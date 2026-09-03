@echo off
setlocal

:: ============================================================
:: CONFIGURACAO
:: Nome local da impressora/fila que recebe os jobs RAW
:: ============================================================
set "PRINTER_NAME=ZEBRA"

if /I "%~1"=="status" goto :status
if /I "%~1"=="clear" goto :clear
if /I "%~1"=="restart" goto :restart
if /I "%~1"=="open" goto :open
if /I "%~1"=="help" goto :help

:menu
cls
echo ==========================================
echo   Zebra Spool - Ferramenta de Diagnostico
echo ==========================================
echo Impressora: %PRINTER_NAME%
echo.
echo [1] Ver fila (status)
echo [2] Limpar fila (clear)
echo [3] Reiniciar spooler (restart)
echo [4] Abrir janela da fila (open)
echo [0] Sair
echo.
set /p CHOICE=Escolha uma opcao: 

if "%CHOICE%"=="1" goto :status
if "%CHOICE%"=="2" goto :clear
if "%CHOICE%"=="3" goto :restart
if "%CHOICE%"=="4" goto :open
if "%CHOICE%"=="0" goto :eof
goto :menu

:status
echo.
echo --- STATUS DA IMPRESSORA ---
powershell -NoProfile -Command "Get-Printer -Name '%PRINTER_NAME%' | Select-Object Name,ShareName,PortName,PrinterStatus | Format-Table -AutoSize"
if errorlevel 1 (
  echo ERRO: Impressora '%PRINTER_NAME%' nao encontrada.
  goto :done
)
echo.
echo --- JOBS NA FILA ---
powershell -NoProfile -Command "$jobs = Get-PrintJob -PrinterName '%PRINTER_NAME%' -ErrorAction SilentlyContinue; if ($jobs) { $jobs | Select-Object ID,DocumentName,JobStatus,SubmittedTime,TotalPages | Format-Table -AutoSize } else { Write-Host 'Fila vazia.' }"
goto :done

:clear
echo.
echo Limpando fila da impressora '%PRINTER_NAME%'...
powershell -NoProfile -Command "$jobs = Get-PrintJob -PrinterName '%PRINTER_NAME%' -ErrorAction SilentlyContinue; if ($jobs) { $jobs | Remove-PrintJob; Write-Host 'Fila limpa com sucesso.' } else { Write-Host 'Fila ja estava vazia.' }"
goto :done

:restart
echo.
echo Reiniciando servico Spooler...
powershell -NoProfile -Command "Restart-Service Spooler -Force; Write-Host 'Spooler reiniciado com sucesso.'"
goto :done

:open
echo.
echo Abrindo janela da fila da impressora...
rundll32 printui.dll,PrintUIEntry /o /n "%PRINTER_NAME%"
goto :done

:help
echo.
echo Uso:
echo   print-check-spool.bat status
echo   print-check-spool.bat clear
echo   print-check-spool.bat restart
echo   print-check-spool.bat open
echo.
goto :done

:done
if not "%~1"=="" exit /b 0
echo.
pause
goto :menu
