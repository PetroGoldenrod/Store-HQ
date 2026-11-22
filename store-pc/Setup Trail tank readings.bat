@echo off
rem Store HQ: set up tank readings every 6 hours (Trail). Keep this file next to tankread.ps1.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tankread.ps1" -Setup -Store 654287 -Site 004
