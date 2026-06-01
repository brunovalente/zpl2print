@echo off
setlocal EnableExtensions EnableDelayedExpansion

:: ============================================================
:: CONFIGURACOES - ajuste conforme seu ambiente
:: ============================================================
set "PRINTER_SHARE=ZEBRA"
:: KEEP_ZPL: 0=deleta o .zpl apos imprimir, 1=mantem para debug
set "KEEP_ZPL=1"
:: QUEUE_CHECK_SECONDS: aguarda N segundos e verifica se o job saiu da fila
set "QUEUE_CHECK_SECONDS=2"
:: QUEUE_MAX_WAIT_SECONDS: tempo maximo (s) aguardando a fila drenar; etiquetas grandes demoram >2s
set "QUEUE_MAX_WAIT_SECONDS=30"
:: AUTO_PORT_FAILOVER: 1=tenta trocar porta automaticamente quando a fila trava
set "AUTO_PORT_FAILOVER=1"
:: ============================================================

set "BASE=%~dp0"
set "LOG_DIR=%BASE%logs"
set "LOG_FILE=%LOG_DIR%\print-events.log"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%" >nul 2>&1

set "INPUT="
set "CURRENT_FILE="
set "SOURCE_TYPE="
set "GENERATED_ZPL="
set "PRINT_SOURCE_FILE="
set "SANITIZED_ZPL="
set "EXIT_CODE=0"
set "FINAL_ERROR_MSG="

call :clear_share_queue "start"

:: Valida argumento
if "%~1"=="" (
    call :log ERROR missing_argument "argumento_arquivo_nao_informado"
    echo Uso: arraste um arquivo .xml ou .zpl sobre este .bat ou execute:
    echo   print-xml-zpl.bat caminho\para\arquivo.xml
    echo   print-xml-zpl.bat caminho\para\arquivo.zpl
    pause
    set "EXIT_CODE=1"
    goto :finalize
)

set "INPUT=%~1"
set "CURRENT_FILE=%INPUT%"
set "EXT=%~x1"
set "SOURCE_TYPE=%EXT%"

:: Valida extensao
if /I not "%EXT%"==".xml" if /I not "%EXT%"==".zpl" (
    call :log ERROR unsupported_extension "extensao_nao_suportada"
    echo ERRO: Extensao nao suportada: %EXT%
    echo Use arquivos .xml ou .zpl.
    pause
    set "EXIT_CODE=1"
    goto :finalize
)

:: Valida existencia do arquivo
if not exist "%INPUT%" (
    call :log ERROR file_not_found "arquivo_nao_encontrado"
    echo ERRO: Arquivo nao encontrado:
    echo   %INPUT%
    pause
    set "EXIT_CODE=1"
    goto :finalize
)

:: Bloco XML: converte para ZPL e imprime
if /I "%EXT%"==".xml" (
    where node >nul 2>&1
    if errorlevel 1 (
        call :log ERROR node_not_found "nodejs_nao_encontrado_no_path"
        echo ERRO: Node.js nao encontrado no PATH.
        echo Instale o Node.js e tente novamente.
        pause
        set "EXIT_CODE=1"
        goto :finalize
    )
    call :log INFO start "inicio_processamento_xml"
    set "GENERATED_ZPL=%~dpn1.zpl"
    node "%BASE%scripts\xml-to-zpl.js" "%INPUT%" "!GENERATED_ZPL!"
    if errorlevel 1 (
        call :log ERROR zpl_generate_failed "falha_ao_gerar_zpl"
        echo ERRO: Falha ao gerar o ZPL a partir do XML.
        pause
        set "EXIT_CODE=1"
        goto :finalize
    )
    call :log INFO zpl_generated "zpl_gerado_com_sucesso"
    set "PRINT_SOURCE_FILE=!GENERATED_ZPL!"
    if not exist "!PRINT_SOURCE_FILE!" (
        if exist "%BASE%temp\danfe-97x150.zpl" set "PRINT_SOURCE_FILE=%BASE%temp\danfe-97x150.zpl"
    )
    if not exist "!PRINT_SOURCE_FILE!" (
        call :resolve_latest_zpl "%~dp1" PRINT_SOURCE_FILE
    )
    if not exist "!PRINT_SOURCE_FILE!" (
        call :log ERROR generated_zpl_not_found "zpl_gerado_nao_localizado_para_impressao"
        echo ERRO: O ZPL gerado nao foi localizado para envio a impressora.
        set "EXIT_CODE=1"
        set "FINAL_ERROR_MSG=Falha ao localizar arquivo ZPL gerado."
        goto :finalize
    )
)

:: Bloco ZPL: imprime diretamente
if /I "%EXT%"==".zpl" (
    call :log INFO start "inicio_processamento_zpl"
    set "PRINT_SOURCE_FILE=%INPUT%"
)

call :sanitize_zpl
call :print_with_failover "%PRINT_SOURCE_FILE%"
if errorlevel 1 (
    set "EXIT_CODE=1"
    set "FINAL_ERROR_MSG=Falha ao imprimir em todas as portas Zebra disponiveis."
    goto :finalize
)

call :log INFO printed_success "zpl_enviado_para_impressora"
echo ZPL enviado com sucesso para "\\localhost\%PRINTER_SHARE%"

if /I "%EXT%"==".xml" (
    if "%KEEP_ZPL%"=="0" (
        del "%GENERATED_ZPL%" >nul 2>&1
        call :log INFO zpl_deleted "arquivo_zpl_removido"
    ) else (
        call :log INFO zpl_kept "arquivo_zpl_mantido_para_debug"
        echo ZPL mantido em:
        echo   %GENERATED_ZPL%
    )
)

:finalize
call :clear_share_queue "end"
if defined SANITIZED_ZPL if "%KEEP_ZPL%"=="0" if exist "%SANITIZED_ZPL%" del "%SANITIZED_ZPL%" >nul 2>&1
if not "%EXIT_CODE%"=="0" (
    if not defined FINAL_ERROR_MSG set "FINAL_ERROR_MSG=Execucao finalizada com erro."
    call :log ERROR finished_with_error "execucao_finalizada_com_erro"
    echo ERRO: !FINAL_ERROR_MSG!
    if defined GENERATED_ZPL if exist "!GENERATED_ZPL!" echo ZPL gerado: !GENERATED_ZPL!
    endlocal
    exit /b 1
)

call :log INFO finished_ok "execucao_finalizada_com_sucesso"
endlocal
exit /b 0

:log
set "LOG_LEVEL=%~1"
set "LOG_EVENT=%~2"
set "LOG_MESSAGE=%~3"
set "PS_TMP=%TEMP%\zpl2print_ts_%RANDOM%.ps1"
echo (Get-Date).ToUniversalTime().AddHours(-3).ToString('yyyy-MM-dd HH:mm:ss') > "%PS_TMP%"
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_TMP%" 2^>nul`) do set "LOG_TS=%%I"
del "%PS_TMP%" >nul 2>&1
>> "%LOG_FILE%" echo [%LOG_TS% UTC-3] [%LOG_LEVEL%] [print-xml-zpl.bat] [%LOG_EVENT%] type="%SOURCE_TYPE%" file="%CURRENT_FILE%" printer="%PRINTER_SHARE%" message="%LOG_MESSAGE%"
exit /b 0

:check_queue_health
call :resolve_share_printer
if errorlevel 1 (
    call :log WARN queue_check_skipped "share_nao_encontrado_para_verificar_fila"
    exit /b 0
)
call :wait_and_get_queue_count "%SHARE_PRINTER_NAME%" QUEUE_PENDING_COUNT
if !QUEUE_PENDING_COUNT! GTR 0 (
    call :log WARN queue_pending "fila_nao_foi_consumida_apos_envio"
    echo AVISO: O arquivo foi enviado, mas ainda ha !QUEUE_PENDING_COUNT! job^(s^) na fila "!SHARE_PRINTER_NAME!".
    echo        Verifique porta/fila da impressora para evitar travamento de impressao.
) else (
    call :log INFO queue_consumed "fila_consumida_apos_envio"
)
exit /b 0

:resolve_latest_zpl
set "%~2="
set "PS_TMP=%TEMP%\zpl2print_latestzpl_%RANDOM%.ps1"
(
    echo $d = '%~1'
    echo try { $f = Get-ChildItem -Path $d -Filter '*.zpl' -File -ErrorAction Stop ^| Sort-Object LastWriteTime -Descending ^| Select-Object -First 1 -ExpandProperty FullName; if ^($f^) { $f } } catch { '' }
) > "%PS_TMP%"
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_TMP%" 2^>nul`) do set "%~2=%%I"
del "%PS_TMP%" >nul 2>&1
exit /b 0

:print_with_failover
set "FILE_TO_PRINT=%~1"
call :attempt_send_and_check "%FILE_TO_PRINT%"
if not errorlevel 1 exit /b 0

if not "%AUTO_PORT_FAILOVER%"=="1" (
    call :log ERROR print_failed_no_failover "falha_impressao_sem_failover"
    exit /b 1
)

call :resolve_share_printer
if errorlevel 1 (
    call :log ERROR printer_share_not_found "nao_foi_possivel_localizar_impressora_compartilhada"
    exit /b 1
)

set "ORIGINAL_SHARE_PORT=%SHARE_PRINTER_PORT%"
set "FAILOVER_SUCCESS="
set "PS_TMP=%TEMP%\zpl2print_failover_%RANDOM%.ps1"
(
    echo $share = '%PRINTER_SHARE%'
    echo $sp = Get-Printer ^| Where-Object { $_.ShareName -eq $share } ^| Select-Object -First 1
    echo if ^($sp^) { $current = $sp.PortName; Get-Printer ^| Where-Object { $_.Name -match 'Zebra^|ZDesigner' -or $_.DriverName -match 'Zebra^|ZDesigner' } ^| Select-Object -ExpandProperty PortName -Unique ^| Where-Object { $_ -and $_ -ne $current } }
) > "%PS_TMP%"
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_TMP%" 2^>nul`) do (
    set "TRY_PORT=%%I"
    call :log WARN failover_port_try "tentando_failover_porta_!TRY_PORT!"
    call :switch_share_port "!TRY_PORT!"
    if errorlevel 1 (
        call :log WARN failover_port_switch_failed "falha_ao_alterar_porta_compartilhada"
    ) else (
        call :attempt_send_and_check "%FILE_TO_PRINT%"
        if not errorlevel 1 (
            set "FAILOVER_SUCCESS=1"
            call :log INFO failover_success "impressao_com_failover_de_porta"
            goto :print_with_failover_done
        )
    )
)
del "%PS_TMP%" >nul 2>&1

:print_with_failover_done
if defined FAILOVER_SUCCESS exit /b 0
if defined ORIGINAL_SHARE_PORT call :switch_share_port "%ORIGINAL_SHARE_PORT%" >nul 2>&1
call :clear_share_queue "failure_cleanup"
call :log ERROR print_failed_all_ports "falha_em_todas_as_portas_zebra"
exit /b 1

:attempt_send_and_check
set "FILE_TO_PRINT=%~1"
if not exist "%FILE_TO_PRINT%" (
    call :log ERROR print_source_not_found "arquivo_de_impressao_nao_encontrado"
    exit /b 1
)
call :resolve_share_printer
if errorlevel 1 (
    call :log ERROR printer_share_not_found "nao_foi_possivel_localizar_impressora_compartilhada"
    exit /b 1
)
call :get_queue_count "%SHARE_PRINTER_NAME%" QUEUE_BEFORE
copy /b "%FILE_TO_PRINT%" "\\localhost\%PRINTER_SHARE%" >nul
if errorlevel 1 (
    call :log WARN print_send_failed "falha_no_envio_raw_para_share"
    exit /b 1
)
call :wait_queue_drain "%SHARE_PRINTER_NAME%" "!QUEUE_BEFORE!"
if "!DRAIN_RESULT!"=="1" (
    call :log INFO queue_consumed "fila_consumida_apos_envio"
    exit /b 0
)
call :log WARN queue_stuck "fila_nao_drenou_em_!QUEUE_MAX_WAIT_SECONDS!s"
exit /b 1

:resolve_share_printer
set "SHARE_PRINTER_NAME="
set "SHARE_PRINTER_PORT="
set "PS_TMP=%TEMP%\zpl2print_resolve_%RANDOM%.ps1"
(
    echo $share = '%PRINTER_SHARE%'
    echo $p = Get-Printer ^| Where-Object { $_.ShareName -eq $share } ^| Select-Object -First 1
    echo if ^($p^) { Write-Output ^($p.Name + [char]167 + $p.PortName^) }
) > "%PS_TMP%"
for /f "usebackq tokens=1* delims=§" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_TMP%" 2^>nul`) do (
    set "SHARE_PRINTER_NAME=%%I"
    set "SHARE_PRINTER_PORT=%%J"
)
del "%PS_TMP%" >nul 2>&1
if not defined SHARE_PRINTER_NAME exit /b 1
exit /b 0

:get_queue_count
set "QUEUE_COUNT=0"
set "PS_TMP=%TEMP%\zpl2print_qcount_%RANDOM%.ps1"
(
    echo $pn = '%~1'
    echo try { [int]^(^(Get-PrintJob -PrinterName $pn -ErrorAction Stop ^| Measure-Object^).Count^) } catch { 0 }
) > "%PS_TMP%"
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_TMP%" 2^>nul`) do set "QUEUE_COUNT=%%I"
del "%PS_TMP%" >nul 2>&1
if not defined QUEUE_COUNT set "QUEUE_COUNT=0"
echo(!QUEUE_COUNT!| findstr /r "^[0-9][0-9]*$" >nul
if errorlevel 1 set "QUEUE_COUNT=0"
set "%~2=%QUEUE_COUNT%"
exit /b 0

:wait_and_get_queue_count
set "QUEUE_COUNT=0"
set "PS_TMP=%TEMP%\zpl2print_qwait_%RANDOM%.ps1"
(
    echo Start-Sleep -Seconds %QUEUE_CHECK_SECONDS%
    echo $pn = '%~1'
    echo try { [int]^(^(Get-PrintJob -PrinterName $pn -ErrorAction Stop ^| Measure-Object^).Count^) } catch { 0 }
) > "%PS_TMP%"
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_TMP%" 2^>nul`) do set "QUEUE_COUNT=%%I"
del "%PS_TMP%" >nul 2>&1
if not defined QUEUE_COUNT set "QUEUE_COUNT=0"
echo(!QUEUE_COUNT!| findstr /r "^[0-9][0-9]*$" >nul
if errorlevel 1 set "QUEUE_COUNT=0"
set "%~2=%QUEUE_COUNT%"
exit /b 0

:switch_share_port
set "NEW_PORT=%~1"
if "%NEW_PORT%"=="" exit /b 1
call :resolve_share_printer
if errorlevel 1 exit /b 1
set "SWITCH_RESULT=FAIL"
set "PS_TMP=%TEMP%\zpl2print_switch_%RANDOM%.ps1"
(
    echo $pn = '%SHARE_PRINTER_NAME%'
    echo $port = '%NEW_PORT%'
    echo try { Set-Printer -Name $pn -PortName $port -ErrorAction Stop; 'OK' } catch { 'FAIL' }
) > "%PS_TMP%"
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_TMP%" 2^>nul`) do set "SWITCH_RESULT=%%I"
del "%PS_TMP%" >nul 2>&1
if /I "%SWITCH_RESULT%"=="OK" (
    call :log INFO failover_port_switched "porta_compartilhada_alterada_com_sucesso"
    exit /b 0
)
exit /b 1

:clear_share_queue
set "CLEAR_PHASE=%~1"
call :resolve_share_printer
if errorlevel 1 (
    call :log WARN queue_clear_skipped "share_nao_encontrado_para_limpeza_!CLEAR_PHASE!"
    exit /b 0
)
set "REMOVED_JOBS=0"
set "PS_TMP=%TEMP%\zpl2print_clearq_%RANDOM%.ps1"
(
    echo $pn = '%SHARE_PRINTER_NAME%'
    echo try { $jobs = Get-PrintJob -PrinterName $pn -ErrorAction Stop; $c = ^($jobs ^| Measure-Object^).Count; if ^($c -gt 0^) { $jobs ^| Remove-PrintJob -Confirm:$false -ErrorAction SilentlyContinue }; [int]$c } catch { 0 }
) > "%PS_TMP%"
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_TMP%" 2^>nul`) do set "REMOVED_JOBS=%%I"
del "%PS_TMP%" >nul 2>&1
if not defined REMOVED_JOBS set "REMOVED_JOBS=0"
echo(!REMOVED_JOBS!| findstr /r "^[0-9][0-9]*$" >nul
if errorlevel 1 set "REMOVED_JOBS=0"
if !REMOVED_JOBS! GTR 0 (
    call :log INFO queue_cleared "fila_limpa_!CLEAR_PHASE!_jobs_!REMOVED_JOBS!"
) else (
    call :log INFO queue_already_empty "fila_ja_estava_vazia_!CLEAR_PHASE!"
)
exit /b 0

:sanitize_zpl
:: Saneia o ZPL (corrige coordenadas fracionarias e ^PW > 832) antes de imprimir.
where node >nul 2>&1
if errorlevel 1 (
    call :log WARN sanitize_skipped "node_indisponivel_envio_sem_saneamento"
    exit /b 0
)
if not exist "%PRINT_SOURCE_FILE%" exit /b 0
set "SANITIZED_ZPL=%PRINT_SOURCE_FILE%.san.zpl"
node "%BASE%scripts\sanitize-zpl.js" "%PRINT_SOURCE_FILE%" "%SANITIZED_ZPL%"
if errorlevel 1 (
    call :log WARN sanitize_failed "falha_no_saneamento_usando_original"
    set "SANITIZED_ZPL="
    exit /b 0
)
if not exist "%SANITIZED_ZPL%" (
    call :log WARN sanitize_no_output "saida_saneada_nao_gerada_usando_original"
    set "SANITIZED_ZPL="
    exit /b 0
)
set "PRINT_SOURCE_FILE=%SANITIZED_ZPL%"
call :log INFO sanitized "zpl_saneado_para_impressao"
exit /b 0

:wait_queue_drain
:: Aguarda a fila drenar ate QUEUE_MAX_WAIT_SECONDS. %1=impressora %2=contagem_base.
:: Define DRAIN_RESULT=1 se a fila voltou a <= base (job consumido), senao 0.
set "DRAIN_RESULT=0"
set "PS_TMP=%TEMP%\zpl2print_drain_%RANDOM%.ps1"
(
    echo $pn = '%~1'
    echo $base = [int]'%~2'
    echo $end = ^(Get-Date^).AddSeconds^(%QUEUE_MAX_WAIT_SECONDS%^)
    echo $ok = 0
    echo while ^(^(Get-Date^) -lt $end^) {
    echo   try { $c = [int]^(^(Get-PrintJob -PrinterName $pn -ErrorAction Stop ^| Measure-Object^).Count^) } catch { $c = 0 }
    echo   if ^($c -le $base^) { $ok = 1; break }
    echo   Start-Sleep -Milliseconds 700
    echo }
    echo $ok
) > "%PS_TMP%"
for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_TMP%" 2^>nul`) do set "DRAIN_RESULT=%%I"
del "%PS_TMP%" >nul 2>&1
if not defined DRAIN_RESULT set "DRAIN_RESULT=0"
exit /b 0
