@echo off
rem Store HQ: connect the Hikvision camera recorder (Goldenrod). Keep this file next to camread.ps1 and token.txt.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0camread.ps1" -Setup -Store 655675
