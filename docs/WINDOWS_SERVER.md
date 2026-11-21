# Running a Lunis server on Windows

This turns a **Windows 10 or 11 PC** into a complete classroom box: the web app, the
local AI tutor and offline translation, all starting by themselves. It is the Windows
counterpart of [SERVER_SETUP.md](SERVER_SETUP.md) (Ubuntu). If you only want to *edit
the code*, see [CONTRIBUTING.md](CONTRIBUTING.md) instead.

Everything runs **offline** once installed. Internet is needed only during the install
(~2.5 GB of downloads: the AI engine, the model, the translator and the lesson videos).

---

## The easiest way: LunisSetup.exe

If the [release page](https://github.com/lunislearning/Lunis/releases) has
**`LunisSetup-<version>.exe`**, download it and run it. A
normal setup wizard asks for the classroom Wi-Fi name and password, copies Lunis to
`C:\Users\<you>\Lunis` and sets everything up, including one Windows permission prompt
(click **Yes**). The last page shows what to write on the board. It also adds
*Start menu → Lunis* (open, status, uninstall) and an entry under *Settings → Apps*.
Uninstalling stops Lunis and removes auto-start and the hotspot, but keeps the student
data in `Lunis\data`.

The installer isn't code-signed yet. If Windows shows *"Windows protected your PC"*,
click **More info → Run anyway**.

Silent install: `LunisSetup-<version>.exe /VERYSILENT /TASKS="hotspot"`.

### No internet at all: the offline bundle (SD card / USB)

If the release offers it, the **Lunis-Offline** folder holds the installers plus an `offline\` folder with
everything they would otherwise download: the AI model, the engine, Python, the
translator and its language data. Copy the whole folder to an SD card or USB stick
(8 GB or more; FAT32 is fine) and double-click `LunisSetup-<version>.exe` on it.
Setup sees the `offline\` folder next to it and installs with no internet. From the
source code, pass the same folder to the installer:
`powershell -ExecutionPolicy Bypass -File server\install-windows.ps1 -OfflineDir E:\Lunis-Offline\offline`.

Mobile Hotspot needs the PC to have joined *some* network once, any Wi-Fi or cable;
internet isn't required. A PC that has never been on any network may refuse to
start the hotspot. If so, use a router.

## From the source code: one double-click

1. Get the code (either way works):
   - **Git:** `git clone https://github.com/lunislearning/Lunis.git %USERPROFILE%\lunis`
   - **No Git:** download the ZIP from GitHub and unzip it to `C:\Users\<you>\lunis`
2. Open the folder, go into `server\` and double-click **`Install Lunis Server.cmd`**.
3. Click **Yes** when Windows asks for permission. That opens the firewall and keeps the
   classroom Wi-Fi hotspot from switching itself off.

When it finishes, a browser opens at <http://127.0.0.1:8090> and the window lists the
address other devices use, for example `http://192.168.1.50:8090`. The first time you
open it, a short wizard sets the teacher password.

The installer is safe to re-run. It skips anything already done and resumes a
half-finished model download.

### What it installs

| Piece | Where | Size |
|---|---|---|
| Python 3.12 (only if there is no Python 3.9+) | per-user, via `winget` | ~100 MB |
| llama.cpp: official Windows CPU build | `%LOCALAPPDATA%\Lunis\llama\` | ~25 MB |
| Qwen2.5-3B-Instruct Q4_K_M model | `%LOCALAPPDATA%\Lunis\models\` | ~1.9 GB |
| LibreTranslate + en/fr/es/de models | `%LOCALAPPDATA%\Lunis\libretranslate-venv\` | ~1 GB |
| Lesson videos (`scripts\fetch_content.py`) | `content\` inside the repo folder | ~570 MB |
| Auto-start | Task Scheduler → **Lunis Server** (runs at sign-in) | |
| Firewall | inbound rule **Lunis (TCP 8090)** | |
| Classroom Wi-Fi | Mobile Hotspot **Lunis**, kept on by the supervisor | |
| Shortcut | Desktop → **Lunis Server Status** | |

No admin rights are needed, apart from the single firewall prompt. Student data stays
where it always is: `data\` inside the repo folder.

The llama.cpp **CPU** build picks the fastest code path for the CPU at run time. The same
download therefore works on a 2012 laptop without AVX2 and on a new machine.

### Installer options

Run these from PowerShell in the repo folder:

```powershell
# skip LibreTranslate (saves ~1 GB; the app stays English-only)
powershell -ExecutionPolicy Bypass -File server\install-windows.ps1 -NoTranslate

# offline install from files you downloaded elsewhere
powershell -ExecutionPolicy Bypass -File server\install-windows.ps1 `
    -LlamaZip D:\llama-b12376-bin-win-cpu-x64.zip -ModelFile D:\qwen2.5-3b-instruct-q4_k_m.gguf

# remove auto-start, firewall rule and shortcuts (-Purge also deletes the engine/model)
powershell -ExecutionPolicy Bypass -File server\install-windows.ps1 -Uninstall
```

---

## How it runs

Windows has no `systemd`, so a small supervisor, `server\lunis_service.py` (standard
library only, like the app), does the same job:

```
Task Scheduler (at sign-in)
  └─ pythonw lunis_service.py run          ← no console window
       ├─ llama-server.exe   :8080          AI tutor
       ├─ LibreTranslate     :5000          translation
       └─ python app\server.py :8090        the Lunis web app
```

- It restarts any piece that crashes. The wait between retries grows (3 s, 6 s, … up to
  60 s), so a broken piece can't spin the CPU.
- If the supervisor itself is killed, its children go with it (a Windows Job object), and
  the Scheduled Task, which re-checks every 5 minutes, starts it again. A deliberate
  `stop` holds until you run `start` or the PC reboots.
- A missing piece is not fatal. Without the model or LibreTranslate the app still serves
  lessons, videos, quizzes and books. Only AI answers and live translation are missing,
  and the log says why.
- While it runs, it **keeps the PC from going to sleep**. The screen can still turn off.
- Logs are kept in `%LOCALAPPDATA%\Lunis\logs\` as `supervisor.log`, `app.log`,
  `llama.log` and `translate.log`.

### Everyday control

Double-click **Lunis Server Status** on the Desktop (or `server\Lunis Server.cmd`). It
shows what is running and offers *open*, *restart app*, *restart everything*, *stop*,
*start* and *logs*. The same actions work from a terminal:

```powershell
py server\lunis_service.py status
py server\lunis_service.py restart app      # after editing server.py
py server\lunis_service.py restart all
py server\lunis_service.py stop
py server\lunis_service.py start          # start again (after a stop)
```

After editing `app.js` or `style.css`, a restart isn't needed. Bump the `?v=NN` in
`index.html` and hard-refresh.

---

## Make it behave like a real server

A classroom box has to come back by itself after a power cut or a Windows Update reboot.

1. **Automatic sign-in.** The auto-start task runs when the user signs in. On a
   dedicated box, sign that user in automatically: press Win+R, type `netplwiz` and
   untick *Users must enter a user name and password*. If that tickbox is missing, set
   *Settings → Accounts → Sign-in options → "For improved security, only allow Windows
   Hello sign-in"* to **Off** first.
2. **Lid and power.** Plug the laptop in. To keep it running with the lid closed, go to
   *Control Panel → Power Options → Choose what closing the lid does → When plugged in:
   Do nothing*.
3. **Restart after a power cut.** If the BIOS/UEFI has *Restore on AC power loss* /
   *Power on after power failure*, turn it on.
4. **Windows Update.** Under *Settings → Windows Update → Advanced options → Active
   hours*, cover the school day so update reboots happen at night.

---

## Let students connect: the box is the Wi-Fi

The installer makes the PC broadcast its own Wi-Fi with Windows' **Mobile Hotspot**.
No router and no internet are needed. At the end, the installer shows:

```
STUDENTS:  join Wi-Fi  Lunis
           password    lunis4821
           then open   http://192.168.137.1:8090
```

Write those three lines on the board. Up to 8 devices can join, which is Windows' limit
for Mobile Hotspot.

- The supervisor checks the hotspot every minute and turns it back on after a reboot,
  after sleep, or if Windows switched it off. The installer also turns off Windows'
  *"turn off when no devices are connected"* timer (that is the one admin prompt).
- It works while the PC is on another Wi-Fi as well, and with no network at all.
- Change the name or password, or turn it off:

  ```powershell
  py server\lunis_service.py hotspot                          # status, devices connected
  py server\lunis_service.py hotspot on --ssid "Room 4" --password apples123
  py server\lunis_service.py hotspot off                      # and it stays off
  ```
- Skip it at install time with `-NoHotspot`. Set the name and password up front with
  `-HotspotName "Room 4" -HotspotPassword apples123`.

**More than 8 students, or a PC without Wi-Fi:** use a cheap Wi-Fi router instead. It
needs no internet. Plug the box into it by cable or join its Wi-Fi, reserve a fixed IP
for the box, and students open `http://<box-ip>:8090`.

---

## Troubleshooting

| Symptom | Check |
|---|---|
| Nothing at `http://127.0.0.1:8090` | `py server\lunis_service.py status`, then `logs\app.log` |
| Other devices can't connect but the box itself can | Firewall rule: `Get-NetFirewallRule -DisplayName "Lunis*"`. Re-run the installer and click **Yes**. Make sure both are on the same Wi-Fi. |
| One phone's Chrome shows `ERR_TOO_MANY_RETRIES` or "can't be reached", but other browsers on the same phone work | Android is keeping Chrome off the local network; the server never sees the request. Go to *Settings → Apps → Chrome → Permissions* and allow **Nearby devices** ("Local network" on some phones). Check that Chrome isn't listed under *Settings → Connections → Data usage → Mobile data only apps*. Then fully close Chrome and reopen it. |
| "AI is unavailable" | `logs\llama.log`. The first answer after a start takes up to a minute while the model loads. |
| `llama-server.exe` won't start (missing DLL) | Install the Visual C++ runtime: `winget install Microsoft.VCRedist.2015+.x64` |
| Translations stay English | `logs\translate.log`. Without the language models, LibreTranslate needs internet once. Re-run the installer while online. |
| Port already in use | Another program has 8090/8080/5000. Change `port`, `llama_url` or `libretranslate_url` in `config.json`. The supervisor reads the same file. |
| Students can't see the "Lunis" Wi-Fi | `py server\lunis_service.py hotspot` shows the state and any error, and `logs\supervisor.log` records each start. Some Wi-Fi cards can't run a hotspot at all; use a router. |
| Phone joins "Lunis" but says "no internet" | Expected. Tap *Stay connected* / *Use this network anyway*, then open `http://192.168.137.1:8090`. |
| Phone is on "Lunis" but Chrome can't open the page (another browser can) | Chrome sometimes keeps using the previous network for a minute after you switch Wi-Fi. Reload, or close Chrome fully and reopen it. If it still fails, see the `ERR_TOO_MANY_RETRIES` row above. |
| Want it to stop starting at sign-in | `server\install-windows.ps1 -Uninstall` |
