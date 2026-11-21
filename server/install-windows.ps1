# =====================================================================
#  Lunis - one-command SERVER installer for Windows 10 / 11
#
#  Makes THIS PC the classroom box. It installs and auto-starts:
#    - the Lunis web app            (port 8090)
#    - llama.cpp + Qwen2.5-3B model    (port 8080)  the AI tutor
#    - LibreTranslate                  (port 5000)  offline translation
#  ...supervised by server\lunis_service.py, which restarts anything that
#  crashes and is itself started at sign-in by a Scheduled Task.
#
#  Usage: double-click  server\Install Lunis Server.cmd
#     or: powershell -ExecutionPolicy Bypass -File server\install-windows.ps1
#
#  Needs internet DURING install only. Safe to re-run: it skips anything
#  already done. No admin rights needed, except one prompt to open the
#  firewall port so other devices can connect.
#
#  The PC also broadcasts its own Wi-Fi ("Lunis") with Windows' Mobile
#  Hotspot, so students' phones and tablets can connect with no router and
#  no internet: they join "Lunis" and open http://192.168.137.1:8090.
#
#  Optional switches:
#    -NoTranslate     skip LibreTranslate (saves ~1.5 GB; app stays English-only)
#    -NoAutoStart     don't register the sign-in task (start it yourself)
#    -NoHotspot       don't broadcast the classroom Wi-Fi (use a router instead)
#    -HotspotName <n> Wi-Fi name students join (default "Lunis")
#    -HotspotPassword <p> its password, 8+ characters (default: generated, shown at the end)
#    -LlamaZip <path> use an already-downloaded llama.cpp Windows zip (offline)
#    -ModelFile <path> use an already-downloaded .gguf model (offline)
#    -OfflineDir <dir> install with NO internet from an offline bundle (SD card /
#                     USB): the "offline" folder built by packaging/build_offline.py.
#                     LunisSetup.exe passes it automatically when that folder sits
#                     next to it.
#    -Uninstall       stop Lunis and remove the auto-start task, firewall rule
#                     and shortcuts (keeps the model/engine; add -Purge to
#                     delete those too). Student data in the repo is never touched.
# =====================================================================
param(
    [switch]$Uninstall,
    [switch]$Purge,
    [switch]$NoTranslate,
    [switch]$NoAutoStart,
    [switch]$NoHotspot,
    [string]$HotspotName = "Lunis",
    [string]$HotspotPassword = "",
    [string]$LlamaZip = "",
    [string]$ModelFile = "",
    [string]$OfflineDir = "",
    [switch]$NoPause,
    [switch]$NoPauseOnSuccess     # used by the LunisSetup.exe wizard: close the console when all went well
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"      # Invoke-WebRequest is 10x slower with the progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo    = Split-Path -Parent $PSScriptRoot
$Service = Join-Path $Repo "server\lunis_service.py"
$TaskName = "Lunis Server"
$ModelName = "qwen2.5-3b-instruct-q4_k_m.gguf"
$ModelUrl = if ($env:LUNIS_MODEL_URL) { $env:LUNIS_MODEL_URL } else {
    "https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-Q4_K_M.gguf?download=true" }

function Step($m){ Write-Host "`n==> $m" -ForegroundColor Cyan }
function OK($m)  { Write-Host "    [ok] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "    [!]  $m" -ForegroundColor Yellow }
function Fail($m){
    Write-Host "`n    [X]  $m" -ForegroundColor Red
    if (-not $NoPause) { Read-Host "  Press Enter to close" }
    exit 1
}
# Run a native program, capturing stdout+stderr as text, without PowerShell 5.1
# turning its stderr into a terminating error (it does that under "Stop").
function Run-Native {
    param([string]$Exe, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { $out = & $Exe @Rest 2>&1 | ForEach-Object { "$_" } }
    finally { $ErrorActionPreference = $prev }
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($out -join "`n") }
}
function Update-Path {
    $env:Path = ([Environment]::GetEnvironmentVariable('Path','Machine'), [Environment]::GetEnvironmentVariable('Path','User')) -join ';'
}

if ($Uninstall) {
    Step "Uninstalling the Lunis server (auto-start, firewall rule, shortcuts)"
    $py = (Get-Command py -ErrorAction SilentlyContinue)
    $pyExe = if ($py) { "py" } else { "python" }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    & $pyExe $Service stop
    & $pyExe $Service hotspot off | Out-Null
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    foreach ($l in @((Join-Path ([Environment]::GetFolderPath("Startup")) "Lunis Server.lnk"),
                     (Join-Path ([Environment]::GetFolderPath("Desktop")) "Lunis Server Status.lnk"))) {
        if (Test-Path $l) { Remove-Item $l }
    }
    $rules = Get-NetFirewallRule -DisplayName "Lunis (TCP *)" -ErrorAction SilentlyContinue
    if ($rules) {
        Start-Process powershell -Verb RunAs -WindowStyle Hidden -ArgumentList "-NoProfile -Command Remove-NetFirewallRule -DisplayName 'Lunis (TCP *)'"
    }
    if ($Purge) {
        $h = ((& $pyExe $Service paths) | Out-String | ConvertFrom-Json).home
        if ($h -and (Test-Path $h)) { Remove-Item -Recurse -Force $h; OK "deleted $h" }
    }
    OK "Lunis server removed. The repo (and any student data in data\) is untouched."
    if (-not $NoPause) { Read-Host "  Press Enter to close" }
    exit 0
}

Write-Host ""
Write-Host "  =======================================" -ForegroundColor Cyan
Write-Host "   Lunis server installer (Windows)" -ForegroundColor Cyan
Write-Host "  =======================================" -ForegroundColor Cyan
Write-Host "  Repo: $Repo"

# --- offline bundle (SD card / USB) ---------------------------------------
# Everything that is normally downloaded comes from this folder instead.
$Offline = $null
if ($OfflineDir) {
    if (-not (Test-Path (Join-Path $OfflineDir "windows"))) { Fail "$OfflineDir is not a Lunis offline bundle (no 'windows' folder in it)." }
    $Offline = (Resolve-Path $OfflineDir).Path
    Write-Host "  Offline install from: $Offline" -ForegroundColor Green
    $OffWin = Join-Path $Offline "windows"
    if (-not $LlamaZip) {
        $z = Get-ChildItem $OffWin -Filter "llama-*-bin-win-cpu-x64.zip" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($z) { $LlamaZip = $z.FullName }
    }
    if (-not $ModelFile) {
        $m = Join-Path $Offline "models\$ModelName"
        if (Test-Path $m) { $ModelFile = $m }
    }
}

# --- 1. Python ---------------------------------------------------------
# One interpreter runs the app, the supervisor and LibreTranslate's venv.
# 3.12 / 3.11 are preferred: LibreTranslate's ML wheels lag the newest Python.
Step "Checking Python"
function Find-Python {
    if (Get-Command py -ErrorAction SilentlyContinue) {
        foreach ($v in @("3.12","3.11","3.10")) {
            $r = Run-Native py "-$v" -c "import sys; print(sys.executable)"
            if ($r.Code -eq 0 -and $r.Out) { return $r.Out.Trim() }
        }
    }
    foreach ($c in @("python","python3")) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source -notlike "*WindowsApps*") {
            $r = Run-Native $cmd.Source -c "import sys; print(int(sys.version_info >= (3,9)))"
            if ($r.Out.Trim() -eq "1") { return (& $cmd.Source -c "import sys; print(sys.executable)").Trim() }
        }
    }
    return $null
}
$Py = $null
if ($Offline) {
    # the bundled translator packages are built for Python 3.12 - use exactly that
    if (Get-Command py -ErrorAction SilentlyContinue) {
        $r = Run-Native py "-3.12" -c "import sys; print(sys.executable)"
        if ($r.Code -eq 0 -and $r.Out) { $Py = $r.Out.Trim() }
    }
    if (-not $Py) {
        $inst = Get-ChildItem $OffWin -Filter "python-3.12*-amd64.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $inst) { Fail "Python 3.12 is not installed and the offline bundle has no python-3.12 installer." }
        Step "Installing Python 3.12 from the offline bundle"
        $p = Start-Process -FilePath $inst.FullName -Wait -PassThru -ArgumentList @(
            "/quiet", "InstallAllUsers=0", "PrependPath=1", "Include_launcher=1",
            "InstallLauncherAllUsers=0", "Include_test=0", "Include_doc=0", "Shortcuts=0")
        if ($p.ExitCode -ne 0) { Fail "The Python installer failed (exit code $($p.ExitCode))." }
        Update-Path
        $cand = Join-Path $env:LOCALAPPDATA "Programs\Python\Python312\python.exe"
        if (Test-Path $cand) { $Py = $cand }
        elseif (Get-Command py -ErrorAction SilentlyContinue) {
            $r = Run-Native py "-3.12" -c "import sys; print(sys.executable)"
            if ($r.Code -eq 0 -and $r.Out) { $Py = $r.Out.Trim() }
        }
        if (-not $Py) { Fail "Python 3.12 was installed but can't be found yet. Run the installer again." }
    }
} else {
    $Py = Find-Python
}
if (-not $Py) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Fail "Python 3.9+ is not installed and winget is missing. Install Python 3.12 from python.org (tick 'Add to PATH') and run this again."
    }
    Step "Installing Python 3.12 (winget)"
    winget install -e --id Python.Python.3.12 --scope user --silent --accept-source-agreements --accept-package-agreements | Out-Null
    Update-Path
    $Py = Find-Python
    if (-not $Py) { Fail "Python was installed but can't be found yet. Close this window and run the installer again." }
}
$PyVer = (& $Py -c "import platform; print(platform.python_version())").Trim()
OK "Python $PyVer  ($Py)"
$PyW = Join-Path (Split-Path $Py) "pythonw.exe"
if (-not (Test-Path $PyW)) { $PyW = $Py }

# Ask the service manager where things go, so the installer and the runtime
# can never disagree about paths.
$paths = (& $Py $Service paths) | Out-String | ConvertFrom-Json
$LunisHome = $paths.home
$LlamaDir  = Join-Path $LunisHome "llama"
$ModelDir  = $paths.model_dir
$LtVenv    = Join-Path $LunisHome "libretranslate-venv"
New-Item -ItemType Directory -Force $LunisHome, $ModelDir | Out-Null
OK "Runtime folder: $LunisHome"

# --- 2. llama.cpp (prebuilt official Windows release) ------------------
# The "cpu" build loads the best kernel for this CPU at runtime, so the same
# zip works on a 2012 laptop without AVX2 and on a modern one.
Step "AI engine (llama.cpp)"
if ($paths.llama_server) {
    OK "already installed ($($paths.llama_server))"
} else {
    $zip = $LlamaZip
    if (-not $zip) {
        $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
        $want = "bin-win-cpu-$arch.zip"
        $tagFilter = $env:LUNIS_LLAMA_TAG
        Write-Host "    finding the latest llama.cpp $want ..."
        $rels = Invoke-RestMethod "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=15" -Headers @{ "User-Agent" = "lunis-installer" }
        $asset = $null
        foreach ($r in $rels) {
            if ($tagFilter -and $r.tag_name -ne $tagFilter) { continue }
            $asset = $r.assets | Where-Object { $_.name -like "llama-*-$want" } | Select-Object -First 1
            if ($asset) { $tag = $r.tag_name; break }
        }
        if (-not $asset) { Fail "Could not find a llama.cpp Windows release ($want). Download it by hand from github.com/ggml-org/llama.cpp/releases and re-run with -LlamaZip <file>." }
        $zip = Join-Path $env:TEMP $asset.name
        Write-Host "    downloading $($asset.name) ($tag, $([math]::Round($asset.size/1MB)) MB)"
        & curl.exe -L --fail --retry 3 -o $zip $asset.browser_download_url
        if ($LASTEXITCODE -ne 0) { Fail "llama.cpp download failed." }
    }
    if (Test-Path $LlamaDir) { Remove-Item -Recurse -Force $LlamaDir }
    Expand-Archive -Path $zip -DestinationPath $LlamaDir -Force
    $paths = (& $Py $Service paths) | Out-String | ConvertFrom-Json
    if (-not $paths.llama_server) { Fail "llama-server.exe was not in $zip." }
    OK "installed to $LlamaDir"
}
$r = Run-Native $paths.llama_server --version
if ($r.Code -ne 0) {
    Warn "llama-server.exe would not run: $($r.Out)"
    $vc = if ($Offline) { Get-ChildItem $OffWin -Filter "vc_redist*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 } else { $null }
    if ($vc) { Warn "Install the Visual C++ runtime from the bundle: $($vc.FullName) - then re-run." }
    else { Warn "Install the Microsoft Visual C++ Redistributable (winget install Microsoft.VCRedist.2015+.x64) and re-run." }
} else { OK "llama-server runs ($(($r.Out -split "`n" | Where-Object { $_ -like 'version*' } | Select-Object -First 1)))" }

# --- 3. the model (~1.9 GB, one time) ----------------------------------
Step "AI model ($ModelName)"
$modelPath = Join-Path $ModelDir $ModelName
if (Test-Path $modelPath) {
    OK "already present"
} elseif ($ModelFile) {
    Write-Host "    copying the model (~1.9 GB) from $ModelFile"
    Copy-Item $ModelFile "$modelPath.part"
    Move-Item -Force "$modelPath.part" $modelPath
    OK "copied"
} elseif ($Offline) {
    Fail "The offline bundle has no models\$ModelName."
} else {
    Write-Host "    downloading ~1.9 GB - this can take a while (it resumes if interrupted)"
    & curl.exe -L --fail --retry 5 -C - -o "$modelPath.part" $ModelUrl
    if ($LASTEXITCODE -ne 0) { Fail "Model download failed. Run the installer again to resume." }
    Move-Item -Force "$modelPath.part" $modelPath
    OK "downloaded"
}

# --- 4. LibreTranslate (offline translation) ---------------------------
Step "Translator (LibreTranslate)"
$LtPy = Join-Path $LtVenv "Scripts\python.exe"
if ($NoTranslate) {
    Warn "skipped (-NoTranslate) - the app will stay in English"
} else {
    $haveLt = $false
    if (Test-Path $LtPy) { $haveLt = ((Run-Native $LtPy -c "import libretranslate").Code -eq 0) }
    if ($haveLt) {
        OK "already installed"
    } else {
        Write-Host "    creating its own virtualenv and installing (~1 GB of packages, several minutes)"
        & $Py -m venv $LtVenv
        if ($Offline) {
            & $LtPy -m pip install --disable-pip-version-check --no-index --find-links (Join-Path $OffWin "wheels") libretranslate
        } else {
            & $LtPy -m pip install --disable-pip-version-check -q --upgrade pip
            & $LtPy -m pip install --disable-pip-version-check libretranslate
        }
        if ($LASTEXITCODE -ne 0 -and -not $Offline) {
            # a stale or locked file in pip's shared cache is a common cause - retry without it
            Warn "pip failed; retrying once without pip's download cache"
            & $LtPy -m pip install --disable-pip-version-check --no-cache-dir libretranslate
        }
        if ($LASTEXITCODE -ne 0) { Fail "pip could not install LibreTranslate (see the messages above). Re-run with -NoTranslate to skip it." }
        OK "installed"
    }
    if ($Offline) {
        # language models + sentence models: copy the bundled Argos data folder
        $argosSrc = Join-Path $Offline "argos-translate"
        $argosDst = Join-Path $env:USERPROFILE ".local\share\argos-translate"
        Write-Host "    copying the en/fr/es/de language models from the bundle"
        New-Item -ItemType Directory -Force $argosDst | Out-Null
        & robocopy.exe $argosSrc $argosDst /E /NFL /NDL /NJH /NJS /NP | Out-Null
        & $LtPy (Join-Path $PSScriptRoot "lt_models.py") --check en fr es de
    } else {
    # Fetch the en/fr/es/de language models NOW, while there is internet - the
    # classroom box may never see the internet again.
    Write-Host "    downloading the en/fr/es/de language models (one time)"
    & $LtPy (Join-Path $PSScriptRoot "lt_models.py") en fr es de
    }
    if ($LASTEXITCODE -ne 0) { Warn "language models not all installed - LibreTranslate will try again on first start (needs internet then)" }
    else { OK "language models ready" }
}

# --- 4b. lesson videos (public repo only) --------------------------------
# The public repo keeps the videos out of git (see NOTICE.md) and ships a
# downloader; the dev repo has them checked in. Fetch only when the script exists.
if ((Test-Path (Join-Path $Repo "scripts\fetch_content.py")) -and -not $Offline) {
    Step "Lesson videos (~570 MB, one time)"
    Push-Location $Repo
    $r = Run-Native $Py scripts\fetch_content.py --download
    Pop-Location
    if ($r.Code -eq 0) { OK "lesson videos ready" }
    else { Warn "could not download the lesson videos - everything else works. Retry: `"$Py`" scripts\fetch_content.py --download" }
}

# --- 5. transcripts the AI reads ---------------------------------------
Step "Preparing lesson transcripts"
Push-Location $Repo
try { $env:PYTHONUTF8 = "1"; & $Py app\prep.py | Out-Null; OK "done" } catch { Warn "prep.py had a hiccup (non-fatal)" }
Pop-Location

# --- 6. one admin prompt: firewall + hotspot that stays on -------------
# The firewall rule lets classroom devices reach port 8090. The registry value stops
# Mobile Hotspot from switching itself off when no device has been connected for a
# few minutes (the supervisor would turn it back on, but students would see the
# network vanish in between).
Step "Firewall and hotspot settings (one Windows permission prompt)"
$port = $paths.ports.app
$icsKey = "HKLM:\SYSTEM\CurrentControlSet\Services\icssvc\Settings"
$adminCmds = @()
if (-not (Get-NetFirewallRule -DisplayName "Lunis (TCP $port)" -ErrorAction SilentlyContinue)) {
    $adminCmds += "New-NetFirewallRule -DisplayName 'Lunis (TCP $port)' -Direction Inbound -Protocol TCP -LocalPort $port -Action Allow -Profile Any | Out-Null"
}
function Test-NoPeerlessTimeout {
    try { return ((Get-ItemProperty -Path $icsKey -Name PeerlessTimeoutEnabled -ErrorAction Stop).PeerlessTimeoutEnabled -eq 0) } catch { return $false }
}
if (-not $NoHotspot -and -not (Test-NoPeerlessTimeout)) {
    # (never "New-Item -Force" on this key: on an existing key that wipes the hotspot's saved settings)
    $adminCmds += "if (-not (Test-Path '$icsKey')) { New-Item -Path '$icsKey' | Out-Null }"
    $adminCmds += "New-ItemProperty -Path '$icsKey' -Name PeerlessTimeoutEnabled -PropertyType DWord -Value 0 -Force | Out-Null"
    $adminCmds += "Restart-Service icssvc -Force -ErrorAction SilentlyContinue"
}
if ($adminCmds.Count -eq 0) {
    OK "already set"
} else {
    $cmd = $adminCmds -join "; "
    try {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($isAdmin) { Invoke-Expression $cmd }
        else {
            Write-Host "    Windows will ask for permission once (Yes = allow the classroom to connect)."
            # no -Wait: if nobody is at the screen to click Yes, the install must not hang
            Start-Process powershell -Verb RunAs -WindowStyle Hidden -ArgumentList "-NoProfile -Command $cmd"
            for ($i = 0; $i -lt 90; $i++) {
                if ((Get-NetFirewallRule -DisplayName "Lunis (TCP $port)" -ErrorAction SilentlyContinue) -and
                    ($NoHotspot -or (Test-NoPeerlessTimeout))) { break }
                Start-Sleep 1
            }
        }
        if (Get-NetFirewallRule -DisplayName "Lunis (TCP $port)" -ErrorAction SilentlyContinue) { OK "port $port opened" }
        else { Warn "firewall rule not created - other devices may be blocked. Re-run as administrator." }
        if (-not $NoHotspot) {
            if (Test-NoPeerlessTimeout) { OK "hotspot stays on with no devices connected" }
            else { Warn "hotspot may switch off when idle (Lunis turns it back on within a minute)" }
        }
    } catch { Warn "admin step failed ($($_.Exception.Message)). Other devices may be blocked until you allow Python through Windows Firewall." }
}

# --- 6b. classroom Wi-Fi (Mobile Hotspot) --------------------------------
$HotspotOn = $false
if ($NoHotspot) {
    & $Py $Service hotspot off | Out-Null
} else {
    Step "Classroom Wi-Fi (Mobile Hotspot)"
    $probe = Run-Native powershell "-NoProfile" "-ExecutionPolicy" "Bypass" "-File" (Join-Path $Repo "server\hotspot-windows.ps1") "status"
    $hs = $null; try { $hs = ($probe.Out -split "`n" | Where-Object { $_ -like "{*" } | Select-Object -Last 1) | ConvertFrom-Json } catch { }
    if (-not $hs -or -not $hs.ok) {
        $why = if ($hs) { $hs.error } else { $probe.Out }
        Warn "this PC can't run a Wi-Fi hotspot ($why)."
        Warn "Use a cheap Wi-Fi router instead - see docs\WINDOWS_SERVER.md."
    } else {
        $hsFile = Join-Path $paths.home "hotspot.json"
        $pass = $HotspotPassword
        if (-not $pass -and (Test-Path $hsFile)) { try { $pass = (Get-Content $hsFile -Raw | ConvertFrom-Json).password } catch { } }
        if (-not $pass) { $pass = "lunis" + (Get-Random -Minimum 1000 -Maximum 10000) }
        $r = Run-Native $Py $Service hotspot on --ssid $HotspotName --password $pass
        if ($r.Code -eq 0) { $HotspotOn = $true; $HotspotPass = $pass; OK "broadcasting Wi-Fi `"$HotspotName`"" }
        else { Warn "hotspot did not start: $($r.Out)"; Warn "Lunis will keep retrying every minute." ; $HotspotOn = $true; $HotspotPass = $pass }
    }
}

# --- 7. auto-start at sign-in ------------------------------------------
# A per-user Scheduled Task (no admin needed). pythonw = no console window.
if ($NoAutoStart) {
    Step "Auto-start"
    Warn "skipped (-NoAutoStart). Start it with:  `"$Py`" `"$Service`" run"
} else {
    Step "Auto-start at sign-in (Scheduled Task '$TaskName')"
    & $Py $Service stop | Out-Null          # an older copy may be running
    $action   = New-ScheduledTaskAction -Execute $PyW -Argument "`"$Service`" run" -WorkingDirectory $Repo
    # the real account name: over SSH or in some sessions $env:USERDOMAIN says WORKGROUP
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $atLogon = New-ScheduledTaskTrigger -AtLogOn -User $me
    # ...plus a 5-minute watchdog: if the supervisor was killed, this brings it back
    # (a running one just exits - "already running"; a deliberate stop is honoured).
    # It has to be its own trigger: a repetition on the logon trigger would only
    # begin at the NEXT sign-in.
    $watchdog = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $trigger  = @($atLogon, $watchdog)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                  -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) `
                  -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
    try {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
            -Principal $principal -Description "Lunis offline math tutor (web app + AI + translation)" -Force | Out-Null
        & $Py $Service start | Out-Null       # clears any earlier deliberate stop, runs the task
        OK "registered and started"
    } catch {
        Warn "Scheduled Task failed ($($_.Exception.Message)); using a Startup-folder shortcut instead"
        $startup = [Environment]::GetFolderPath("Startup")
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut((Join-Path $startup "Lunis Server.lnk"))
        $lnk.TargetPath = $PyW; $lnk.Arguments = "`"$Service`" run"; $lnk.WorkingDirectory = $Repo
        $lnk.WindowStyle = 7; $lnk.Save()
        Start-Process -FilePath $PyW -ArgumentList "`"$Service`" run" -WorkingDirectory $Repo -WindowStyle Hidden
        OK "Startup shortcut created and Lunis started"
    }
}

# --- 8. desktop helpers -------------------------------------------------
try {
    $desk = [Environment]::GetFolderPath("Desktop")
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut((Join-Path $desk "Lunis Server Status.lnk"))
    $lnk.TargetPath = Join-Path $Repo "server\Lunis Server.cmd"; $lnk.WorkingDirectory = $Repo; $lnk.Save()
} catch { }

# --- 9. health check ----------------------------------------------------
Step "Checking the app is up"
$code = 0
if (-not $NoAutoStart) {
    for ($i = 0; $i -lt 30; $i++) {
        try { $code = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 "http://127.0.0.1:$port/").StatusCode } catch { $code = 0 }
        if ($code -eq 200) { break }
        Start-Sleep 1
    }
}
$ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
       Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" -and $_.PrefixOrigin -ne "WellKnown" } |
       Select-Object -ExpandProperty IPAddress

Write-Host ""
Write-Host "  =======================================" -ForegroundColor Cyan
if ($code -eq 200) { Write-Host "   Lunis is RUNNING" -ForegroundColor Green }
elseif ($NoAutoStart) { Write-Host "   Installed (not started)" -ForegroundColor Yellow }
else { Write-Host "   App not answering yet - check: server\Lunis Server.cmd" -ForegroundColor Yellow }
Write-Host "  =======================================" -ForegroundColor Cyan
Write-Host "   On this PC:        http://127.0.0.1:$port"
foreach ($ip in $ips) { if ($ip -ne "192.168.137.1") { Write-Host "   From other devices: http://${ip}:$port" } }
if ($HotspotOn) {
    Write-Host ""
    Write-Host "   STUDENTS:  join Wi-Fi  $HotspotName" -ForegroundColor Green
    Write-Host "              password    $HotspotPass" -ForegroundColor Green
    Write-Host "              then open   http://192.168.137.1:$port" -ForegroundColor Green
}
Write-Host ""
Write-Host "   Notes:"
Write-Host "    - The AI model and translator load in the background; the first AI"
Write-Host "      answer and first translation can take a minute."
Write-Host "    - Status / restart / logs: double-click 'Lunis Server Status' on the Desktop"
Write-Host "      (or: `"$Py`" server\lunis_service.py status)"
Write-Host "    - It starts by itself when you sign in. For a box that should come up"
Write-Host "      after a power cut, turn on automatic sign-in (see docs\WINDOWS_SERVER.md)."
if ($HotspotOn) {
    Write-Host "    - The PC keeps a Wi-Fi hotspot on while Lunis runs (no internet needed)."
    Write-Host "      Change the name/password: `"$Py`" server\lunis_service.py hotspot on --ssid NAME --password PASS"
} else {
    Write-Host "    - Kids' Wi-Fi with no internet: a cheap Wi-Fi router (docs\WINDOWS_SERVER.md)."
}
Write-Host "    - First time you open it, an on-screen wizard sets the teacher password."
Write-Host ""
if ($code -eq 200 -and -not $NoPauseOnSuccess) { Start-Process "http://127.0.0.1:$port" }
if (-not $NoPause -and -not ($NoPauseOnSuccess -and $code -eq 200)) { Read-Host "  Done. Press Enter to close" }
