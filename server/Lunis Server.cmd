@echo off
REM ============================================================
REM  Lunis server control panel (Windows).
REM  Shows what is running and lets you restart / stop / start it.
REM ============================================================
setlocal
title Lunis Server
set "SVC=%~dp0lunis_service.py"
where py >nul 2>&1 && (set "PY=py -3") || (set "PY=python")

:menu
cls
echo.
%PY% "%SVC%" status
echo.
echo   [1] Open Lunis in the browser     [5] Start
echo   [2] Restart the web app           [6] Open the logs folder
echo   [3] Restart everything            [7] Refresh
echo   [4] Stop                          [0] Close
echo.
choice /c 12345670 /n /m "  Choose: "
if errorlevel 8 goto :eof
if errorlevel 7 goto menu
if errorlevel 6 goto logs
if errorlevel 5 goto start
if errorlevel 4 goto stop
if errorlevel 3 goto restartall
if errorlevel 2 goto restartapp
start "" http://127.0.0.1:8090
goto menu

:restartapp
%PY% "%SVC%" restart app
pause
goto menu

:restartall
%PY% "%SVC%" restart all
pause
goto menu

:stop
%PY% "%SVC%" stop
pause
goto menu

:start
%PY% "%SVC%" start
pause
goto menu

:logs
for /f "usebackq delims=" %%L in (`%PY% -c "import sys; sys.path.insert(0, r'%~dp0.'); import lunis_service as s; print(s.LOGS)"`) do set "LOGDIR=%%L"
if not exist "%LOGDIR%" mkdir "%LOGDIR%"
start "" explorer "%LOGDIR%"
goto menu
