# OneAgent-Diagnostics-Menu.ps1
# Ejecutar como Administrador
# Version v5: ingreso compatible del Tenant Token y timeout controlado para prueba TCP 443

$OneAgentCtl = "C:\Program Files\Dynatrace\OneAgent\agent\tools\oneagentctl.exe"
$LogRoot = "C:\ProgramData\dynatrace\oneagent\log"

function Write-Host {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [object[]]$Object,

        [ConsoleColor]$ForegroundColor,

        [ConsoleColor]$BackgroundColor,

        [switch]$NoNewline,

        [object]$Separator
    )

    if ($null -eq $Object -or $Object.Count -eq 0) {
        Microsoft.PowerShell.Utility\Write-Host ""
        return
    }

    $text = if ($PSBoundParameters.ContainsKey('Separator')) {
        ($Object -join $Separator)
    } else {
        ($Object -join ' ')
    }

    $indentedText = (($text -split "`r?`n", -1) | ForEach-Object { " $_" }) -join [Environment]::NewLine

    $params = @{
        Object = $indentedText
    }

    if ($PSBoundParameters.ContainsKey('ForegroundColor')) {
        $params.ForegroundColor = $ForegroundColor
    }

    if ($PSBoundParameters.ContainsKey('BackgroundColor')) {
        $params.BackgroundColor = $BackgroundColor
    }

    if ($NoNewline) {
        $params.NoNewline = $true
    }

    Microsoft.PowerShell.Utility\Write-Host @params
}

function Read-Host {
    [CmdletBinding(DefaultParameterSetName = 'Prompt')]
    param(
        [Parameter(ParameterSetName = 'Prompt', Position = 0)]
        [object]$Prompt,

        [Parameter(ParameterSetName = 'Secure')]
        [switch]$AsSecureString
    )

    if ($PSCmdlet.ParameterSetName -eq 'Secure') {
        if ($PSBoundParameters.ContainsKey('Prompt')) {
            return Microsoft.PowerShell.Utility\Read-Host -Prompt (" " + [string]$Prompt) -AsSecureString
        }

        return Microsoft.PowerShell.Utility\Read-Host -AsSecureString
    }

    if ($PSBoundParameters.ContainsKey('Prompt')) {
        return Microsoft.PowerShell.Utility\Read-Host -Prompt (" " + [string]$Prompt)
    }

    return Microsoft.PowerShell.Utility\Read-Host
}

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

function Write-IndentedBlock {
    param(
        [Parameter(ValueFromPipeline = $true)]
        $InputObject
    )

    begin {
        $buffer = @()
    }

    process {
        if ($null -ne $InputObject) {
            $buffer += $InputObject
        }
    }

    end {
        if ($buffer.Count -eq 0) {
            return
        }

        $text = ($buffer | Out-String).TrimEnd("`r", "`n")
        foreach ($line in ($text -split "`r?`n")) {
            Write-Host $line
        }
    }
}

function Write-IndentedCommandOutput {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    $output = & $ScriptBlock 2>&1
    if ($null -eq $output) {
        return
    }

    $text = ($output | Out-String).TrimEnd("`r", "`n")
    foreach ($line in ($text -split "`r?`n")) {
        Write-Host $line
    }
}

function Test-OneAgentCtl {
    if (-not (Test-Path $OneAgentCtl)) {
        Write-Host "No se encontro oneagentctl.exe en:" -ForegroundColor Red
        Write-Host $OneAgentCtl
        return $false
    }
    return $true
}

function Get-OneAgentServiceState {
    return Get-Service "Dynatrace OneAgent" -ErrorAction SilentlyContinue
}

function Get-OneAgentRuntimeInfo {
    $info = [ordered]@{
        Tenant = ""
        Server = ""
        NetworkZone = ""
        Proxy = ""
    }

    if (-not (Test-OneAgentCtl)) {
        return [pscustomobject]$info
    }

    $info.Tenant = ((& $OneAgentCtl --get-tenant 2>$null) | Out-String).Trim()
    $info.Server = ((& $OneAgentCtl --get-server 2>$null) | Out-String).Trim()
    $info.NetworkZone = ((& $OneAgentCtl --get-network-zone 2>$null) | Out-String).Trim()
    $info.Proxy = ((& $OneAgentCtl --get-proxy 2>$null) | Out-String).Trim()

    return [pscustomobject]$info
}

function Test-TcpPortWithTimeout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [Parameter(Mandatory = $true)]
        [int]$Port,

        [int]$TimeoutMilliseconds = 8000
    )

    $tcpClient = New-Object System.Net.Sockets.TcpClient
    $asyncResult = $null

    try {
        $asyncResult = $tcpClient.BeginConnect($ComputerName, $Port, $null, $null)

        if (-not $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            return [pscustomobject]@{
                ComputerName     = $ComputerName
                RemotePort       = $Port
                TcpTestSucceeded = $false
                TimedOut         = $true
                TimeoutMs        = $TimeoutMilliseconds
                Error            = "Tiempo de espera agotado al intentar conexion TCP."
            }
        }

        $tcpClient.EndConnect($asyncResult)

        return [pscustomobject]@{
            ComputerName     = $ComputerName
            RemotePort       = $Port
            TcpTestSucceeded = $true
            TimedOut         = $false
            TimeoutMs        = $TimeoutMilliseconds
            Error            = ""
        }
    } catch {
        return [pscustomobject]@{
            ComputerName     = $ComputerName
            RemotePort       = $Port
            TcpTestSucceeded = $false
            TimedOut         = $false
            TimeoutMs        = $TimeoutMilliseconds
            Error            = $_.Exception.Message
        }
    } finally {
        if ($null -ne $asyncResult -and $null -ne $asyncResult.AsyncWaitHandle) {
            $asyncResult.AsyncWaitHandle.Close()
        }

        $tcpClient.Close()
    }
}

function Test-OneAgentEndpointConnectivity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Tenant
    )

    $result = [ordered]@{
        HostName = ""
        DnsOk = $false
        DnsError = ""
        TcpOk = $false
        TcpDetails = $null
    }

    if ([string]::IsNullOrWhiteSpace($Tenant)) {
        return [pscustomobject]$result
    }

    $result.HostName = "$Tenant.live.dynatrace.com"

    try {
        Resolve-DnsName $result.HostName -ErrorAction Stop | Out-Null
        $result.DnsOk = $true
    } catch {
        $result.DnsError = $_.Exception.Message
    }

    # Evita que Test-NetConnection quede demasiado tiempo en "Waiting for response".
    # La prueba TCP se cancela logicamente despues de 8 segundos.
    $tcp = Test-TcpPortWithTimeout -ComputerName $result.HostName -Port 443 -TimeoutMilliseconds 8000
    $result.TcpDetails = $tcp
    $result.TcpOk = ($null -ne $tcp -and $tcp.TcpTestSucceeded)

    return [pscustomobject]$result
}

function Convert-SecureStringToPlainText {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.SecureString]$SecureString
    )

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)

    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Read-SecretPlainText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt
    )

    $secureValue = Microsoft.PowerShell.Utility\Read-Host -Prompt (" " + $Prompt) -AsSecureString

    if ($null -eq $secureValue -or $secureValue.Length -eq 0) {
        return ""
    }

    return Convert-SecureStringToPlainText -SecureString $secureValue
}


function Read-ApiTokenPlainText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt
    )

    Write-Host "" 
    Write-Host "Modo de ingreso del API token InstallerDownload:" -ForegroundColor Yellow
    Write-Host "1. Visible compatible recomendado si el modo oculto te devuelve vacio"
    Write-Host "2. Oculto / SecureString"
    Write-Host "" 

    $mode = Read-Host "Selecciona modo o ENTER para usar 1"
    $mode = Normalize-PlainInput -Value $mode

    if ($mode -eq "2") {
        $value = Read-SecretPlainText $Prompt
        $value = Normalize-SecretText -Value $value

        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }

        Write-Host "El modo oculto devolvio un valor vacio en esta consola." -ForegroundColor Yellow
        Write-Host "Se usara ingreso visible para mantener compatibilidad con PowerShell/Windows Terminal." -ForegroundColor Yellow
    }

    Write-Host "" 
    Write-Host "Pega el API token. Se vera en pantalla mientras lo escribes/pegas." -ForegroundColor Yellow
    Write-Host "No se guardara en el script ni se imprimira completo despues." -ForegroundColor Yellow
    $plainValue = Microsoft.PowerShell.Utility\Read-Host -Prompt (" " + $Prompt)

    return (Normalize-SecretText -Value $plainValue)
}


function Read-TenantTokenPlainText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt
    )

    Write-Host ""
    Write-Host "Modo de ingreso del Tenant Token:" -ForegroundColor Yellow
    Write-Host "1. Visible / compatible (recomendado en esta consola)"
    Write-Host "2. Oculto / SecureString"
    Write-Host ""

    $mode = Read-Host "Selecciona modo o ENTER para usar 1"
    $mode = Normalize-PlainInput -Value $mode

    if ($mode -eq "2") {
        Write-Host "Pega el Tenant Token y presiona ENTER para continuar." -ForegroundColor DarkGray
        $value = Read-SecretPlainText $Prompt
        $value = Normalize-SecretText -Value $value

        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }

        Write-Host "El modo oculto devolvio un valor vacio en esta consola." -ForegroundColor Yellow
        Write-Host "Se cambiara automaticamente al modo visible compatible." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Pega el Tenant Token y presiona ENTER." -ForegroundColor Yellow
    Write-Host "El valor sera visible solo durante el ingreso." -ForegroundColor Yellow
    Write-Host "Despues el script solo mostrara el token enmascarado." -ForegroundColor Yellow

    $plainValue = Microsoft.PowerShell.Utility\Read-Host -Prompt (" " + $Prompt)
    return (Normalize-SecretText -Value $plainValue)
}

function Normalize-SecretText {
    param(
        [string]$Value
    )

    if ($null -eq $Value) {
        return ""
    }

    # Limpieza defensiva para tokens copiados desde navegador, correo o bloc de notas.
    # Evita errores .NET como: "El valor especificado tiene caracteres de control no validos".
    $clean = [string]$Value
    $clean = $clean.Trim()
    $clean = $clean.Trim('"', "'")
    $clean = $clean -replace "`u{FEFF}", ""  # BOM
    $clean = $clean -replace "`u{200B}", ""  # zero-width space
    $clean = $clean -replace "`u{200C}", ""
    $clean = $clean -replace "`u{200D}", ""
    $clean = $clean -replace "`u{00A0}", ""  # NBSP
    $clean = $clean -replace '[\x00-\x1F\x7F-\x9F]', ''
    $clean = $clean.Trim()

    return $clean
}

function Normalize-PlainInput {
    param(
        [string]$Value
    )

    if ($null -eq $Value) {
        return ""
    }

    $clean = [string]$Value
    $clean = $clean.Trim()
    $clean = $clean.Trim('"', "'")
    $clean = $clean -replace "`u{FEFF}", ""
    $clean = $clean -replace '[\x00-\x1F\x7F-\x9F]', ''
    $clean = $clean.Trim()

    return $clean
}

function Test-HeaderValueIsSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return ($Value -notmatch '[\x00-\x1F\x7F-\x9F]')
}

function Mask-Secret {
    param(
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    if ($Value.Length -le 8) {
        return "****"
    }

    return ($Value.Substring(0, 4) + "****" + $Value.Substring($Value.Length - 4))
}

function Get-DynatraceDefaultEnvironmentUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EnvironmentId
    )

    return "https://$EnvironmentId.live.dynatrace.com"
}

function Get-FirstCommunicationEndpoint {
    param(
        [Parameter(Mandatory = $true)]
        $ConnectionInfo,

        [Parameter(Mandatory = $true)]
        [string]$EnvironmentId
    )

    $fallbackEndpoint = "https://$EnvironmentId.live.dynatrace.com/communication"

    if ($null -eq $ConnectionInfo) {
        return $fallbackEndpoint
    }

    $endpoints = @()

    if ($ConnectionInfo.communicationEndpoints) {
        $endpoints = @($ConnectionInfo.communicationEndpoints)
    }

    if ($endpoints.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$endpoints[0])) {
        return [string]$endpoints[0]
    }

    $formattedEndpoints = [string]$ConnectionInfo.formattedCommunicationEndpoints

    if (-not [string]::IsNullOrWhiteSpace($formattedEndpoints)) {
        $parts = ($formattedEndpoints -replace "[{}*]", "") -split ";" |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

        if ($parts.Count -gt 0) {
            return [string]$parts[0]
        }
    }

    return $fallbackEndpoint
}

function Invoke-DynatraceConnectionInfoRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EnvironmentId,

        [Parameter(Mandatory = $true)]
        [string]$InstallerDownloadToken,

        [string]$EnvironmentUrl,

        [ValidateSet("QueryParameter", "AuthorizationHeader", "Auto")]
        [string]$AuthMode = "QueryParameter"
    )

    $EnvironmentId = Normalize-PlainInput -Value $EnvironmentId
    $InstallerDownloadToken = Normalize-SecretText -Value $InstallerDownloadToken
    $EnvironmentUrl = Normalize-PlainInput -Value $EnvironmentUrl

    if ([string]::IsNullOrWhiteSpace($EnvironmentUrl)) {
        $EnvironmentUrl = Get-DynatraceDefaultEnvironmentUrl -EnvironmentId $EnvironmentId
    }

    $EnvironmentUrl = $EnvironmentUrl.TrimEnd("/")
    $baseUri = "$EnvironmentUrl/api/v1/deployment/installer/agent/connectioninfo"

    if ([string]::IsNullOrWhiteSpace($InstallerDownloadToken)) {
        throw "API token vacio despues de limpiar caracteres ocultos. Vuelve a copiarlo desde Dynatrace."
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch {
        # PowerShell Core puede administrar TLS automaticamente.
    }

    # En algunos entornos Windows/PowerShell, el modo Authorization Header puede fallar con:
    # "El valor especificado tiene caracteres de control no validos".
    # Por compatibilidad, el modo por defecto usa Api-Token como query parameter,
    # que es el flujo que ya probaste como funcional.
    # Se usa el mismo formato compatible que probaste en tu script funcional.
    # Los API tokens de Dynatrace usan caracteres seguros para query string.
    $queryUri = "$baseUri`?Api-Token=$InstallerDownloadToken"

    if ($AuthMode -eq "QueryParameter") {
        return Invoke-RestMethod -Method Get -Uri $queryUri -Headers @{ Accept = "application/json" } -ErrorAction Stop
    }

    if ($AuthMode -eq "AuthorizationHeader") {
        if (-not (Test-HeaderValueIsSafe -Value $InstallerDownloadToken)) {
            throw "API token contiene caracteres de control. Usa modo QueryParameter o copia nuevamente el token sin saltos de linea."
        }

        $headers = @{
            Authorization = "Api-Token $InstallerDownloadToken"
            Accept = "application/json"
        }

        return Invoke-RestMethod -Method Get -Uri $baseUri -Headers $headers -ErrorAction Stop
    }

    # Auto: primero intenta header; si falla por problema local de header/PowerShell,
    # reintenta con query parameter. No imprime ni registra el token.
    try {
        if (-not (Test-HeaderValueIsSafe -Value $InstallerDownloadToken)) {
            throw "Header no seguro para este entorno. Se reintentara con QueryParameter."
        }

        $headers = @{
            Authorization = "Api-Token $InstallerDownloadToken"
            Accept = "application/json"
        }

        return Invoke-RestMethod -Method Get -Uri $baseUri -Headers $headers -ErrorAction Stop
    } catch {
        Write-Host "Modo Authorization Header fallo. Reintentando con modo compatible QueryParameter..." -ForegroundColor Yellow
        return Invoke-RestMethod -Method Get -Uri $queryUri -Headers @{ Accept = "application/json" } -ErrorAction Stop
    }
}

function Get-NewTenantConnectionInfo {
    param(
        [string]$EnvironmentId,
        [switch]$ReturnInfo,
        [switch]$PauseAfter
    )

    Write-Header "Obtener Tenant Token desde Deployment API"

    if ([string]::IsNullOrWhiteSpace($EnvironmentId)) {
        $EnvironmentId = Read-Host "Ingresa el nuevo Environment ID"
    }

    $EnvironmentId = Normalize-PlainInput -Value $EnvironmentId

    if ([string]::IsNullOrWhiteSpace($EnvironmentId)) {
        Write-Host "Environment ID vacio. Operacion cancelada." -ForegroundColor Red
        if ($PauseAfter) { Pause-Menu }
        return $null
    }

    if ($EnvironmentId -notmatch "^[a-zA-Z0-9]{8,}$") {
        Write-Host "Advertencia: el Environment ID no tiene el formato comun de Dynatrace SaaS. Se continuara de todos modos." -ForegroundColor Yellow
    }

    $defaultEnvironmentUrl = Get-DynatraceDefaultEnvironmentUrl -EnvironmentId $EnvironmentId
    $environmentUrl = Read-Host "Ingresa Environment URL base o ENTER para usar $defaultEnvironmentUrl"
    $environmentUrl = Normalize-PlainInput -Value $environmentUrl

    if ([string]::IsNullOrWhiteSpace($environmentUrl)) {
        $environmentUrl = $defaultEnvironmentUrl
    }

    Write-Host ""
    Write-Host "Necesitas un API token de Dynatrace con scope InstallerDownload." -ForegroundColor Yellow
    Write-Host "Este NO es el tenant token. Solo se usa para consultar connectioninfo." -ForegroundColor Yellow
    $installerDownloadToken = Read-ApiTokenPlainText "Ingresa API token con scope InstallerDownload"

    if ([string]::IsNullOrWhiteSpace($installerDownloadToken)) {
        Write-Host "Token InstallerDownload vacio. Operacion cancelada." -ForegroundColor Red
        Write-Host "Sugerencia: usa el modo visible porque en tu consola el modo oculto puede devolver vacio." -ForegroundColor Yellow
        if ($PauseAfter) { Pause-Menu }
        return $null
    }

    Write-Host "Token recibido correctamente. Longitud: $($installerDownloadToken.Length). Mascara: $(Mask-Secret -Value $installerDownloadToken)" -ForegroundColor DarkGray

    try {
        Write-Host ""
        Write-Host "Consultando connectivity information..." -ForegroundColor Cyan
        Write-Host "URL base: $environmentUrl/api/v1/deployment/installer/agent/connectioninfo" -ForegroundColor DarkGray
        Write-Host "Modo auth: QueryParameter compatible, igual al script Get-TenantToken.ps1" -ForegroundColor DarkGray
        Write-Host "API token usado: $(Mask-Secret -Value $installerDownloadToken)" -ForegroundColor DarkGray

        $connectionInfo = Invoke-DynatraceConnectionInfoRequest `
            -EnvironmentId $EnvironmentId `
            -InstallerDownloadToken $installerDownloadToken `
            -EnvironmentUrl $environmentUrl

        $tenantUuid = [string]$connectionInfo.tenantUUID
        $tenantToken = [string]$connectionInfo.tenantToken
        $server = Get-FirstCommunicationEndpoint -ConnectionInfo $connectionInfo -EnvironmentId $EnvironmentId

        if ([string]::IsNullOrWhiteSpace($tenantToken)) {
            Write-Host "La respuesta no devolvio tenantToken. Revisa permisos del token InstallerDownload." -ForegroundColor Red
            if ($PauseAfter) { Pause-Menu }
            return $null
        }

        Write-Host ""
        Write-Host "Datos obtenidos:" -ForegroundColor Green
        Write-Host "Environment ID ingresado: $EnvironmentId"
        Write-Host "tenantUUID devuelto:      $tenantUuid"
        Write-Host "tenantToken:              $(Mask-Secret -Value $tenantToken)"
        Write-Host "Endpoint sugerido:        $server"

        if ($connectionInfo.communicationEndpoints) {
            Write-Host ""
            Write-Host "Communication endpoints devueltos por Dynatrace:" -ForegroundColor Yellow
            @($connectionInfo.communicationEndpoints) | ForEach-Object { Write-Host "- $_" }
        }

        if (-not [string]::IsNullOrWhiteSpace($tenantUuid) -and $tenantUuid -ne $EnvironmentId) {
            Write-Host ""
            Write-Host "Advertencia: tenantUUID devuelto no coincide exactamente con el Environment ID ingresado." -ForegroundColor Yellow
            Write-Host "Valida que estes apuntando a la cuenta/entorno correcto antes de aplicar cambios." -ForegroundColor Yellow
        }

        $showFullToken = Read-Host "Quieres mostrar el tenantToken completo en pantalla? No recomendado si estas compartiendo pantalla. (S/N)"
        if ($showFullToken -match "^[sS]$") {
            Write-Host ""
            Write-Host "tenantToken completo:" -ForegroundColor Yellow
            Write-Host $tenantToken -ForegroundColor Yellow
        } else {
            Write-Host "tenantToken completo no mostrado. Se mantiene en memoria solo para esta ejecucion." -ForegroundColor Cyan
        }

        $result = [pscustomobject]@{
            EnvironmentId = $EnvironmentId
            EnvironmentUrl = $environmentUrl.TrimEnd("/")
            TenantUUID = $tenantUuid
            TenantToken = $tenantToken
            Server = $server
            ConnectionInfo = $connectionInfo
        }

        if ($PauseAfter) { Pause-Menu }
        return $result
    } catch {
        Write-Host "Error consultando Deployment API:" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red

        if ($_.Exception.InnerException) {
            Write-Host "Detalle interno:" -ForegroundColor Red
            Write-Host $_.Exception.InnerException.Message -ForegroundColor Red
        }

        if ($_.Exception.Response) {
            try {
                $statusCode = [int]$_.Exception.Response.StatusCode
                Write-Host "HTTP Status: $statusCode" -ForegroundColor Red
            } catch { }
        }

        Write-Host ""
        Write-Host "Causas frecuentes:" -ForegroundColor Yellow
        Write-Host "- El API token fue copiado con saltos de linea, espacios invisibles o comillas."
        Write-Host "- El API token no tiene scope InstallerDownload."
        Write-Host "- El Environment ID o Environment URL no corresponde a tu nueva cuenta."
        Write-Host "- Hay proxy/SSL inspection bloqueando la llamada HTTPS."
        Write-Host "- El tenant nuevo aun no esta disponible o fue escrito incorrectamente."
        Write-Host "- Si el modo Authorization Header falla, usa el modo QueryParameter compatible incluido en esta version."

        if ($PauseAfter) { Pause-Menu }
        return $null
    }
}


function Get-OneAgentBasicInfo {
    Write-Header "Informacion basica"

    Write-Host "Servicio Dynatrace:" -ForegroundColor Yellow
    Get-Service *dynatrace* -ErrorAction SilentlyContinue | Format-Table -AutoSize | Write-IndentedBlock

    if (Test-OneAgentCtl) {
        $runtimeInfo = Get-OneAgentRuntimeInfo

        Write-Host "`nVersion:" -ForegroundColor Yellow
        Write-IndentedCommandOutput { & $OneAgentCtl --version }

        Write-Host "`nTenant actual:" -ForegroundColor Yellow
        Write-Host $runtimeInfo.Tenant

        Write-Host "`nServidor / endpoints:" -ForegroundColor Yellow
        Write-Host $runtimeInfo.Server

        Write-Host "`nNetwork Zone:" -ForegroundColor Yellow
        $nz = $runtimeInfo.NetworkZone
        if ([string]::IsNullOrWhiteSpace($nz)) {
            Write-Host "default / sin zona configurada"
        } else {
            Write-Host $nz
        }

        Write-Host "`nProxy:" -ForegroundColor Yellow
        $proxy = $runtimeInfo.Proxy
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
        $processes | Select-Object Id, ProcessName, CPU, StartTime -ErrorAction SilentlyContinue | Format-Table -AutoSize | Write-IndentedBlock
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

    $runtimeInfo = Get-OneAgentRuntimeInfo
    $tenant = $runtimeInfo.Tenant

    if ([string]::IsNullOrWhiteSpace($tenant)) {
        Write-Host "No se pudo obtener el tenant actual." -ForegroundColor Red
        Pause-Menu
        return
    }

    $connectivity = Test-OneAgentEndpointConnectivity -Tenant $tenant
    $hostName = $connectivity.HostName

    Write-Host "Tenant: $tenant"
    Write-Host "Host:   $hostName"
    Write-Host ""

    Write-Host "Resolviendo DNS..." -ForegroundColor Yellow
    if ($connectivity.DnsOk) {
        Resolve-DnsName $hostName -ErrorAction SilentlyContinue | Format-Table -AutoSize | Write-IndentedBlock
    } else {
        Write-Host "Error DNS: $($connectivity.DnsError)" -ForegroundColor Red
    }

    Write-Host "`nProbando puerto 443..." -ForegroundColor Yellow
    $connectivity.TcpDetails | Format-List | Write-IndentedBlock

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

function Get-LogSeverityColor {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    if ($Line -match "Connected successfully|Registration successful|acked|Communication upload statistics|Configuration received|AgentId") {
        return "Green"
    }

    if ($Line -match "http status: 410|Connection to all gateways failed|Could not resolve host|Certificate check failed|Heartbeat failed|not working|unauthorized|forbidden|authentication|SSL|TLS") {
        return "Red"
    }

    if ($Line -match "cluster time is not yet available|Dropping package list report|proxy|tenant|token") {
        return "Yellow"
    }

    return "White"
}

function Get-OneAgentLogFindings {
    param(
        [int]$LogCount = 20,
        [int]$TailLines = 200
    )

    $findings = @()

    if (-not (Test-Path $LogRoot)) {
        return $findings
    }

    $patterns = Get-RecommendedConnectionPatterns
    $recentLogs = Get-ChildItem $LogRoot -Recurse -Filter "*.log" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First $LogCount

    foreach ($log in $recentLogs) {
        $content = Get-Content $log.FullName -Tail $TailLines -ErrorAction SilentlyContinue
        if (-not $content) {
            continue
        }

        $matches = $content | Select-String -Pattern $patterns -SimpleMatch
        foreach ($match in $matches) {
            $findings += [pscustomobject]@{
                LogPath = $log.FullName
                LastWriteTime = $log.LastWriteTime
                Line = $match.Line
                Severity = Get-LogSeverityColor -Line $match.Line
            }
        }
    }

    return $findings
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

                Write-Host $line -ForegroundColor (Get-LogSeverityColor -Line $line)
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
        Format-Table -AutoSize |
        Write-IndentedBlock

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

function Invoke-OneAgentDiagnosis {
    Write-Header "Diagnostico completo"

    $issues = @()
    $warnings = @()

    $service = Get-OneAgentServiceState

    if (-not $service) {
        $issues += "OneAgent no esta instalado o el servicio no existe."
    } elseif ($service.Status -ne "Running") {
        $issues += "El servicio existe pero no esta Running. Estado actual: $($service.Status)"
    }

    if (-not (Test-OneAgentCtl)) {
        $issues += "No se encontro oneagentctl.exe."
    } else {
        $runtimeInfo = Get-OneAgentRuntimeInfo
        $tenant = $runtimeInfo.Tenant
        $server = $runtimeInfo.Server

        if ([string]::IsNullOrWhiteSpace($tenant)) {
            $issues += "No hay tenant configurado."
        } else {
            $connectivity = Test-OneAgentEndpointConnectivity -Tenant $tenant

            if (-not $connectivity.DnsOk) {
                $issues += "DNS falla para $($connectivity.HostName)."
            }

            if (-not $connectivity.TcpOk) {
                $issues += "No hay conexion TCP 443 contra $($connectivity.HostName)."
            }
        }

        if ([string]::IsNullOrWhiteSpace($server)) {
            $warnings += "No se obtuvo el communication endpoint desde oneagentctl."
        }

        if (-not [string]::IsNullOrWhiteSpace($runtimeInfo.Proxy)) {
            $warnings += "Hay proxy configurado. Validar que siga vigente: $($runtimeInfo.Proxy)"
        }
    }

    $findings = Get-OneAgentLogFindings -LogCount 20 -TailLines 200

    $logProblem410 = @($findings | Where-Object { $_.Line -match "http status: 410" }).Count -gt 0
    $logProblemDns = @($findings | Where-Object { $_.Line -match "Could not resolve host" }).Count -gt 0
    $logProblemGateway = @($findings | Where-Object { $_.Line -match "Connection to all gateways failed" }).Count -gt 0
    $logProblemTls = @($findings | Where-Object { $_.Line -match "Certificate check failed|SSL|TLS" }).Count -gt 0
    $logSuccess = @($findings | Where-Object { $_.Line -match "Connected successfully|Registration successful|Communication upload statistics" }).Count -gt 0

    if ($logProblem410) {
        $issues += "Se detecto HTTP 410. Posible tenant expirado, eliminado o endpoint obsoleto."
    }

    if ($logProblemDns) {
        $issues += "Se detecto 'Could not resolve host' en logs."
    }

    if ($logProblemGateway) {
        $issues += "Se detecto 'Connection to all gateways failed'."
    }

    if ($logProblemTls) {
        $issues += "Se detectaron errores SSL/TLS o validacion de certificado en logs."
    }

    if ((-not $logProblem410) -and (-not $logProblemDns) -and (-not $logProblemGateway) -and (-not $logProblemTls) -and (-not $logSuccess)) {
        $warnings += "No hubo patrones concluyentes en los ultimos logs revisados."
    }

    Write-Host "Resultado:" -ForegroundColor Yellow

    if ($issues.Count -eq 0) {
        Write-Host "No se detectaron problemas evidentes." -ForegroundColor Green
    } else {
        foreach ($issue in $issues) {
            Write-Host "- $issue" -ForegroundColor Red
        }
    }

    if ($warnings.Count -gt 0) {
        Write-Host ""
        Write-Host "Observaciones:" -ForegroundColor Yellow
        foreach ($warning in $warnings) {
            Write-Host "- $warning" -ForegroundColor Yellow
        }
    }

    if ($findings.Count -gt 0) {
        Write-Host ""
        Write-Host "Eventos relevantes encontrados en logs recientes:" -ForegroundColor Cyan
        $findings |
            Sort-Object LastWriteTime |
            Select-Object -Last 10 |
            ForEach-Object {
                Write-Host "[$($_.LastWriteTime)] $($_.Line)" -ForegroundColor $_.Severity
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

    if (-not (Test-IsAdmin)) {
        Write-Host "Este script no esta ejecutandose como Administrador." -ForegroundColor Red
        Write-Host "Abre PowerShell como Administrador para cambiar configuracion del OneAgent." -ForegroundColor Yellow
        Pause-Menu
        return
    }

    $newTenant = Read-Host "Ingresa el nuevo Environment ID"
    $newTenant = Normalize-PlainInput -Value $newTenant

    if ([string]::IsNullOrWhiteSpace($newTenant)) {
        Write-Host "Environment ID vacio. Operacion cancelada." -ForegroundColor Red
        Pause-Menu
        return
    }

    $tenantToken = ""
    $suggestedServer = "https://$newTenant.live.dynatrace.com/communication"

    Write-Host ""
    $hasTenantToken = Read-Host "Ya tienes el nuevo Tenant Token? (S/N). Si respondes N, se consultara con Deployment API"

    if ($hasTenantToken -match "^[sS]$") {
        $tenantToken = Read-TenantTokenPlainText "Ingresa el nuevo Tenant Token"
        $tenantToken = Normalize-SecretText -Value $tenantToken
    } else {
        $info = Get-NewTenantConnectionInfo -EnvironmentId $newTenant -ReturnInfo

        if ($null -eq $info) {
            Write-Host "No se obtuvo Tenant Token. No se aplicaran cambios." -ForegroundColor Red
            Pause-Menu
            return
        }

        $tenantToken = [string]$info.TenantToken
        if (-not [string]::IsNullOrWhiteSpace([string]$info.Server)) {
            $suggestedServer = [string]$info.Server
        }
    }

    if ([string]::IsNullOrWhiteSpace($tenantToken)) {
        Write-Host "Tenant Token vacio. Operacion cancelada." -ForegroundColor Red
        Pause-Menu
        return
    }

    $newServer = Read-Host "Ingresa Communication Endpoint o presiona ENTER para usar $suggestedServer"
    $newServer = Normalize-PlainInput -Value $newServer

    if ([string]::IsNullOrWhiteSpace($newServer)) {
        $newServer = $suggestedServer
    }

    Write-Host ""
    Write-Host "Nueva configuracion a aplicar:" -ForegroundColor Yellow
    Write-Host "Tenant:      $newTenant"
    Write-Host "TenantToken: $(Mask-Secret -Value $tenantToken)"
    Write-Host "Server:      $newServer"
    Write-Host ""
    Write-Host "Importante: no se imprime el tenant token completo en esta confirmacion." -ForegroundColor Cyan
    Write-Host ""

    $confirm = Read-Host "Confirmas aplicar cambios y reiniciar OneAgent? (S/N)"

    if ($confirm -notmatch "^[sS]$") {
        Write-Host "Operacion cancelada." -ForegroundColor Yellow
        Pause-Menu
        return
    }

    try {
        Write-IndentedCommandOutput { & $OneAgentCtl "--set-tenant=$newTenant" }
        Write-IndentedCommandOutput { & $OneAgentCtl "--set-tenant-token=$tenantToken" }
        Write-IndentedCommandOutput { & $OneAgentCtl "--set-server=$newServer" }

        Write-Host "`nReiniciando servicio..." -ForegroundColor Yellow
        Restart-Service "Dynatrace OneAgent" -Force -ErrorAction Stop

        Start-Sleep -Seconds 10

        Write-Host "`nConfiguracion actual:" -ForegroundColor Green
        Write-Host "Tenant:" -ForegroundColor Yellow
        Write-IndentedCommandOutput { & $OneAgentCtl --get-tenant }
        Write-Host "Server:" -ForegroundColor Yellow
        Write-IndentedCommandOutput { & $OneAgentCtl --get-server }

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
        Get-Service "Dynatrace OneAgent" | Format-Table -AutoSize | Write-IndentedBlock
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
        Write-Host "4. Revisar logs recientes y lineas clave"
        Write-Host "5. Ejecutar diagnostico completo"
        Write-Host "6. Obtener Tenant Token desde nueva cuenta"
        Write-Host "7. Cambiar tenant manualmente o con obtencion automatica"
        Write-Host "8. Reiniciar OneAgent"
        Write-Host "0. Salir"
        Write-Host ""

        $option = Read-Host "Selecciona una opcion"

        switch ($option) {
            "1" { Get-OneAgentBasicInfo }
            "2" { Test-OneAgentProcesses }
            "3" { Test-OneAgentConnectivity }
            "4" { Get-LatestLogs }
            "5" { Invoke-OneAgentDiagnosis }
            "6" { Get-NewTenantConnectionInfo -PauseAfter | Out-Null }
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
