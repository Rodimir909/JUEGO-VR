@echo off
setlocal
cd /d "%~dp0"
if exist ".venv\Scripts\python.exe" (
  ".venv\Scripts\python.exe" holistic_test.py %*
) else if exist "venv311\Scripts\python.exe" (
  "venv311\Scripts\python.exe" holistic_test.py %*
) else (
  python holistic_test.py %*
)
if errorlevel 1 pause
