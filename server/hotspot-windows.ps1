# Lunis classroom Wi-Fi on Windows: drives the built-in Mobile Hotspot through the
# WinRT tethering API, so the box broadcasts its own network with no router and no
# internet. Students join it and open http://192.168.137.1:8090.
#
#   hotspot-windows.ps1 status
#   hotspot-windows.ps1 ensure -Ssid Lunis -Password secret123   (start if off; reconfigure if changed)
#   hotspot-windows.ps1 stop
#
# Prints one line of JSON. No admin rights needed. Called every minute by
# lunis_service.py, which is what keeps the hotspot up across reboots, sleep and
# Windows' "turn off when no devices are connected" timer.
#
# Mobile Hotspot has to be tied to a network "connection profile". Normally that is
# the one with internet, but any profile works - including the profile of a cable or
# Wi-Fi network that is not connected right now - so the hotspot comes up in a room
# with no internet at all.
param(
    [Parameter(Position = 0)][ValidateSet('status', 'ensure', 'stop')][string]$Action = 'status',
    [string]$Ssid = 'Lunis',
    [string]$Password = ''
)
$ErrorActionPreference = 'Stop'

function Out-Json($h) { $h | ConvertTo-Json -Compress; exit 0 }

try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 }
    $asOp = ($asTask | Where-Object { $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    $asAct = ($asTask | Where-Object { $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' })[0]
    function Wait-Op($op, [Type]$t) {
        $task = $asOp.MakeGenericMethod($t).Invoke($null, @($op))
        if (-not $task.Wait(30000)) { throw 'timed out' }
        $task.Result
    }
    function Wait-Act($op) {
        $task = $asAct.Invoke($null, @($op))
        if (-not $task.Wait(30000)) { throw 'timed out' }
    }
    $NI = [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime]
    $TM = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]
    $RT = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]
    [Windows.Networking.NetworkOperators.NetworkOperatorTetheringAccessPointConfiguration, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime] | Out-Null
} catch {
    Out-Json @{ ok = $false; state = 'unsupported'; error = "Mobile Hotspot API unavailable: $($_.Exception.Message)" }
}

# Pick a connection profile to hang the hotspot on: internet first, then any other
# whose tethering capability is Enabled.
$manager = $null; $profileName = ''; $lastErr = 'no network connection profile on this PC'
$cands = @()
$inet = $NI::GetInternetConnectionProfile()
if ($inet) { $cands += $inet }
$cands += @($NI::GetConnectionProfiles() | Where-Object { -not $inet -or $_.ProfileName -ne $inet.ProfileName })
foreach ($p in $cands) {
    try {
        $cap = $TM::GetTetheringCapabilityFromConnectionProfile($p)
        if ("$cap" -ne 'Enabled') { $lastErr = "tethering capability: $cap"; continue }
        $manager = $TM::CreateFromConnectionProfile($p); $profileName = $p.ProfileName
        break
    } catch { $lastErr = $_.Exception.Message }
}
if (-not $manager) { Out-Json @{ ok = $false; state = 'unavailable'; error = $lastErr } }

# The saved hotspot settings can be missing or unreadable (fresh PC, wiped registry):
# then start from an empty configuration, which "ensure" fills in and saves.
function Get-Config {
    try { return $manager.GetCurrentAccessPointConfiguration() }
    catch { return New-Object Windows.Networking.NetworkOperators.NetworkOperatorTetheringAccessPointConfiguration }
}
function Get-State {
    $c = Get-Config
    @{ ok = $true; state = "$($manager.TetheringOperationalState)"; ssid = $c.Ssid
       clients = $manager.ClientCount; max_clients = $manager.MaxClientCount; profile = $profileName }
}

try {
    switch ($Action) {
        'status' { Out-Json (Get-State) }
        'stop' {
            if ("$($manager.TetheringOperationalState)" -ne 'Off') {
                $r = Wait-Op ($manager.StopTetheringAsync()) $RT
                if ("$($r.Status)" -ne 'Success') { Out-Json @{ ok = $false; state = 'error'; error = "stop: $($r.Status) $($r.AdditionalErrorMessage)" } }
            }
            Out-Json (Get-State)
        }
        'ensure' {
            $c = Get-Config
            $changed = $false
            if ($Ssid -and $c.Ssid -ne $Ssid) { $c.Ssid = $Ssid; $changed = $true }
            if ($Password -and $c.Passphrase -ne $Password) { $c.Passphrase = $Password; $changed = $true }
            $on = "$($manager.TetheringOperationalState)" -eq 'On'
            if ($changed) {
                if ($on) { Wait-Op ($manager.StopTetheringAsync()) $RT | Out-Null; $on = $false }
                Wait-Act ($manager.ConfigureAccessPointAsync($c))
            }
            if (-not $on) {
                $r = Wait-Op ($manager.StartTetheringAsync()) $RT
                if ("$($r.Status)" -ne 'Success') {
                    $h = Get-State; $h.ok = $false; $h.error = "start: $($r.Status) $($r.AdditionalErrorMessage)"; Out-Json $h
                }
            }
            $h = Get-State; $h.started = (-not $on); Out-Json $h
        }
    }
} catch {
    Out-Json @{ ok = $false; state = 'error'; error = $_.Exception.Message; profile = $profileName }
}
