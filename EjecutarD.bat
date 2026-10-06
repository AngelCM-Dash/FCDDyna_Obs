@ECHO OFF
SETLOCAL

CD /D "%~dp0"

SET "SCRIPT=%~dp0OneAgent-Diagnostics-Menu.ps1"

REM Primer intento: como administrador
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
"try { Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""%SCRIPT%""'; exit 0 } catch { exit 1 }" >NUL 2>&1

REM Si se rechazo/cancelo el administrador, ejecutar normalmente
IF ERRORLEVEL 1 (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
)

PAUSE >NUL
ENDLOCAL