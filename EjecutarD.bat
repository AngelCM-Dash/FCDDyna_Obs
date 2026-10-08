@ECHO OFF
SETLOCAL

CD /D "%~dp0"

SET "SCRIPT=%~dp0OneAgent-Diagnostics-Menu.ps1"

REM Ejecutar el PS1 como Administrador
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
"try { ^
    Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""%SCRIPT%""'; ^
    exit 0 ^
} catch { ^
    exit 1 ^
}" >NUL 2>&1

REM Si el usuario rechazo el UAC
IF ERRORLEVEL 1 (
    powershell.exe -NoProfile -Command ^
    "Add-Type -AssemblyName PresentationFramework; [System.Windows.MessageBox]::Show('Este programa requiere permisos de Administrador para ejecutarse.','Permisos requeridos',[System.Windows.MessageBoxButton]::OK,[System.Windows.MessageBoxImage]::Error) | Out-Null"

    EXIT /B 1
)

REM El PowerShell Administrador ya fue lanzado.
REM Cerrar la ventana negra del BAT.
ENDLOCAL
EXIT /B 0