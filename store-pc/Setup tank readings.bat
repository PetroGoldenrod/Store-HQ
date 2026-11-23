@echo off
rem Store HQ: set up tank readings (every 2 hours, plus Read now) (Goldenrod). Keep this file next to tankread.ps1.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tankread.ps1" -Setup -Store 655675 -Site 011
