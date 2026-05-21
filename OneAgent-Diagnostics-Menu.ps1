# OneAgent-Diagnostics-Menu.ps1
# Ejecutar como Administrador

$OneAgentCtl = "C:\Program Files\Dynatrace\OneAgent\agent\tools\oneagentctl.exe"
$LogRoot = "C:\ProgramData\dynatrace\oneagent\log"

function Write-Header($title) {
    Clear-Host
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host " Dynatrace OneAgent Diagnostics" -ForegroundColor Cyan
    Write-Host " $title" -ForegroundColor Cyan
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host ""
}

function Pause-Menu {
    Write-Host ""
    Read-Host "Presiona ENTER para continuar"
}

function Test-OneAgentCtl {
    if (-not (Test-Path $OneAgentCtl)) {
        Write-Host "No se encontro oneagentctl.exe en:" -ForegroundColor Red
        Write-Host $OneAgentCtl
        return $false
    }
    return $true
}

function Get-OneAgentBasicInfo {
    Write-Header "Informacion basica"

    Write-Host "Servicio Dynatrace:" -ForegroundColor Yellow
    Get-Service *dynatrace* -ErrorAction SilentlyContinue | Format-Table -AutoSize

    if (Test-OneAgentCtl) {
        Write-Host "`nVersion:" -ForegroundColor Yellow
        & $OneAgentCtl --version

        Write-Host "`nTenant actual:" -ForegroundColor Yellow
        & $OneAgentCtl --get-tenant

        Write-Host "`nServidor / endpoints:" -ForegroundColor Yellow
        & $OneAgentCtl --get-server

        Write-Host "`nNetwork Zone:" -ForegroundColor Yellow
        $nz = & $OneAgentCtl --get-network-zone
        if ([string]::IsNullOrWhiteSpace($nz)) {
            Write-Host "default / sin zona configurada"
        } else {
            Write-Host $nz
        }

        Write-Host "`nProxy:" -ForegroundColor Yellow
        $proxy = & $OneAgentCtl --get-proxy
        if ([string]::IsNullOrWhiteSpace($proxy)) {
            Write-Host "Sin proxy configurado"
        } else {
            Write-Host $proxy
        }
    }

    Pause-Menu
}

function Test-OneAgentProcesses {
    Write-Header "Procesos OneAgent"

    $processes = Get-Process | Where-Object {
        $_.ProcessName -like "*dynatrace*" -or $_.ProcessName -like "*ruxit*"
    }

    if ($processes) {
        $processes | Select-Object Id, ProcessName, CPU, StartTime -ErrorAction SilentlyContinue | Format-Table -AutoSize
    } else {
        Write-Host "No se encontraron procesos ruxit/dynatrace visibles." -ForegroundColor Yellow
        Write-Host "Esto no siempre significa que OneAgent este mal, pero requiere revisar logs."
    }

    Pause-Menu
}

function Test-OneAgentConnectivity {
    Write-Header "Prueba DNS y puerto 443"

    if (-not (Test-OneAgentCtl)) {
        Pause-Menu
        return
    }

    $tenant = & $OneAgentCtl --get-tenant
    $tenant = $tenant.Trim()

    if ([string]::IsNullOrWhiteSpace($tenant)) {
        Write-Host "No se pudo obtener el tenant actual." -ForegroundColor Red
        Pause-Menu
        return
    }

    $hostName = "$tenant.live.dynatrace.com"

    Write-Host "Tenant: $tenant"
    Write-Host "Host:   $hostName"
    Write-Host ""

    Write-Host "Resolviendo DNS..." -ForegroundColor Yellow
    try {
        Resolve-DnsName $hostName -ErrorAction Stop | Format-Table -AutoSize
    } catch {
        Write-Host "Error DNS: $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host "`nProbando puerto 443..." -ForegroundColor Yellow
    Test-NetConnection $hostName -Port 443

    Pause-Menu
}

function Get-RecommendedConnectionPatterns {
    return @(
        # Conexion correcta / sincronizacion
        "Connected successfully",
        "Registration successful",
        "Configuration received",
        "Communication upload statistics",
        "acked",
        "cluster time",
        "AgentId",

        # Problemas de tenant, gateway o comunicacion
        "http status: 410",
        "Connection to all gateways failed",
        "not working",
        "Could not resolve host",
        "Certificate check failed",
        "Heartbeat failed",
        "cluster time is not yet available",
        "Dropping package list report",
        "unauthorized",
        "forbidden",
        "authentication",
        "SSL",
        "TLS",
        "proxy",
        "tenant",
        "token"
    )
}

function Show-RecommendedLogLines {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogPath,

        [int]$TailLines = 600,

        [int]$MaxMatches = 40
    )

    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "Log:" -ForegroundColor Cyan
    Write-Host $LogPath
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray

    if (-not (Test-Path $LogPath)) {
        Write-Host "No se encontro el archivo de log." -ForegroundColor Red
        return
    }

    $patterns = Get-RecommendedConnectionPatterns
    $content = Get-Content $LogPath -Tail $TailLines -ErrorAction SilentlyContinue

    if (-not $content -or $content.Count -eq 0) {
        Write-Host "El log esta vacio o no se pudo leer." -ForegroundColor Yellow
        return
    }

    Write-Host "Lineas recomendadas para validar conexion con Dynatrace:" -ForegroundColor Yellow
    Write-Host "- Exitosas: Connected successfully, Registration successful, Communication upload statistics, acked, cluster time."
    Write-Host "- Problemas: http status: 410, Connection to all gateways failed, Could not resolve host, Certificate check failed, Heartbeat failed."
    Write-Host ""

    $matches = $content | Select-String -Pattern $patterns -SimpleMatch

    if ($matches) {
        Write-Host "Coincidencias encontradas en las ultimas $TailLines lineas:" -ForegroundColor Green
        $matches |
            Select-Object -Last $MaxMatches |
            ForEach-Object {
                $line = $_.Line

                if ($line -match "Connected successfully|Registration successful|acked|Communication upload statistics") {
                    Write-Host $line -ForegroundColor Green
                }
                elseif ($line -match "http status: 410|Connection to all gateways failed|Could not resolve host|Certificate check failed|Heartbeat failed|not working|unauthorized|forbidden|authentication") {
                    Write-Host $line -ForegroundColor Red
                }
                elseif ($line -match "cluster time is not yet available|Dropping package list report") {
                    Write-Host $line -ForegroundColor Yellow
                }
                else {
                    Write-Host $line
                }
            }
    } else {
        Write-Host "No se encontraron coincidencias clave en las ultimas $TailLines lineas." -ForegroundColor Yellow
        Write-Host "Mostrando las ultimas 20 lineas para revision manual:" -ForegroundColor Yellow
        $content | Select-Object -Last 20 | ForEach-Object { Write-Host $_ }
    }
}

function Get-LatestLogs {
    Write-Header "Ultimos logs"

    if (-not (Test-Path $LogRoot)) {
        Write-Host "No existe la carpeta de logs:" -ForegroundColor Red
        Write-Host $LogRoot
        Pause-Menu
        return
    }

    $logs = Get-ChildItem $LogRoot -Recurse -Filter "*.log" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 15

    if (-not $logs -or $logs.Count -eq 0) {
        Write-Host "No se encontraron archivos .log en:" -ForegroundColor Yellow
        Write-Host $LogRoot
        Pause-Menu
        return
    }

    Write-Host "Ultimos logs encontrados:" -ForegroundColor Yellow
    $logs |
        Select-Object `
            @{Name = "Nro"; Expression = { [array]::IndexOf($logs, $_) + 1 } },
            FullName,
            LastWriteTime,
            @{Name = "SizeKB"; Expression = { [math]::Round($_.Length / 1KB, 2) } } |
        Format-Table -AutoSize

    Write-Host ""
    $viewAnswer = Read-Host "Quieres visualizar lineas recomendadas de los ultimos logs? (S/N)"

    if ($viewAnswer -notmatch "^[sS]$") {
        Pause-Menu
        return
    }

    $countInput = Read-Host "Cuantos ultimos logs quieres visualizar? Ejemplo: 5, 8 o 10"
    $count = 0

    if (-not [int]::TryParse($countInput, [ref]$count)) {
        Write-Host "Valor invalido. Se usaran 5 logs por defecto." -ForegroundColor Yellow
        $count = 5
    }

    if ($count -lt 1) { $count = 1 }
    if ($count -gt $logs.Count) { $count = $logs.Count }

    $tailInput = Read-Host "Cuantas lineas finales revisar por cada log? Presiona ENTER para usar 600"
    $tailLines = 600

    if (-not [string]::IsNullOrWhiteSpace($tailInput)) {
        $parsedTail = 0
        if ([int]::TryParse($tailInput, [ref]$parsedTail) -and $parsedTail -gt 0) {
            $tailLines = $parsedTail
        } else {
            Write-Host "Valor invalido. Se usaran 600 lineas por defecto." -ForegroundColor Yellow
        }
    }

    Write-Host ""
    Write-Host "Visualizando los ultimos $count logs. Por cada log se imprimen lineas clave para validar el estado de conexion." -ForegroundColor Cyan

    $logsToView = $logs | Select-Object -First $count

    foreach ($log in $logsToView) {
        Show-RecommendedLogLines -LogPath $log.FullName -TailLines $tailLines -MaxMatches 40
    }

    Pause-Menu
}

function Read-ImportantLogs {
    Write-Header "Analisis rapido de logs"

    if (-not (Test-Path $LogRoot)) {
        Write-Host "No existe la carpeta de logs." -ForegroundColor Red
        Pause-Menu
        return
    }

    $logs = Get-ChildItem $LogRoot -Recurse -Filter "*.log" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 20

    $patterns = @(
        "http status: 410",
        "Connection to all gateways failed",
        "Could not resolve host",
        "Certificate check failed",
        "Heartbeat failed",
        "Connected successfully",
        "Registration successful",
        "cluster time is not yet available"
    )

    foreach ($log in $logs) {
        $content = Get-Content $log.FullName -Tail 150 -ErrorAction SilentlyContinue
        $matches = $content | Select-String -Pattern $patterns -SimpleMatch

        if ($matches) {
            Write-Host "`nArchivo:" -ForegroundColor Cyan
            Write-Host $log.FullName
            Write-Host "Coincidencias:" -ForegroundColor Yellow
            $matches | Select-Object -First 20 | ForEach-Object {
                Write-Host $_.Line
            }
        }
    }

    Pause-Menu
}

function Invoke-OneAgentDiagnosis {
    Write-Header "Diagnostico completo"

    $issues = @()

    $service = Get-Service "Dynatrace OneAgent" -ErrorAction SilentlyContinue

    if (-not $service) {
        $issues += "OneAgent no esta instalado o el servicio no existe."
    } elseif ($service.Status -ne "Running") {
        $issues += "El servicio existe pero no esta Running. Estado actual: $($service.Status)"
    }

    if (-not (Test-OneAgentCtl)) {
        $issues += "No se encontro oneagentctl.exe."
    } else {
        $tenantRaw = & $OneAgentCtl --get-tenant 2>$null
        $serverRaw = & $OneAgentCtl --get-server 2>$null

        $tenant = if ($null -ne $tenantRaw) { ($tenantRaw | Out-String).Trim() } else { "" }
        $server = if ($null -ne $serverRaw) { ($serverRaw | Out-String).Trim() } else { "" }

        if ([string]::IsNullOrWhiteSpace($tenant)) {
            $issues += "No hay tenant configurado."
        } else {
            $hostName = "$tenant.live.dynatrace.com"

            try {
                Resolve-DnsName $hostName -ErrorAction Stop | Out-Null
            } catch {
                $issues += "DNS falla para $hostName."
            }

            $tcp = Test-NetConnection $hostName -Port 443 -WarningAction SilentlyContinue
            if (-not $tcp.TcpTestSucceeded) {
                $issues += "No hay conexion TCP 443 contra $hostName."
            }
        }
    }

    $logProblem410 = $false
    $logProblemDns = $false
    $logProblemGateway = $false

    if (Test-Path $LogRoot) {
        $recentLogs = Get-ChildItem $LogRoot -Recurse -Filter "*.log" |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 20

        foreach ($log in $recentLogs) {
            $tail = Get-Content $log.FullName -Tail 200 -ErrorAction SilentlyContinue

            if ($tail -match "http status: 410") { $logProblem410 = $true }
            if ($tail -match "Could not resolve host") { $logProblemDns = $true }
            if ($tail -match "Connection to all gateways failed") { $logProblemGateway = $true }
        }
    }

    if ($logProblem410) {
        $issues += "Se detecto HTTP 410. Posible tenant expirado, eliminado o endpoint obsoleto."
    }

    if ($logProblemDns) {
        $issues += "Se detecto 'Could not resolve host' en logs."
    }

    if ($logProblemGateway) {
        $issues += "Se detecto 'Connection to all gateways failed'."
    }

    Write-Host "Resultado:" -ForegroundColor Yellow

    if ($issues.Count -eq 0) {
        Write-Host "No se detectaron problemas evidentes." -ForegroundColor Green
    } else {
        foreach ($issue in $issues) {
            Write-Host "- $issue" -ForegroundColor Red
        }
    }

    if ($logProblem410) {
        Write-Host ""
        Write-Host "El error 410 suele ocurrir cuando el tenant ya no esta disponible." -ForegroundColor Yellow
        $answer = Read-Host "Quieres cambiar el OneAgent a un nuevo tenant? (S/N)"

        if ($answer -match "^[sS]$") {
            Set-NewTenant
        }
    }

    Pause-Menu
}

function Set-NewTenant {
    Write-Header "Cambiar tenant"

    if (-not (Test-OneAgentCtl)) {
        Pause-Menu
        return
    }

    $newTenant = Read-Host "Ingresa el nuevo Environment ID"
    $newToken = Read-Host "Ingresa el nuevo Tenant Token"
    $newServer = Read-Host "Ingresa Communication Endpoint o presiona ENTER para usar https://$newTenant.live.dynatrace.com/communication"

    if ([string]::IsNullOrWhiteSpace($newServer)) {
        $newServer = "https://$newTenant.live.dynatrace.com/communication"
    }

    Write-Host ""
    Write-Host "Nueva configuracion:" -ForegroundColor Yellow
    Write-Host "Tenant: $newTenant"
    Write-Host "Server: $newServer"
    Write-Host ""

    $confirm = Read-Host "Confirmas aplicar cambios? (S/N)"

    if ($confirm -notmatch "^[sS]$") {
        Write-Host "Operacion cancelada." -ForegroundColor Yellow
        Pause-Menu
        return
    }

    try {
        & $OneAgentCtl --set-tenant=$newTenant
        & $OneAgentCtl --set-tenant-token=$newToken
        & $OneAgentCtl --set-server=$newServer

        Write-Host "`nReiniciando servicio..." -ForegroundColor Yellow
        Restart-Service "Dynatrace OneAgent" -Force

        Start-Sleep -Seconds 10

        Write-Host "`nConfiguracion actual:" -ForegroundColor Green
        & $OneAgentCtl --get-tenant
        & $OneAgentCtl --get-server

        Write-Host "`nCambio aplicado correctamente." -ForegroundColor Green
    } catch {
        Write-Host "Error aplicando cambios:" -ForegroundColor Red
        Write-Host $_.Exception.Message
    }

    Pause-Menu
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-OneAgent {
    Write-Header "Reiniciar OneAgent"

    if (-not (Test-IsAdmin)) {
        Write-Host "Este script no esta ejecutandose como Administrador." -ForegroundColor Red
        Write-Host "Abre PowerShell como Administrador y vuelve a intentar." -ForegroundColor Yellow
        Pause-Menu
        return
    }

    try {
        Restart-Service -Name "Dynatrace OneAgent" -Force -ErrorAction Stop
        Start-Sleep -Seconds 10
        Get-Service "Dynatrace OneAgent" | Format-Table -AutoSize
        Write-Host "OneAgent reiniciado correctamente." -ForegroundColor Green
    } catch {
        Write-Host "Error reiniciando OneAgent:" -ForegroundColor Red
        Write-Host $_.Exception.Message
    }

    Pause-Menu
}

function Show-Menu {
    do {
        Write-Header "Menu principal"

        Write-Host "1. Ver informacion basica del OneAgent"
        Write-Host "2. Ver procesos Dynatrace/ruxit"
        Write-Host "3. Probar DNS y puerto 443"
        Write-Host "4. Listar logs recientes"
        Write-Host "5. Analizar logs importantes"
        Write-Host "6. Ejecutar diagnostico completo"
        Write-Host "7. Cambiar tenant manualmente"
        Write-Host "8. Reiniciar OneAgent"
        Write-Host "0. Salir"
        Write-Host ""

        $option = Read-Host "Selecciona una opcion"

        switch ($option) {
            "1" { Get-OneAgentBasicInfo }
            "2" { Test-OneAgentProcesses }
            "3" { Test-OneAgentConnectivity }
            "4" { Get-LatestLogs }
            "5" { Read-ImportantLogs }
            "6" { Invoke-OneAgentDiagnosis }
            "7" { Set-NewTenant }
            "8" { Restart-OneAgent }
            "0" { Write-Host "Saliendo..." }
            default {
                Write-Host "Opcion invalida." -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }

    } while ($option -ne "0")
}

Show-Menu