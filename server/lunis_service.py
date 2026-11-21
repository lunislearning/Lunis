#!/usr/bin/env python3
"""Lunis service manager - runs the whole classroom box on Windows (or any box without systemd).

The box is three local programs:
    app        app/server.py        the Lunis web app      (:8090)
    llama      llama-server         the AI tutor           (:8080)
    translate  LibreTranslate       offline translation    (:5000)

On Linux, server/install.sh hands them to systemd. Windows has no equivalent you
can rely on without admin rights, so this one small supervisor does that job there:
it starts all three, restarts any that crash (with back-off), writes their output to
log files, stops them cleanly, and keeps the classroom Wi-Fi hotspot on. Windows only
has to start this script at sign-in (a Scheduled Task - install-windows.ps1 sets it
up).

    python server/lunis_service.py run              supervise all three (foreground)
    python server/lunis_service.py status           what is running / answering
    python server/lunis_service.py stop             stop the supervisor and everything
    python server/lunis_service.py start            start it in the background (after a stop)
    python server/lunis_service.py restart [NAME]   restart one service (or all)
    python server/lunis_service.py hotspot [on|off] classroom Wi-Fi (Windows; see hotspot-windows.ps1)
    python server/lunis_service.py paths            where everything is expected

A missing piece is not fatal: if llama-server or LibreTranslate is not installed the
web app still runs (lessons, videos, quizzes, books all work; only AI answers and
live translation are unavailable), and the log says what is missing.

Pure standard library, like the app itself.
"""
import json
import os
import platform
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from urllib.parse import urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
APP = os.path.join(REPO, "app")
IS_WIN = os.name == "nt"
EXE = ".exe" if IS_WIN else ""

CONTROL_PORT = 18090          # localhost-only; doubles as the single-instance lock
LOG_MAX_BYTES = 5 * 1024 * 1024
LANGS = "en,fr,es,de"


# ---------------------------------------------------------------- configuration

def _load_config():
    path = os.path.join(REPO, "config.json")
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f) or {}
    except (OSError, ValueError):
        return {}

_CFG = _load_config()

def conf(key, default=None):
    """Same lookup order as app/server.py: LUNIS_<KEY> env var, config.json, default."""
    return os.environ.get("LUNIS_" + key.upper(), _CFG.get(key, default))


def lunis_home():
    """Where the installers put the engine, model, translator venv and logs."""
    h = conf("home")
    if h:
        return os.path.abspath(os.path.expanduser(h))
    if IS_WIN:
        base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~\\AppData\\Local")
        return os.path.join(base, "Lunis")
    return os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"), "lunis")

HOME = lunis_home()
LOGS = os.path.join(HOME, "logs")


def _port_of(url, default):
    try:
        return urlparse(url).port or default
    except ValueError:
        return default

APP_PORT = int(conf("port", 8090))
LLAMA_URL = conf("llama_url", "http://127.0.0.1:8080/v1/chat/completions")
LT_URL = conf("libretranslate_url", "http://127.0.0.1:5000/translate")
LLAMA_PORT = _port_of(LLAMA_URL, 8080)
LT_PORT = _port_of(LT_URL, 5000)
MODEL = conf("model", "qwen2.5-3b-instruct-q4_k_m.gguf")


def _first_file(cands):
    for c in cands:
        if c and os.path.isfile(c):
            return c
    return None


def python_for_children():
    """The interpreter for child Python processes. Under pythonw.exe (how the Windows
    Scheduled Task starts us, so no console window appears) use the python.exe next
    to it instead: the app prints, and pythonw has no stdout to print to."""
    exe = sys.executable
    if IS_WIN and os.path.basename(exe).lower() == "pythonw.exe":
        alt = os.path.join(os.path.dirname(exe), "python.exe")
        if os.path.isfile(alt):
            return alt
    return exe


def find_llama_server():
    explicit = conf("llama_server")
    if explicit:
        return explicit if os.path.isfile(explicit) else None
    name = "llama-server" + EXE
    llama_dir = os.path.join(HOME, "llama")
    cands = [os.path.join(llama_dir, name),
             os.path.join(llama_dir, "build", "bin", name),
             os.path.expanduser(os.path.join("~", "llama.cpp", "build", "bin", name))]
    if os.path.isdir(llama_dir):           # release zips sometimes unpack into a subfolder
        for sub in sorted(os.listdir(llama_dir)):
            cands.append(os.path.join(llama_dir, sub, name))
    return _first_file(cands) or shutil.which("llama-server")


def find_model():
    explicit = conf("model_path")
    if explicit:
        return explicit if os.path.isfile(explicit) else None
    return _first_file([os.path.join(HOME, "models", MODEL),
                        os.path.expanduser(os.path.join("~", "models", MODEL))])


def find_translate_python():
    """The LibreTranslate virtualenv's interpreter (we run the package through it
    rather than via its console-script wrapper, so stopping it stops the real process)."""
    explicit = conf("libretranslate_python")
    if explicit:
        return explicit if os.path.isfile(explicit) else None
    venvs = [os.path.join(HOME, "libretranslate-venv"),
             os.path.expanduser(os.path.join("~", "libretranslate-venv"))]
    rel = os.path.join("Scripts", "python.exe") if IS_WIN else os.path.join("bin", "python")
    return _first_file([os.path.join(v, rel) for v in venvs])


def llama_threads():
    t = conf("threads")
    if t:
        return int(t)
    try:
        sys.path.insert(0, APP)
        from tutor_core import hardware
        return max(1, hardware.physical_cores())
    except Exception:
        return max(1, (os.cpu_count() or 2) // 2)
    finally:
        if sys.path and sys.path[0] == APP:
            sys.path.pop(0)


# ---------------------------------------------------------------- service specs

class Spec:
    def __init__(self, name, port, health_path, cmd=None, cwd=None, missing=None, env=None):
        self.name, self.port, self.health_path = name, port, health_path
        self.cmd, self.cwd, self.missing, self.env = cmd, cwd, missing, env


def build_specs():
    child_env = dict(os.environ, PYTHONUTF8="1", PYTHONIOENCODING="utf-8", PYTHONUNBUFFERED="1")
    specs = []

    specs.append(Spec("app", APP_PORT, "/",
                      cmd=[python_for_children(), os.path.join(APP, "server.py")],
                      cwd=APP, env=child_env))

    llama, model = find_llama_server(), find_model()
    if llama and model:
        extra = conf("llama_args")
        if isinstance(extra, str):
            extra = extra.split()
        cmd = [llama, "-m", model, "--host", "127.0.0.1", "--port", str(LLAMA_PORT),
               "-c", str(conf("ctx", 4096)), "-t", str(llama_threads())] + list(extra or [])
        specs.append(Spec("llama", LLAMA_PORT, "/health", cmd=cmd, cwd=os.path.dirname(llama)))
    else:
        why = []
        if not llama:
            why.append("llama-server not found (looked in %s and on PATH)" % os.path.join(HOME, "llama"))
        if not model:
            why.append("model %s not found in %s" % (MODEL, os.path.join(HOME, "models")))
        specs.append(Spec("llama", LLAMA_PORT, "/health", missing="; ".join(why)))

    lt_py = find_translate_python()
    if lt_py:
        code = "import sys; from libretranslate.main import main; sys.exit(main())"
        cmd = [lt_py, "-c", code, "--host", "127.0.0.1", "--port", str(LT_PORT),
               "--load-only", LANGS]
        specs.append(Spec("translate", LT_PORT, "/languages", cmd=cmd, cwd=HOME, env=child_env))
    else:
        specs.append(Spec("translate", LT_PORT, "/languages",
                          missing="LibreTranslate venv not found in %s" % HOME))
    return specs


# ---------------------------------------------------------------- helpers

def http_code(port, path, timeout=3.0):
    try:
        with urllib.request.urlopen("http://127.0.0.1:%d%s" % (port, path), timeout=timeout) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception:
        return 0


def port_busy(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.5)
        return s.connect_ex(("127.0.0.1", port)) == 0


def _open_log(name):
    os.makedirs(LOGS, exist_ok=True)
    path = os.path.join(LOGS, name + ".log")
    try:
        if os.path.getsize(path) > LOG_MAX_BYTES:
            old = path + ".1"
            if os.path.exists(old):
                os.remove(old)
            os.replace(path, old)
    except OSError:
        pass
    return open(path, "ab", buffering=0)


_say_lock = threading.Lock()
_say_file = None

def say(msg):
    line = "%s  %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg)
    with _say_lock:
        if _say_file:
            _say_file.write((line + "\n").encode("utf-8", "replace"))
        if sys.stdout:                     # None under pythonw.exe
            try:
                print(line, flush=True)
            except (OSError, ValueError):
                pass


def kill_tree(proc):
    """Stop a child and everything it started."""
    if proc.poll() is not None:
        return
    if IS_WIN:
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    else:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except OSError:
            proc.terminate()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        if not IS_WIN:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except OSError:
                pass
        proc.kill()


# ---------------------------------------------------------------- orphan control
# If the supervisor itself is killed (Task Manager, kill -9, a crash), its children
# must not live on holding ports 8090/8080/5000 - the next supervisor could then
# never start its own. Windows: every child goes into a Job object that the OS
# kills when the supervisor's handle to it closes. Elsewhere: the children's
# PIDs are written to a file, and the next supervisor stops any that are still ours.

PIDFILE = os.path.join(HOME, "children.json")
_job = None

def _windows_job():
    global _job
    if _job is not None or not IS_WIN:
        return _job
    import ctypes
    from ctypes import wintypes
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.CreateJobObjectW.restype = wintypes.HANDLE
    job = k32.CreateJobObjectW(None, None)
    if not job:
        return None

    class IO_COUNTERS(ctypes.Structure):
        _fields_ = [(n, ctypes.c_ulonglong) for n in ("r", "w", "o", "rb", "wb", "ob")]

    class BASIC(ctypes.Structure):
        _fields_ = [("PerProcessUserTimeLimit", ctypes.c_longlong),
                    ("PerJobUserTimeLimit", ctypes.c_longlong),
                    ("LimitFlags", wintypes.DWORD),
                    ("MinimumWorkingSetSize", ctypes.c_size_t),
                    ("MaximumWorkingSetSize", ctypes.c_size_t),
                    ("ActiveProcessLimit", wintypes.DWORD),
                    ("Affinity", ctypes.c_size_t),
                    ("PriorityClass", wintypes.DWORD),
                    ("SchedulingClass", wintypes.DWORD)]

    class EXTENDED(ctypes.Structure):
        _fields_ = [("BasicLimitInformation", BASIC), ("IoInfo", IO_COUNTERS),
                    ("ProcessMemoryLimit", ctypes.c_size_t), ("JobMemoryLimit", ctypes.c_size_t),
                    ("PeakProcessMemoryUsed", ctypes.c_size_t), ("PeakJobMemoryUsed", ctypes.c_size_t)]

    info = EXTENDED()
    info.BasicLimitInformation.LimitFlags = 0x2000          # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    if not k32.SetInformationJobObject(wintypes.HANDLE(job), 9, ctypes.byref(info), ctypes.sizeof(info)):
        return None                                         # 9 = JobObjectExtendedLimitInformation
    _job = (k32, job)
    return _job


def bind_to_supervisor(proc):
    """Make sure `proc` cannot outlive the supervisor."""
    if IS_WIN:
        j = _windows_job()
        if j:
            from ctypes import wintypes
            k32, job = j
            k32.AssignProcessToJobObject(wintypes.HANDLE(job), wintypes.HANDLE(int(proc._handle)))


def _proc_command(pid):
    try:
        return subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True,
                              text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def record_children(children):
    if IS_WIN:
        return                                              # the Job object covers Windows
    # identify each child by its most distinctive argument, not argv[0]: some python
    # builds re-execute themselves, so "ps" can show a different interpreter path
    tags = {"app": os.path.join(APP, "server.py"), "translate": "libretranslate.main"}
    pids = {c.spec.name: {"pid": c.proc.pid, "tag": tags.get(c.spec.name, c.spec.cmd[0])}
            for c in children if c.proc and c.proc.poll() is None}
    try:
        with open(PIDFILE, "w", encoding="utf-8") as f:
            json.dump(pids, f)
    except OSError:
        pass


def reap_orphans():
    """Stop children left behind by a supervisor that died without cleaning up.
    Only processes whose command line still matches what we started are touched,
    so a recycled PID belonging to something else is never killed."""
    if IS_WIN:
        return
    try:
        with open(PIDFILE, encoding="utf-8") as f:
            old = json.load(f)
    except (OSError, ValueError):
        return
    for name, info in old.items():
        pid, tag = int(info.get("pid", 0)), info.get("tag", "")
        if pid > 1 and tag and tag in _proc_command(pid):
            say("%-9s stopping a copy left over from an earlier run (pid %d)" % (name, pid))
            try:
                os.killpg(pid, signal.SIGTERM)
            except OSError:
                try:
                    os.kill(pid, signal.SIGTERM)
                except OSError:
                    pass
            for _ in range(20):
                if not _proc_command(pid):
                    break
                time.sleep(0.5)
    try:
        os.remove(PIDFILE)
    except OSError:
        pass


# ---------------------------------------------------------------- supervisor

class Child:
    def __init__(self, spec):
        self.spec = spec
        self.proc = None
        self.started = 0.0
        self.restarts = 0
        self.backoff = 3.0
        self.next_start = 0.0
        self.lock = threading.Lock()

    def start(self):
        s = self.spec
        log = _open_log(s.name)
        log.write(("\n===== %s starting: %s\n" % (time.ctime(), " ".join(s.cmd))).encode("utf-8", "replace"))
        kw = {}
        if IS_WIN:
            kw["creationflags"] = (subprocess.CREATE_NEW_PROCESS_GROUP |
                                   getattr(subprocess, "CREATE_NO_WINDOW", 0))
        else:
            kw["start_new_session"] = True    # own process group, so stop reaches its children
        self.proc = subprocess.Popen(s.cmd, cwd=s.cwd, env=s.env, stdin=subprocess.DEVNULL,
                                     stdout=log, stderr=subprocess.STDOUT, **kw)
        log.close()                            # the child holds its own handle
        bind_to_supervisor(self.proc)
        self.started = time.time()
        say("%-9s started (pid %d)" % (s.name, self.proc.pid))

    def stop(self):
        with self.lock:
            if self.proc and self.proc.poll() is None:
                kill_tree(self.proc)
                say("%-9s stopped" % self.spec.name)

    def state(self):
        s = self.spec
        if s.missing:
            st = "not installed"
        elif self.proc and self.proc.poll() is None:
            st = "running"
        else:
            st = "restarting"
        return {"name": s.name, "state": st, "port": s.port,
                "pid": self.proc.pid if self.proc and self.proc.poll() is None else None,
                "uptime": int(time.time() - self.started) if st == "running" else 0,
                "restarts": self.restarts, "missing": s.missing}


# ---------------------------------------------------------------- classroom Wi-Fi
# The box's main job is serving a room with no internet and no router: it broadcasts
# its own Wi-Fi and the students' devices join it. On Linux that is a persistent
# NetworkManager hotspot (install.sh sets it up; NetworkManager keeps it up). On
# Windows the supervisor keeps Mobile Hotspot on: it checks every minute, because
# Windows turns the hotspot off after a reboot, after sleep, and when no device has
# been connected for a while. Settings live in HOME/hotspot.json (written by the
# installer): {"enabled": true, "ssid": "Lunis", "password": "..."}.

HOTSPOT_FILE = os.path.join(HOME, "hotspot.json")
HOTSPOT_CHECK_EVERY = 60


def hotspot_settings():
    try:
        with open(HOTSPOT_FILE, encoding="utf-8") as f:
            s = json.load(f) or {}
    except (OSError, ValueError):
        s = {}
    env = os.environ.get("LUNIS_HOTSPOT")
    if env is not None:
        s["enabled"] = env.lower() not in ("0", "false", "no", "off")
    s["enabled"] = bool(s.get("enabled", False))
    s.setdefault("ssid", "Lunis")
    s.setdefault("password", "")
    return s


def _powershell():
    root = os.environ.get("SystemRoot", r"C:\Windows")
    exe = os.path.join(root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
    return exe if os.path.isfile(exe) else "powershell"


def hotspot_call(action, settings=None):
    """Run the platform hotspot helper; returns its JSON status as a dict."""
    if not IS_WIN:
        return {"ok": False, "state": "unsupported"}
    cmd = [_powershell(), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
           "-File", os.path.join(HERE, "hotspot-windows.ps1"), action]
    if settings and action == "ensure":
        cmd += ["-Ssid", settings["ssid"]]
        if settings.get("password"):
            cmd += ["-Password", settings["password"]]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=90,
                             creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0)).stdout
        line = [l for l in out.splitlines() if l.strip().startswith("{")]
        return json.loads(line[-1]) if line else {"ok": False, "state": "error", "error": out.strip()[-300:]}
    except (OSError, ValueError, subprocess.TimeoutExpired) as e:
        return {"ok": False, "state": "error", "error": str(e)}


def hotspot_address():
    return "192.168.137.1" if IS_WIN else "10.42.0.1"


class HotspotKeeper:
    def __init__(self):
        self.settings = hotspot_settings()
        self.last = {"state": "disabled" if not self.settings["enabled"] else "starting"}
        self._said = None

    def enabled(self):
        return IS_WIN and self.settings["enabled"]

    def loop(self, stopping):
        while not stopping.is_set():
            self.settings = hotspot_settings()        # pick up edits without a restart
            if self.enabled():
                st = hotspot_call("ensure", self.settings)
                self.last = st
                msg = ("hotspot   %s - Wi-Fi \"%s\", students open http://%s:%d"
                       % ("started" if st.get("started") else "on", st.get("ssid"), hotspot_address(), APP_PORT)
                       if st.get("ok") else "hotspot   could not start: %s" % st.get("error"))
                if st.get("started") or (not st.get("ok") and msg != self._said) or self._said is None:
                    say(msg)
                self._said = msg
            else:
                self.last = {"state": "disabled"}
            stopping.wait(HOTSPOT_CHECK_EVERY)
        if self.enabled():
            hotspot_call("stop")
            say("hotspot   stopped")


class Supervisor:
    def __init__(self):
        self.children = [Child(s) for s in build_specs()]
        self.stopping = threading.Event()
        self.hotspot = HotspotKeeper()

    def child(self, name):
        for c in self.children:
            if c.spec.name == name:
                return c
        return None

    def run(self):
        reap_orphans()
        for c in self.children:
            if c.spec.missing:
                say("%-9s NOT STARTED - %s" % (c.spec.name, c.spec.missing))
            elif port_busy(c.spec.port):
                say("%-9s port %d is already in use - something else is running there; "
                    "will keep retrying" % (c.spec.name, c.spec.port))
        # the AI engine and translator first: they take the longest to load
        for name in ("llama", "translate", "app"):
            c = self.child(name)
            if c and not c.spec.missing:
                try:
                    c.start()
                except OSError as e:
                    say("%-9s could not start: %s" % (name, e))
                    c.next_start = time.time() + c.backoff
        record_children(self.children)
        hs = threading.Thread(target=self.hotspot.loop, args=(self.stopping,), daemon=True)
        hs.start()
        while not self.stopping.wait(1.0):
            now = time.time()
            for c in self.children:
                if c.spec.missing:
                    continue
                with c.lock:
                    alive = c.proc is not None and c.proc.poll() is None
                    if alive:
                        if now - c.started > 60:
                            c.backoff = 3.0                 # it has been healthy; forget past crashes
                        continue
                    if c.proc is not None and c.next_start == 0.0:
                        say("%-9s exited with code %s - restarting in %ds (see logs/%s.log)"
                            % (c.spec.name, c.proc.returncode, c.backoff, c.spec.name))
                        c.next_start = now + c.backoff
                        c.backoff = min(c.backoff * 2, 60.0)
                    if now >= c.next_start:
                        c.next_start = 0.0
                        c.restarts += 1
                        try:
                            c.start()
                            record_children(self.children)
                        except OSError as e:
                            say("%-9s could not start: %s" % (c.spec.name, e))
                            c.next_start = now + c.backoff
        for c in reversed(self.children):
            c.stop()
        hs.join(timeout=30)
        say("supervisor stopped")

    def restart(self, name):
        targets = [c for c in self.children if not c.spec.missing and (name in (None, "all") or c.spec.name == name)]
        for c in targets:
            with c.lock:
                if c.proc and c.proc.poll() is None:
                    kill_tree(c.proc)
                c.backoff = 3.0
                c.next_start = 0.0
                c.restarts += 1
                c.start()
        record_children(self.children)
        return [c.spec.name for c in targets]

    def status(self):
        return {"supervisor_pid": os.getpid(), "home": HOME,
                "services": [c.state() for c in self.children],
                "hotspot": self.hotspot.last}


def serve_control(sup, sock):
    """Tiny line protocol on 127.0.0.1:CONTROL_PORT: 'status', 'stop', 'restart [name]'."""
    sock.settimeout(1.0)
    while not sup.stopping.is_set():
        try:
            conn, _ = sock.accept()
        except socket.timeout:
            continue
        except OSError:
            break
        with conn:
            try:
                conn.settimeout(5)
                req = conn.recv(256).decode("utf-8", "replace").strip().split()
                cmd = req[0] if req else ""
                if cmd == "status":
                    out = sup.status()
                elif cmd == "stop":
                    out = {"ok": True}
                    sup.stopping.set()
                elif cmd == "restart":
                    out = {"restarted": sup.restart(req[1] if len(req) > 1 else None)}
                else:
                    out = {"error": "unknown command"}
                conn.sendall(json.dumps(out).encode("utf-8"))
            except Exception as e:
                try:
                    conn.sendall(json.dumps({"error": str(e)}).encode("utf-8"))
                except OSError:
                    pass


def control(cmd, timeout=30.0):
    """Send one command to a running supervisor. None if none is running."""
    try:
        with socket.create_connection(("127.0.0.1", CONTROL_PORT), timeout=timeout) as s:
            s.sendall(cmd.encode("utf-8"))
            s.shutdown(socket.SHUT_WR)
            data = b""
            while True:
                chunk = s.recv(65536)
                if not chunk:
                    break
                data += chunk
        return json.loads(data.decode("utf-8") or "{}")
    except (OSError, ValueError):
        return None


# ---------------------------------------------------------------- deliberate stop
# Windows' Scheduled Task re-runs "run" every few minutes so a killed supervisor
# comes back. A deliberate "stop" must stick, so it leaves a marker that "run"
# honours - until the next reboot (a box that was rebooted should come up) or an
# explicit "start".

STOP_FLAG = os.path.join(HOME, "stopped")
TASK_NAME = "Lunis Server"


def boot_time():
    try:
        if IS_WIN:
            import ctypes
            ctypes.windll.kernel32.GetTickCount64.restype = ctypes.c_ulonglong
            return time.time() - ctypes.windll.kernel32.GetTickCount64() / 1000.0
        with open("/proc/uptime") as f:
            return time.time() - float(f.read().split()[0])
    except Exception:
        return 0.0


def stopped_on_purpose():
    try:
        with open(STOP_FLAG, encoding="utf-8") as f:
            when = float(f.read().strip() or 0)
    except (OSError, ValueError):
        return False
    if when < boot_time():                  # stopped before the last reboot: forget it
        try:
            os.remove(STOP_FLAG)
        except OSError:
            pass
        return False
    return True


def set_stop_flag(on):
    try:
        if on:
            os.makedirs(HOME, exist_ok=True)
            with open(STOP_FLAG, "w", encoding="utf-8") as f:
                f.write(str(time.time()))
        elif os.path.exists(STOP_FLAG):
            os.remove(STOP_FLAG)
    except OSError:
        pass


# ---------------------------------------------------------------- commands

def keep_awake():
    """A server that falls asleep serves nobody. While the supervisor runs, block
    idle SYSTEM sleep (the display may still turn off). No admin rights needed.
    Set "prevent_sleep": false in config.json to opt out. Closing a laptop lid can
    still put it to sleep - see docs/WINDOWS_SERVER.md."""
    if str(conf("prevent_sleep", "true")).lower() in ("0", "false", "no"):
        return
    try:
        if IS_WIN:
            ES_CONTINUOUS, ES_SYSTEM_REQUIRED = 0x80000000, 0x00000001
            import ctypes
            ctypes.windll.kernel32.SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)
            say("keeping the PC awake while Lunis runs")
    except Exception as e:
        say("could not block sleep: %s" % e)


def cmd_run():
    global _say_file
    if stopped_on_purpose():
        say("Lunis was stopped on purpose - not starting (use 'start' to start it).")
        return 0
    lock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):      # Windows: nobody else may share the port
        lock.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
    else:                                          # Unix: allow re-binding right after a restart
        lock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        lock.bind(("127.0.0.1", CONTROL_PORT))
    except OSError:
        say("Lunis is already running (another supervisor holds port %d)." % CONTROL_PORT)
        return 0
    lock.listen(4)
    _say_file = _open_log("supervisor")
    say("Lunis supervisor starting - repo %s, home %s" % (REPO, HOME))
    sup = Supervisor()
    keep_awake()      # same thread as the main loop: SetThreadExecutionState is per-thread

    def _quit(*_):
        sup.stopping.set()
    signal.signal(signal.SIGINT, _quit)
    signal.signal(signal.SIGTERM, _quit)
    if hasattr(signal, "SIGBREAK"):
        signal.signal(signal.SIGBREAK, _quit)

    threading.Thread(target=serve_control, args=(sup, lock), daemon=True).start()
    try:
        sup.run()
    finally:
        lock.close()
    return 0


def _probe_line(name, port, path):
    code = http_code(port, path)
    return "%-9s :%-5d %s" % (name, port, "answering (HTTP %d)" % code if code else "not answering")


def cmd_status():
    st = control("status", timeout=5)
    if st is None:
        print("Supervisor: not running")
    else:
        print("Supervisor: running (pid %s)" % st.get("supervisor_pid"))
        for s in st.get("services", []):
            extra = ""
            if s["state"] == "running":
                extra = "pid %s, up %ds, restarts %d" % (s["pid"], s["uptime"], s["restarts"])
            elif s.get("missing"):
                extra = s["missing"]
            print("  %-9s %-13s %s" % (s["name"], s["state"], extra))
        hs = st.get("hotspot") or {}
        if hs.get("state") not in (None, "disabled"):
            if hs.get("ok"):
                print("  %-9s %-13s Wi-Fi \"%s\", %s device(s) connected - students open http://%s:%d"
                      % ("hotspot", hs.get("state", "?").lower(), hs.get("ssid"), hs.get("clients", 0),
                         hotspot_address(), APP_PORT))
            else:
                print("  %-9s %-13s %s" % ("hotspot", hs.get("state", "?"), hs.get("error", "")))
    print("Health:")
    print("  " + _probe_line("app", APP_PORT, "/"))
    print("  " + _probe_line("llama", LLAMA_PORT, "/health"))
    print("  " + _probe_line("translate", LT_PORT, "/languages"))
    print("Logs: %s" % LOGS)
    return 0 if http_code(APP_PORT, "/") == 200 else 1


def cmd_stop():
    set_stop_flag(True)
    r = control("stop", timeout=5)
    if r is None:
        print("Supervisor: not running")
        return 0
    for _ in range(40):                      # wait until it has stopped its children
        time.sleep(0.5)
        if control("status", timeout=2) is None:
            print("Stopped.")
            return 0
    print("Asked the supervisor to stop; it is still shutting down.")
    return 1


def cmd_start():
    set_stop_flag(False)
    if control("status", timeout=3) is not None:
        print("Already running.")
        return 0
    started = False
    if IS_WIN:
        started = subprocess.run(["schtasks", "/run", "/tn", TASK_NAME], capture_output=True,
                                 creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0)).returncode == 0
    if not started:                          # no auto-start registered: run detached ourselves
        exe = sys.executable
        if IS_WIN:
            w = os.path.join(os.path.dirname(exe), "pythonw.exe")
            exe = w if os.path.isfile(w) else exe
            subprocess.Popen([exe, os.path.abspath(__file__), "run"], cwd=REPO,
                             creationflags=subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            subprocess.Popen([exe, os.path.abspath(__file__), "run"], cwd=REPO, start_new_session=True,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(20):
        time.sleep(0.5)
        if control("status", timeout=2) is not None:
            print("Started. (The AI model takes a minute to load.)")
            return 0
    print("Start requested; the supervisor is not answering yet - check: status")
    return 1


def cmd_restart(name):
    r = control("restart %s" % (name or "all"), timeout=60)
    if r is None:
        print("RESTART_FAILED (supervisor not running - start it first)")
        return 1
    if r.get("error"):
        print("RESTART_FAILED (%s)" % r["error"])
        return 1
    if name in (None, "all", "app"):
        for _ in range(30):
            time.sleep(1)
            if http_code(APP_PORT, "/") == 200:
                print("RESTARTED_OK (HTTP 200) - %s" % ", ".join(r.get("restarted", [])))
                return 0
        print("RESTART_FAILED (app not answering on :%d; see %s)" % (APP_PORT, os.path.join(LOGS, "app.log")))
        return 1
    print("RESTARTED_OK - %s" % ", ".join(r.get("restarted", [])))
    return 0


def save_hotspot_settings(s):
    os.makedirs(HOME, exist_ok=True)
    tmp = HOTSPOT_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"enabled": s["enabled"], "ssid": s["ssid"], "password": s["password"]}, f, indent=2)
    os.replace(tmp, HOTSPOT_FILE)


def cmd_hotspot(args):
    """hotspot [status] | hotspot on [--ssid NAME] [--password PASS] | hotspot off"""
    action = args[0] if args else "status"
    s = hotspot_settings()
    if action in ("on", "off"):
        i = 1
        while i < len(args) - 1:
            if args[i] in ("--ssid", "--password"):
                s[args[i][2:]] = args[i + 1]
                i += 2
            else:
                i += 1
        if action == "on":
            if not s["ssid"] or len(s["ssid"]) > 32:
                print("The Wi-Fi name must be 1-32 characters.")
                return 2
            if not (8 <= len(s["password"]) <= 63):
                print("The Wi-Fi password must be 8-63 characters (--password ...).")
                return 2
        s["enabled"] = action == "on"
        save_hotspot_settings(s)
        if not IS_WIN:
            print("Saved. On %s the hotspot is managed by the OS - see the server docs." % platform.system())
            return 0
        st = hotspot_call("ensure" if action == "on" else "stop", s)
    elif action == "status":
        st = hotspot_call("status") if IS_WIN else {"ok": False, "state": "unsupported"}
    else:
        print(cmd_hotspot.__doc__)
        return 2
    print("Hotspot: %s (auto-start %s)" % (st.get("state", "?"), "on" if s["enabled"] else "off"))
    if st.get("ok"):
        print("  Wi-Fi name: %s" % st.get("ssid"))
        if s.get("password"):
            print("  Password:   %s" % s["password"])
        print("  Devices:    %s of %s" % (st.get("clients", 0), st.get("max_clients", "?")))
        print("  Students open: http://%s:%d" % (hotspot_address(), APP_PORT))
    elif st.get("error"):
        print("  " + st["error"])
    return 0 if st.get("ok") or action == "off" else 1


def cmd_paths():
    out = {"repo": REPO, "home": HOME, "logs": LOGS,
           "python": python_for_children(),
           "llama_server": find_llama_server(), "model": find_model(),
           "model_dir": os.path.join(HOME, "models"), "model_file": MODEL,
           "libretranslate_python": find_translate_python(),
           "ports": {"app": APP_PORT, "llama": LLAMA_PORT, "translate": LT_PORT}}
    print(json.dumps(out, indent=2))
    return 0


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    cmd = argv[0]
    if cmd == "run":
        return cmd_run()
    if cmd == "status":
        return cmd_status()
    if cmd == "stop":
        return cmd_stop()
    if cmd == "start":
        return cmd_start()
    if cmd == "restart":
        return cmd_restart(argv[1] if len(argv) > 1 else None)
    if cmd == "paths":
        return cmd_paths()
    if cmd == "hotspot":
        return cmd_hotspot(argv[1:])
    print("unknown command %r - try: run | start | status | stop | restart [app|llama|translate] | hotspot | paths" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
