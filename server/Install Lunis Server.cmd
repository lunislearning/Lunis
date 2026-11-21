@echo off
REM ============================================================
REM  Lunis - make THIS Windows PC the classroom server.
REM  Double-click this file. Needs internet during install only.
REM ============================================================
title Lunis Server Setup
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-windows.ps1" %*
