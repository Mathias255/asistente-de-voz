@echo off
setlocal
powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File "%~dp0AsistenteVoz.ps1"
if errorlevel 1 (
  echo.
  echo No se pudo iniciar el asistente. Revisa que Windows PowerShell 5.1 este instalado.
  pause
)
