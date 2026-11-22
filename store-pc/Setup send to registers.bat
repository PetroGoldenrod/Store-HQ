@echo off
rem Store HQ: let the "Send to registers" button run VS-Poll on this PC (Goldenrod). Keep next to regsend.ps1.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0regsend.ps1" -Setup -Store 655675 -Site 011
