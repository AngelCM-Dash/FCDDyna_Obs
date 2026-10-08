# OneAgent-Diagnostics-Menu.ps1
# Ejecutar como Administrador
# Version v11: estado actual 15 min + historial 60 min, endpoint activo, TLS real Windows/.NET y diagnostico cronologico

$OneAgentCtl = "C:\Program Files\Dynatrace\OneAgent\agent\tools\oneagentctl.exe"
$LogRoot = "C:\ProgramData\dynatrace\oneagent\log"
$CustomKeysDir = "C:\ProgramData\dynatrace\oneagent\agent\customkeys"
$CustomProxyPemPath = Join-Path $CustomKeysDir "custom-proxy.pem"
$CustomPemPath = Join-Path $CustomKeysDir "custom.pem"

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
    Write-Host " Dynatrace OneAgent Diagnostics v11" -ForegroundColor Cyan
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


function Get-OneAgentVersionInfo {
    $result = [ordered]@{
        Available = $false
        Raw = ''
        VersionText = ''
        Major = $null
        Minor = $null
        Patch = $null
        Build = $null
        ActiveMarkerSupported = $false
    }

    if (-not (Test-Path $OneAgentCtl)) {
        return [pscustomobject]$result
    }

    try {
        $raw = ((& $OneAgentCtl --version 2>$null) | Out-String).Trim()
        $result.Raw = $raw

        $match = [regex]::Match($raw, '(?<Version>\d+\.\d+(?:\.\d+){0,2})')
        if (-not $match.Success) {
            return [pscustomobject]$result
        }

        $versionText = $match.Groups['Version'].Value
        $parts = @($versionText -split '\.')

        $result.Available = $true
        $result.VersionText = $versionText
        $result.Major = [int]$parts[0]
        $result.Minor = if ($parts.Count -ge 2) { [int]$parts[1] } else { 0 }
        $result.Patch = if ($parts.Count -ge 3) { [int]$parts[2] } else { 0 }
        $result.Build = if ($parts.Count -ge 4) { [int]$parts[3] } else { 0 }

        # Dynatrace documenta el marcador '*' de --get-server a partir de OneAgent 1.207.
        $result.ActiveMarkerSupported = (
            ($result.Major -gt 1) -or
            ($result.Major -eq 1 -and $result.Minor -ge 207)
        )
    } catch {
        $result.Raw = $_.Exception.Message
    }

    return [pscustomobject]$result
}

function Test-OneAgentProxyConfigured {
    param([string]$ProxyText)

    if ([string]::IsNullOrWhiteSpace($ProxyText)) {
        return $false
    }

    $normalized = $ProxyText.Trim()
    if ($normalized -match '^(?i:none|unset|not\s+set|not\s+configured|disabled|off|-)$') {
        return $false
    }

    return $true
}


function Get-MaskedProxyDisplayText {
    param([string]$ProxyText)

    if ([string]::IsNullOrWhiteSpace($ProxyText)) {
        return ""
    }

    $value = $ProxyText.Trim()

    # Evita exponer credenciales si el proxy fue configurado como usuario:password@host:puerto.
    $value = $value -replace '(?i)(https?://)[^/@\s]+@', '$1****@'
    $value = $value -replace '^(?!https?://)[^/@\s]+@', '****@'

    return $value
}

function Get-OneAgentServerSelection {
    param(
        [string]$InitialServerText,
        [bool]$ActiveMarkerSupported = $true,
        [int]$MaxAttempts = 3,
        [int]$DelaySeconds = 3
    )

    if ($MaxAttempts -lt 1) { $MaxAttempts = 1 }

    $serverText = [string]$InitialServerText
    $attemptLog = @()
    $endpoints = @()
    $activeEndpoint = $null

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if ($attempt -gt 1) {
            Start-Sleep -Seconds $DelaySeconds
            $serverText = ((& $OneAgentCtl --get-server 2>$null) | Out-String).Trim()
        }

        $endpoints = @(Get-OneAgentCommunicationEndpoints -ServerText $serverText)
        $activeCandidates = @($endpoints | Where-Object { $_.IsActive })

        $attemptLog += [pscustomobject]@{
            Attempt = $attempt
            ActiveFound = ($activeCandidates.Count -gt 0)
            EndpointCount = $endpoints.Count
        }

        if ($activeCandidates.Count -gt 0) {
            $activeEndpoint = $activeCandidates[0]
            break
        }

        # En versiones anteriores a 1.207 la ausencia de '*' es normal.
        if (-not $ActiveMarkerSupported) {
            break
        }
    }

    return [pscustomobject]@{
        ServerText = $serverText
        Endpoints = $endpoints
        ActiveEndpoint = $activeEndpoint
        ActiveFound = ($null -ne $activeEndpoint)
        Attempts = $attemptLog
    }
}


function Get-ExceptionMessageChain {
    param(
        [Parameter(Mandatory = $true)]
        [System.Exception]$Exception
    )

    $messages = @()
    $current = $Exception

    while ($null -ne $current) {
        if (-not [string]::IsNullOrWhiteSpace($current.Message)) {
            $messages += $current.Message.Trim()
        }
        $current = $current.InnerException
    }

    return (($messages | Select-Object -Unique) -join ' --> ')
}

function Test-OneAgentTlsHandshake {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HostName,

        [int]$Port = 443,

        [int]$TimeoutMilliseconds = 8000
    )

    # Esta prueba usa el almacén de confianza de Windows/.NET.
    # OneAgent puede usar su propio conjunto de CA (por ejemplo custom.pem/custom-proxy.pem),
    # por lo que el resultado TLS se contrasta siempre con los logs reales de OneAgent.
    $result = [ordered]@{
        HostName             = $HostName
        Port                 = $Port
        Attempted            = $false
        HandshakeOk          = $false
        TimedOut             = $false
        Error                = ''
        Protocol             = ''
        CipherAlgorithm      = ''
        CipherStrength       = $null
        CertificateAvailable = $false
        Subject              = ''
        Issuer               = ''
        NotBefore            = $null
        NotAfter             = $null
        Thumbprint           = ''
        IsSelfSigned         = $false
    }

    if ([string]::IsNullOrWhiteSpace($HostName)) {
        $result.Error = 'Host vacio.'
        return [pscustomobject]$result
    }

    $tcpClient = New-Object System.Net.Sockets.TcpClient
    $connectAsync = $null
    $sslStream = $null
    $authAsync = $null

    try {
        $connectAsync = $tcpClient.BeginConnect($HostName, $Port, $null, $null)
        if (-not $connectAsync.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            $result.TimedOut = $true
            $result.Error = 'Tiempo de espera agotado durante la conexion TCP previa al handshake TLS.'
            return [pscustomobject]$result
        }

        $tcpClient.EndConnect($connectAsync)
        $result.Attempted = $true

        $networkStream = $tcpClient.GetStream()
        $sslStream = New-Object System.Net.Security.SslStream -ArgumentList $networkStream, $false
        $authAsync = $sslStream.BeginAuthenticateAsClient($HostName, $null, $null)

        if (-not $authAsync.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            $result.TimedOut = $true
            $result.Error = 'Tiempo de espera agotado durante el handshake TLS.'
            return [pscustomobject]$result
        }

        $sslStream.EndAuthenticateAsClient($authAsync)
        $result.HandshakeOk = $true

        try { $result.Protocol = $sslStream.SslProtocol.ToString() } catch {}
        try { $result.CipherAlgorithm = $sslStream.CipherAlgorithm.ToString() } catch {}
        try { $result.CipherStrength = $sslStream.CipherStrength } catch {}

        try {
            $remoteCertificate = $sslStream.RemoteCertificate
            if ($null -ne $remoteCertificate) {
                $rawCertificate = $remoteCertificate.GetRawCertData()
                $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (, $rawCertificate)

                $result.CertificateAvailable = $true
                $result.Subject = $cert.Subject
                $result.Issuer = $cert.Issuer
                $result.NotBefore = $cert.NotBefore
                $result.NotAfter = $cert.NotAfter
                $result.Thumbprint = $cert.Thumbprint
                $result.IsSelfSigned = ($cert.Subject -eq $cert.Issuer)
            }
        } catch {
            # El handshake ya fue exitoso; un fallo al leer metadatos no invalida TLS.
        }
    } catch {
        $result.Error = Get-ExceptionMessageChain -Exception $_.Exception
    } finally {
        if ($null -ne $authAsync -and $null -ne $authAsync.AsyncWaitHandle) {
            try { $authAsync.AsyncWaitHandle.Close() } catch {}
        }
        if ($null -ne $connectAsync -and $null -ne $connectAsync.AsyncWaitHandle) {
            try { $connectAsync.AsyncWaitHandle.Close() } catch {}
        }
        if ($null -ne $sslStream) {
            try { $sslStream.Close() } catch {}
        }
        if ($null -ne $tcpClient) {
            try { $tcpClient.Close() } catch {}
        }
    }

    return [pscustomobject]$result
}

function Test-OneAgentEndpointSetConnectivity {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Endpoints,
        [int]$TimeoutMilliseconds = 8000,
        [switch]$IncludeTls
    )

    $results = @()
    $seen = @{}

    foreach ($endpoint in $Endpoints) {
        if ($null -eq $endpoint -or [string]::IsNullOrWhiteSpace([string]$endpoint.HostName)) {
            continue
        }

        $key = ("{0}:{1}" -f $endpoint.HostName.ToLowerInvariant(), $endpoint.Port)
        if ($seen.ContainsKey($key)) {
            continue
        }
        $seen[$key] = $true

        $connectivity = Test-OneAgentHostConnectivity `
            -HostName $endpoint.HostName `
            -Port $endpoint.Port `
            -TimeoutMilliseconds $TimeoutMilliseconds

        $reachable = ($connectivity.DnsOk -and $connectivity.TcpOk)
        $tls = $null
        $tlsRequired = ([string]$endpoint.Url -match '(?i)^https://')

        if ($IncludeTls -and $reachable -and $tlsRequired) {
            $tls = Test-OneAgentTlsHandshake `
                -HostName $endpoint.HostName `
                -Port $endpoint.Port `
                -TimeoutMilliseconds $TimeoutMilliseconds
        }

        $results += [pscustomobject]@{
            Endpoint      = $endpoint
            Connectivity  = $connectivity
            Reachable     = $reachable
            TlsRequired   = $tlsRequired
            Tls           = $tls
            TlsTested     = ($null -ne $tls)
            TlsOk         = ($null -ne $tls -and $tls.HandshakeOk)
        }
    }

    return $results
}

function Get-PemCertificateInventory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $result = [ordered]@{
        Path = $Path
        Exists = $false
        CertificateCount = 0
        ParsedCount = 0
        PrivateKeyDetected = $false
        Certificates = @()
        Errors = @()
    }

    if (-not (Test-Path $Path)) {
        return [pscustomobject]$result
    }

    $result.Exists = $true

    try {
        $text = [System.IO.File]::ReadAllText($Path)
    } catch {
        $result.Errors += "No se pudo leer el archivo: $($_.Exception.Message)"
        return [pscustomobject]$result
    }

    $result.PrivateKeyDetected = ($text -match '-----BEGIN (?:RSA |EC |ENCRYPTED )?PRIVATE KEY-----')

    $matches = [regex]::Matches(
        $text,
        '-----BEGIN CERTIFICATE-----\s*(?<Data>.*?)\s*-----END CERTIFICATE-----',
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )

    $result.CertificateCount = $matches.Count
    $index = 0

    foreach ($match in $matches) {
        $index++
        try {
            $base64 = ($match.Groups['Data'].Value -replace '\s', '')
            $bytes = [Convert]::FromBase64String($base64)
            $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (, $bytes)

            $result.Certificates += [pscustomobject]@{
                Index = $index
                Subject = $cert.Subject
                Issuer = $cert.Issuer
                NotBefore = $cert.NotBefore
                NotAfter = $cert.NotAfter
                Thumbprint = $cert.Thumbprint
                IsSelfSigned = ($cert.Subject -eq $cert.Issuer)
                IsExpired = ($cert.NotAfter -lt (Get-Date))
            }
            $result.ParsedCount++
        } catch {
            $result.Errors += "Certificado #$index no pudo analizarse: $($_.Exception.Message)"
        }
    }

    if ($result.CertificateCount -eq 0) {
        $result.Errors += "No se encontraron bloques BEGIN/END CERTIFICATE."
    }

    return [pscustomobject]$result
}

function Show-PemInventorySummary {
    param(
        [Parameter(Mandatory = $true)]
        $Inventory,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    Write-Host "${Label}:" -ForegroundColor Cyan
    Write-Host "Ruta: $($Inventory.Path)"

    if (-not $Inventory.Exists) {
        Write-Host "[NO EXISTE]" -ForegroundColor Yellow
        return
    }

    Write-Host "Certificados PEM encontrados: $($Inventory.CertificateCount)"
    Write-Host "Certificados interpretados:   $($Inventory.ParsedCount)"

    if ($Inventory.PrivateKeyDetected) {
        Write-Host "[ERROR] Se detecto una PRIVATE KEY. Este archivo debe contener solo certificados publicos." -ForegroundColor Red
    }

    foreach ($cert in $Inventory.Certificates) {
        $role = if ($cert.IsSelfSigned) { 'posible CA raiz/autofirmada' } else { 'certificado intermedio o emitido' }
        $expiryState = if ($cert.IsExpired) { 'EXPIRADO' } else { 'vigente' }
        Write-Host ("  #{0} [{1}; {2}]" -f $cert.Index, $role, $expiryState) -ForegroundColor $(if ($cert.IsExpired) { 'Red' } else { 'Gray' })
        Write-Host "     Subject: $($cert.Subject)"
        Write-Host "     Issuer:  $($cert.Issuer)"
        Write-Host "     Valido hasta: $($cert.NotAfter)"
    }

    foreach ($errorText in $Inventory.Errors) {
        Write-Host "[ADVERTENCIA] $errorText" -ForegroundColor Yellow
    }
}

function Test-OneAgentCertificateFiles {
    $proxyInventory = Get-PemCertificateInventory -Path $CustomProxyPemPath
    $customInventory = Get-PemCertificateInventory -Path $CustomPemPath

    return [pscustomobject]@{
        CustomProxy = $proxyInventory
        Custom = $customInventory
    }
}

function Show-OneAgentCertificateTrustFiles {
    Write-Header "Certificados personalizados de OneAgent"

    $runtime = Get-OneAgentRuntimeInfo
    $proxyConfigured = Test-OneAgentProxyConfigured -ProxyText $runtime.Proxy
    $inventories = Test-OneAgentCertificateFiles

    Write-Host "Proxy configurado en OneAgent:" -ForegroundColor Cyan
    if ($proxyConfigured) {
        Write-Host (Get-MaskedProxyDisplayText -ProxyText $runtime.Proxy) -ForegroundColor Green
    } else {
        Write-Host "[no configurado explicitamente]" -ForegroundColor Yellow
    }

    Write-Host ""
    Show-PemInventorySummary -Inventory $inventories.CustomProxy -Label "custom-proxy.pem"
    Write-Host ""
    Show-PemInventorySummary -Inventory $inventories.Custom -Label "custom.pem"

    Write-Host ""
    Write-Host "Interpretacion:" -ForegroundColor Cyan
    if ($proxyConfigured) {
        if (-not $inventories.CustomProxy.Exists) {
            Write-Host "[ADVERTENCIA] Hay proxy configurado, pero custom-proxy.pem no existe." -ForegroundColor Yellow
            Write-Host "Si ese proxy reemplaza/intercepta el certificado TLS con una CA privada, OneAgent necesitara la CA correspondiente y sus intermedias en custom-proxy.pem." -ForegroundColor Yellow
        } elseif ($inventories.CustomProxy.CertificateCount -eq 0 -or $inventories.CustomProxy.PrivateKeyDetected) {
            Write-Host "[ERROR] custom-proxy.pem existe pero su contenido no tiene un formato seguro/valido para este uso." -ForegroundColor Red
        } else {
            Write-Host "[OK] custom-proxy.pem contiene certificados PEM legibles." -ForegroundColor Green
            Write-Host "Esto no garantiza que sean las CA correctas: deben corresponder a la cadena que presenta el proxy." -ForegroundColor Yellow
        }
    } else {
        if ($inventories.CustomProxy.Exists) {
            Write-Host "[ADVERTENCIA] custom-proxy.pem existe, pero OneAgent no tiene un proxy configurado explicitamente." -ForegroundColor Yellow
            Write-Host "Dynatrace documenta que custom-proxy.pem se ignora cuando no hay proxy configurado en OneAgent." -ForegroundColor Yellow
        }
        Write-Host "Si existe inspeccion TLS transparente, no asumas que custom-proxy.pem sera utilizado." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Nota sobre el orden de certificados:" -ForegroundColor Cyan
    Write-Host "El script muestra los certificados en el mismo orden en que aparecen en el PEM." -ForegroundColor Gray
    Write-Host "No se marca como error un orden raiz/intermedia concreto; lo importante es incluir las CA necesarias sin claves privadas y con certificados vigentes." -ForegroundColor Gray

    Pause-Menu
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


function Get-OneAgentCommunicationEndpoints {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerText
    )

    $endpoints = @()

    if ([string]::IsNullOrWhiteSpace($ServerText)) {
        return $endpoints
    }

    # Ejemplo de --get-server:
    # {https://gw1/communication;*https://gw2/communication}{https://tenant.live.dynatrace.com:443/communication}
    # El asterisco identifica el endpoint que OneAgent esta utilizando actualmente.
    $urlMatches = [regex]::Matches(
        $ServerText,
        '(?<Active>\*)?(?<Url>https?://[^;\}\s]+)',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    foreach ($match in $urlMatches) {
        $url = $match.Groups['Url'].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($url)) {
            continue
        }

        try {
            $uri = [uri]$url
            $port = if ($uri.IsDefaultPort) {
                if ($uri.Scheme -ieq 'https') { 443 } else { 80 }
            } else {
                $uri.Port
            }

            $endpoints += [pscustomobject]@{
                Url      = $url
                HostName = $uri.DnsSafeHost
                Port     = $port
                IsActive = $match.Groups['Active'].Success
            }
        } catch {
            # Si aparece una URL no interpretable, no se usa para diagnostico.
        }
    }

    return $endpoints
}

function Test-OneAgentHostConnectivity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HostName,

        [int]$Port = 443,

        [int]$TimeoutMilliseconds = 8000
    )

    $result = [ordered]@{
        HostName   = $HostName
        Port       = $Port
        DnsOk      = $false
        DnsError   = ''
        TcpOk      = $false
        TcpDetails = $null
    }

    if ([string]::IsNullOrWhiteSpace($HostName)) {
        return [pscustomobject]$result
    }

    try {
        Resolve-DnsName $HostName -ErrorAction Stop | Out-Null
        $result.DnsOk = $true
    } catch {
        $result.DnsError = $_.Exception.Message
    }

    if ($result.DnsOk) {
        $tcp = Test-TcpPortWithTimeout `
            -ComputerName $HostName `
            -Port $Port `
            -TimeoutMilliseconds $TimeoutMilliseconds

        $result.TcpDetails = $tcp
        $result.TcpOk = ($null -ne $tcp -and $tcp.TcpTestSucceeded)
    }

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
    # Vista manual: se evitan palabras demasiado genericas como SSL, TLS, proxy, tenant o token.
    return @(
        "Connected successfully",
        "Registration successful",
        "Configuration received",
        "Communication upload statistics",
        "acked",
        "AgentId",
        "Tenant identifier changed to",
        "http status: 410",
        "Connection to all gateways failed",
        "Could not resolve host",
        "Could not resolve hostname",
        "Certificate check failed",
        "self-signed certificate in certificate chain",
        "SSL peer certificate or SSH remote key was not OK",
        "Heartbeat failed",
        "Not sent because last heartbeat failed",
        "Periodic task has been failing",
        "cluster time is not yet available",
        "Dropping package list report",
        "unauthorized",
        "forbidden"
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

    if ($Line -match "http status: 410|Connection to all gateways failed|Could not resolve host|Could not resolve hostname|Certificate check failed|self-signed certificate in certificate chain|SSL peer certificate or SSH remote key was not OK|Heartbeat failed|Not sent because last heartbeat failed|Periodic task has been failing|unauthorized|forbidden") {
        return "Red"
    }

    if ($Line -match "cluster time is not yet available|Dropping package list report|Tenant identifier changed to") {
        return "Yellow"
    }

    return "White"
}


function Get-OneAgentLogEventTimeUtc {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    # OneAgent puede aparecer con fecha separada por puntos o guiones, por ejemplo:
    # 2026.10.07 18:19:40.587 UTC ...
    # 2026-10-07 18:19:40.587 UTC ...
    if ($Line -notmatch '^\s*(?<Date>\d{4}[\.-]\d{2}[\.-]\d{2})\s+(?<Time>\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?)\s+UTC\b') {
        return $null
    }

    $timestampText = "$($Matches.Date) $($Matches.Time)"
    $formats = @(
        "yyyy.MM.dd HH:mm:ss.fff",
        "yyyy.MM.dd HH:mm:ss.ff",
        "yyyy.MM.dd HH:mm:ss.f",
        "yyyy.MM.dd HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss.fff",
        "yyyy-MM-dd HH:mm:ss.ff",
        "yyyy-MM-dd HH:mm:ss.f",
        "yyyy-MM-dd HH:mm:ss"
    )

    $parsed = [datetime]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal

    if ([datetime]::TryParseExact(
            $timestampText,
            $formats,
            [Globalization.CultureInfo]::InvariantCulture,
            $styles,
            [ref]$parsed
        )) {
        return $parsed.ToUniversalTime()
    }

    return $null
}

function Get-DiagnosticConnectionPatterns {
    # Patrones especificos para estado de comunicacion real.
    # Incluye errores observados en ruxitagent_host cuando falla la validacion TLS.
    return @(
        "http status: 410",
        "Connection to all gateways failed",
        "Could not resolve host",
        "Could not resolve hostname",
        "Certificate check failed",
        "Heartbeat failed",
        "Not sent because last heartbeat failed",
        "Periodic task has been failing",
        "Connected successfully",
        "Registration successful",
        "Communication upload statistics",
        "Configuration received",
        "SSL error",
        "SSL failed",
        "SSL peer certificate or SSH remote key was not OK",
        "TLS error",
        "TLS failed",
        "SSL handshake",
        "TLS handshake",
        "certificate verify failed",
        "certificate validation failed",
        "self-signed certificate in certificate chain"
    )
}

function Get-LatestTenantChangeUtc {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Tenant,

        [int]$LogCount = 30,

        [int]$TailLines = 1200
    )

    if ([string]::IsNullOrWhiteSpace($Tenant) -or -not (Test-Path $LogRoot)) {
        return $null
    }

    $needle = 'Tenant identifier changed to "' + $Tenant.Trim() + '"'
    $latest = $null

    $logs = Get-ChildItem $LogRoot -Recurse -Filter "*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First $LogCount

    foreach ($log in $logs) {
        $content = Get-Content $log.FullName -Tail $TailLines -ErrorAction SilentlyContinue
        if (-not $content) {
            continue
        }

        foreach ($line in $content) {
            if ($line.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                continue
            }

            $eventTimeUtc = Get-OneAgentLogEventTimeUtc -Line $line
            if ($null -ne $eventTimeUtc) {
                if ($null -eq $latest -or $eventTimeUtc -gt $latest) {
                    $latest = $eventTimeUtc
                }
            }
        }
    }

    return $latest
}

function Get-OneAgentLogFindings {
    param(
        [int]$LogCount = 20,
        [int]$TailLines = 200,
        [datetime]$SinceUtc = [datetime]::MinValue,
        [switch]$DiagnosticOnly
    )

    $findings = @()

    if (-not (Test-Path $LogRoot)) {
        return $findings
    }

    $patterns = if ($DiagnosticOnly) {
        Get-DiagnosticConnectionPatterns
    } else {
        Get-RecommendedConnectionPatterns
    }

    $recentLogs = Get-ChildItem $LogRoot -Recurse -Filter "*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First $LogCount

    foreach ($log in $recentLogs) {
        $content = Get-Content $log.FullName -Tail $TailLines -ErrorAction SilentlyContinue
        if (-not $content) {
            continue
        }

        $matches = $content | Select-String -Pattern $patterns -SimpleMatch
        foreach ($match in $matches) {
            $eventTimeUtc = Get-OneAgentLogEventTimeUtc -Line $match.Line

            # Cuando el diagnostico define una ventana temporal, solo se consideran
            # eventos con timestamp real del log dentro de esa ventana.
            # No se usa LastWriteTime del archivo como fecha del evento.
            if ($SinceUtc -ne [datetime]::MinValue) {
                if ($null -eq $eventTimeUtc) {
                    continue
                }

                if ($eventTimeUtc -lt $SinceUtc.ToUniversalTime()) {
                    continue
                }
            }

            $findings += [pscustomobject]@{
                LogPath       = $log.FullName
                LastWriteTime = $log.LastWriteTime
                EventTimeUtc  = $eventTimeUtc
                Line          = $match.Line
                Severity      = Get-LogSeverityColor -Line $match.Line
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


function Get-OneAgentCommunicationFindingSummary {
    param(
        [object[]]$Findings
    )

    $items = @($Findings)

    $http410 = @($items | Where-Object { $_.Line -match '(?i)http status:\s*410' })
    $dns = @($items | Where-Object { $_.Line -match '(?i)Could not resolve host(?:name)?' })
    $gateway = @($items | Where-Object { $_.Line -match '(?i)Connection to all gateways failed' })
    $heartbeat = @($items | Where-Object { $_.Line -match '(?i)Heartbeat failed|Not sent because last heartbeat failed|Periodic task has been failing' })
    $selfSigned = @($items | Where-Object { $_.Line -match '(?i)self-signed certificate in certificate chain' })
    $tls = @($items | Where-Object {
        $_.Line -match '(?i)Certificate check failed|self-signed certificate in certificate chain|SSL peer certificate or SSH remote key was not OK|certificate.*(failed|invalid|expired|untrusted)|SSL.*(error|failed|failure)|TLS.*(error|failed|failure)|handshake.*(error|failed|failure)'
    })
    $proxyCaEmpty = @($items | Where-Object { $_.Line -match '(?i)proxyCAInfo:\s*\[\s*\]' })
    $success = @($items | Where-Object {
        $_.Line -match '(?i)Connected successfully|Registration successful|Communication upload statistics|Configuration received'
    })
    $critical = @($items | Where-Object {
        $_.Line -match '(?i)http status:\s*410|Connection to all gateways failed|Could not resolve host(?:name)?|Certificate check failed|self-signed certificate in certificate chain|SSL peer certificate or SSH remote key was not OK|Heartbeat failed|Not sent because last heartbeat failed|Periodic task has been failing|certificate.*(failed|invalid|expired|untrusted)|SSL.*(error|failed|failure)|TLS.*(error|failed|failure)|handshake.*(error|failed|failure)'
    })

    $latestError = $critical | Where-Object { $null -ne $_.EventTimeUtc } | Sort-Object EventTimeUtc -Descending | Select-Object -First 1
    $latestSuccess = $success | Where-Object { $null -ne $_.EventTimeUtc } | Sort-Object EventTimeUtc -Descending | Select-Object -First 1

    $recoveredAfterError = $false
    if ($null -ne $latestError -and $null -ne $latestSuccess) {
        $recoveredAfterError = ($latestSuccess.EventTimeUtc -gt $latestError.EventTimeUtc)
    }

    return [pscustomobject]@{
        FindingCount          = $items.Count
        Http410Count          = $http410.Count
        DnsCount              = $dns.Count
        GatewayCount          = $gateway.Count
        HeartbeatCount        = $heartbeat.Count
        SelfSignedCount       = $selfSigned.Count
        TlsCount              = $tls.Count
        ProxyCaEmptyCount     = $proxyCaEmpty.Count
        SuccessCount          = $success.Count
        CriticalCount         = $critical.Count
        Problem410            = ($http410.Count -gt 0)
        ProblemDns            = ($dns.Count -gt 0)
        ProblemGateway        = ($gateway.Count -gt 0)
        ProblemHeartbeat      = ($heartbeat.Count -gt 0)
        ProblemSelfSigned     = ($selfSigned.Count -gt 0)
        ProblemTls            = ($tls.Count -gt 0)
        ProxyCaEmpty          = ($proxyCaEmpty.Count -gt 0)
        HasSuccess            = ($success.Count -gt 0)
        CriticalFindings      = $critical
        SuccessFindings       = $success
        LatestErrorEvent      = $latestError
        LatestSuccessEvent    = $latestSuccess
        RecoveredAfterError   = $recoveredAfterError
    }
}

function Invoke-OneAgentDiagnosis {
    Write-Header "Diagnostico completo"

    $issues = @()
    $warnings = @()
    $observations = @()

    $serviceInstalled = $false
    $serviceRunning = $false
    $ctlAvailable = $false
    $tenantConfigured = $false
    $serverConfigured = $false

    $tenantDnsOk = $false
    $tenantTcpOk = $false
    $tenantTls = $null
    $tenantConnectivity = $null

    $activeEndpointDetected = $false
    $activeEndpoint = $null
    $activeDnsOk = $false
    $activeTcpOk = $false
    $activeTls = $null
    $activeConnectivity = $null

    $versionInfo = $null
    $serverSelection = $null
    $endpointConnectivity = @()
    $reachableEndpointCount = 0
    $proxyConfigured = $false
    $certificateFiles = $null

    $service = Get-OneAgentServiceState
    $runtimeInfo = $null
    $tenant = ""
    $server = ""
    $serverEndpoints = @()

    if (-not $service) {
        $issues += "OneAgent no esta instalado o el servicio no existe."
    } else {
        $serviceInstalled = $true
        if ($service.Status -eq "Running") {
            $serviceRunning = $true
        } else {
            $issues += "El servicio existe pero no esta Running. Estado actual: $($service.Status)"
        }
    }

    if (-not (Test-OneAgentCtl)) {
        $issues += "No se encontro oneagentctl.exe."
    } else {
        $ctlAvailable = $true
        $versionInfo = Get-OneAgentVersionInfo
        $runtimeInfo = Get-OneAgentRuntimeInfo
        $tenant = $runtimeInfo.Tenant
        $server = $runtimeInfo.Server
        $proxyConfigured = Test-OneAgentProxyConfigured -ProxyText $runtimeInfo.Proxy

        if ([string]::IsNullOrWhiteSpace($tenant)) {
            $issues += "No hay tenant configurado."
        } else {
            $tenantConfigured = $true
            $tenantConnectivity = Test-OneAgentEndpointConnectivity -Tenant $tenant
            $tenantDnsOk = $tenantConnectivity.DnsOk
            $tenantTcpOk = $tenantConnectivity.TcpOk

            if ($tenantDnsOk -and $tenantTcpOk) {
                $tenantTls = Test-OneAgentTlsHandshake `
                    -HostName $tenantConnectivity.HostName `
                    -Port 443 `
                    -TimeoutMilliseconds 8000
            }
        }

        if ([string]::IsNullOrWhiteSpace($server)) {
            $issues += "No se obtuvo el Communication Endpoint desde oneagentctl."
        } else {
            $serverConfigured = $true

            $markerSupported = $true
            if ($null -ne $versionInfo -and $versionInfo.Available) {
                $markerSupported = $versionInfo.ActiveMarkerSupported
            }

            $serverSelection = Get-OneAgentServerSelection `
                -InitialServerText $server `
                -ActiveMarkerSupported $markerSupported `
                -MaxAttempts 3 `
                -DelaySeconds 3

            $server = $serverSelection.ServerText
            $serverEndpoints = @($serverSelection.Endpoints)
            $activeEndpointDetected = $serverSelection.ActiveFound
            $activeEndpoint = $serverSelection.ActiveEndpoint

            if ($serverEndpoints.Count -eq 0) {
                $issues += "oneagentctl devolvio configuracion de servidor, pero no se pudo interpretar ningun endpoint HTTP/HTTPS."
            } else {
                $endpointConnectivity = @(
                    Test-OneAgentEndpointSetConnectivity `
                        -Endpoints $serverEndpoints `
                        -TimeoutMilliseconds 8000 `
                        -IncludeTls
                )
                $reachableEndpointCount = @($endpointConnectivity | Where-Object { $_.Reachable }).Count
            }

            if ($activeEndpointDetected) {
                $activeConnectivityResult = @($endpointConnectivity | Where-Object {
                    $_.Endpoint.HostName -eq $activeEndpoint.HostName -and $_.Endpoint.Port -eq $activeEndpoint.Port
                } | Select-Object -First 1)

                if ($activeConnectivityResult.Count -gt 0) {
                    $activeConnectivity = $activeConnectivityResult[0].Connectivity
                    $activeTls = $activeConnectivityResult[0].Tls
                } else {
                    $activeConnectivity = Test-OneAgentHostConnectivity `
                        -HostName $activeEndpoint.HostName `
                        -Port $activeEndpoint.Port `
                        -TimeoutMilliseconds 8000

                    if ($activeConnectivity.DnsOk -and $activeConnectivity.TcpOk -and $activeEndpoint.Url -match '(?i)^https://') {
                        $activeTls = Test-OneAgentTlsHandshake `
                            -HostName $activeEndpoint.HostName `
                            -Port $activeEndpoint.Port `
                            -TimeoutMilliseconds 8000
                    }
                }

                $activeDnsOk = $activeConnectivity.DnsOk
                $activeTcpOk = $activeConnectivity.TcpOk

                if (-not $activeDnsOk) {
                    $issues += "DNS falla para el Communication Endpoint activo $($activeEndpoint.HostName)."
                } elseif (-not $activeTcpOk) {
                    $issues += "No hay conexion TCP $($activeEndpoint.Port) contra el Communication Endpoint activo $($activeEndpoint.HostName)."
                }
            } else {
                if ($null -ne $versionInfo -and $versionInfo.Available -and -not $versionInfo.ActiveMarkerSupported) {
                    $observations += "OneAgent $($versionInfo.VersionText) es anterior a 1.207; la ausencia del marcador '*' en --get-server no se considera falla."
                } elseif ($reachableEndpointCount -gt 0) {
                    $warnings += "No se pudo confirmar el Communication Endpoint activo mediante '*', aunque al menos un endpoint configurado responde por DNS/TCP."
                } elseif ($serverEndpoints.Count -gt 0) {
                    $issues += "No se identifico endpoint activo y ninguno de los Communication Endpoints interpretados presenta conectividad DNS/TCP completa."
                }
            }
        }

        # El endpoint base del Tenant es una validacion complementaria. Si el endpoint
        # activo funciona, un problema del endpoint base no invalida por si solo la sesion activa.
        if ($tenantConfigured -and $null -ne $tenantConnectivity) {
            $someConfiguredEndpointReachable = ($reachableEndpointCount -gt 0)

            if (-not $tenantDnsOk) {
                if ($someConfiguredEndpointReachable) {
                    $warnings += "No se pudo resolver DNS del endpoint base del Tenant $($tenantConnectivity.HostName), aunque existe conectividad hacia otro Communication Endpoint configurado."
                } else {
                    $issues += "DNS falla para $($tenantConnectivity.HostName)."
                }
            } elseif (-not $tenantTcpOk) {
                if ($someConfiguredEndpointReachable) {
                    $warnings += "No hay conexion TCP 443 contra el endpoint base del Tenant $($tenantConnectivity.HostName), aunque existe conectividad hacia otro Communication Endpoint configurado."
                } else {
                    $issues += "No hay conexion TCP 443 contra $($tenantConnectivity.HostName)."
                }
            }
        }

        if ($proxyConfigured) {
            $observations += "OneAgent tiene proxy configurado explicitamente: $(Get-MaskedProxyDisplayText -ProxyText $runtimeInfo.Proxy)"
        }
    }

    # Dos horizontes distintos:
    # - 15 minutos: determina el estado ACTUAL.
    # - 60 minutos: solo describe estabilidad/historial y no convierte por si solo un estado sano en ERROR.
    $diagnosticWindowMinutes = 15
    $historyWindowMinutes = 60
    $nowUtc = (Get-Date).ToUniversalTime()
    $diagnosticSinceUtc = $nowUtc.AddMinutes(-$diagnosticWindowMinutes)
    $historySinceUtc = $nowUtc.AddMinutes(-$historyWindowMinutes)
    $tenantChangeUtc = $null
    $diagnosticCriterion = "Ultimos $diagnosticWindowMinutes minutos"
    $historyCriterion = "Ultimos $historyWindowMinutes minutos"

    if (-not [string]::IsNullOrWhiteSpace($tenant)) {
        $tenantChangeUtc = Get-LatestTenantChangeUtc -Tenant $tenant
        if ($null -ne $tenantChangeUtc) {
            if ($tenantChangeUtc -gt $historySinceUtc) {
                $historySinceUtc = $tenantChangeUtc.AddSeconds(-1)
                $historyCriterion = "Desde el ultimo cambio al Tenant actual"
            }
            if ($tenantChangeUtc -gt $diagnosticSinceUtc) {
                $diagnosticSinceUtc = $tenantChangeUtc.AddSeconds(-1)
                $diagnosticCriterion = "Desde el ultimo cambio al Tenant actual"
            }
        }
    }

    # Se lee una sola ventana amplia y luego se deriva la ventana actual.
    $historyFindings = @(Get-OneAgentLogFindings `
        -LogCount 30 `
        -TailLines 4000 `
        -SinceUtc $historySinceUtc `
        -DiagnosticOnly)

    $currentFindings = @($historyFindings | Where-Object {
        $null -ne $_.EventTimeUtc -and $_.EventTimeUtc -ge $diagnosticSinceUtc
    })

    $currentSummary = Get-OneAgentCommunicationFindingSummary -Findings $currentFindings
    $historySummary = Get-OneAgentCommunicationFindingSummary -Findings $historyFindings

    $historicalCriticalOutsideCurrent = [Math]::Max(0, $historySummary.CriticalCount - $currentSummary.CriticalCount)
    $historicalInstability = ($historicalCriticalOutsideCurrent -gt 0)
    $recoveredAfterError = $currentSummary.RecoveredAfterError

    # Contraste entre TLS de Windows/.NET y TLS real observado por OneAgent.
    # Un fallo Windows/.NET NO es concluyente si OneAgent usa custom.pem/custom-proxy.pem.
    # En cambio, un error TLS en los logs de OneAgent si se considera evidencia directa.
    if ($null -ne $activeTls -and -not $activeTls.HandshakeOk -and -not $currentSummary.ProblemTls) {
        $observations += "El handshake TLS con Windows/.NET no pudo validarse contra el endpoint activo, pero OneAgent no reporta un error TLS actual. Los almacenes de confianza pueden ser distintos."
    }
    if ($null -ne $tenantTls -and -not $tenantTls.HandshakeOk -and -not $currentSummary.ProblemTls) {
        $observations += "El handshake TLS con Windows/.NET no pudo validarse contra el endpoint base del Tenant; esta prueba es complementaria y no usa necesariamente el mismo trust store que OneAgent."
    }

    if ($currentSummary.ProblemTls -or $historySummary.ProblemTls) {
        $certificateFiles = Test-OneAgentCertificateFiles

        if ($proxyConfigured) {
            if (-not $certificateFiles.CustomProxy.Exists) {
                $observations += "Hay proxy configurado y no existe custom-proxy.pem en $CustomProxyPemPath."
            } elseif ($certificateFiles.CustomProxy.CertificateCount -eq 0 -or $certificateFiles.CustomProxy.PrivateKeyDetected) {
                $observations += "custom-proxy.pem existe, pero no contiene certificados PEM validos o incluye una clave privada."
            } elseif ($certificateFiles.CustomProxy.Certificates | Where-Object { $_.IsExpired }) {
                $observations += "custom-proxy.pem contiene al menos un certificado expirado."
            } else {
                $observations += "custom-proxy.pem existe y contiene $($certificateFiles.CustomProxy.ParsedCount) certificado(s) legible(s); aun debe verificarse que correspondan a la CA real del proxy."
            }
        } else {
            if ($certificateFiles.CustomProxy.Exists) {
                $observations += "custom-proxy.pem existe, pero OneAgent no tiene un proxy configurado explicitamente. Dynatrace documenta que ese archivo se ignora en ese escenario."
            }
            $observations += "Los errores TLS con OneAgent sin proxy explicito pueden ser compatibles con inspeccion TLS transparente o con un certificado intermedio presentado por la red."
        }

        if ($currentSummary.ProxyCaEmpty -and $proxyConfigured) {
            $observations += "Los logs muestran proxyCAInfo vacio durante el fallo TLS; conviene verificar que OneAgent haya cargado la CA personalizada del proxy."
        }
    }

    # Solo la ventana actual determina ERROR/ADVERTENCIA.
    # El historial de 60 minutos se informa por separado.
    if ($recoveredAfterError) {
        $warnings += "Se detectaron errores de comunicacion en los ultimos 15 minutos, pero existe evidencia positiva posterior de recuperacion. Revisar estabilidad."
    } else {
        if ($currentSummary.Problem410) {
            $issues += "Se detecto HTTP 410 dentro de la ventana actual de diagnostico."
        }
        if ($currentSummary.ProblemDns) {
            $issues += "Se detecto un error de resolucion DNS dentro de la ventana actual de diagnostico."
        }
        if ($currentSummary.ProblemGateway) {
            $issues += "Se detecto 'Connection to all gateways failed' dentro de la ventana actual de diagnostico."
        }
        if ($currentSummary.ProblemTls) {
            if ($currentSummary.ProblemSelfSigned) {
                $issues += "Se detecto falla TLS por una cadena que contiene un certificado autofirmado/no confiable para OneAgent."
            } else {
                $issues += "Se detectaron errores SSL/TLS o de certificado dentro de la ventana actual de diagnostico."
            }
        }
        if ($currentSummary.ProblemHeartbeat) {
            $issues += "El heartbeat de OneAgent esta fallando o hay tareas que no se envian porque el ultimo heartbeat fallo."
        }
    }

    $activePathOk = ($activeEndpointDetected -and $activeDnsOk -and $activeTcpOk)
    $anyEndpointPathOk = ($reachableEndpointCount -gt 0)

    $markerRequired = $true
    if ($null -ne $versionInfo -and $versionInfo.Available -and -not $versionInfo.ActiveMarkerSupported) {
        $markerRequired = $false
    }

    $communicationEndpointCheckOk = if ($markerRequired) { $activePathOk } else { $anyEndpointPathOk }

    # El endpoint base del tenant es complementario. El camino de comunicacion activo es la
    # evidencia primaria, porque --get-server con '*' identifica el endpoint usado actualmente.
    $baseChecksOk = (
        $serviceInstalled -and
        $serviceRunning -and
        $ctlAvailable -and
        $tenantConfigured -and
        $serverConfigured -and
        $communicationEndpointCheckOk
    )

    if ($issues.Count -gt 0) {
        $diagnosticState = "ERROR"
    } elseif ($warnings.Count -gt 0) {
        $diagnosticState = "ADVERTENCIA"
    } elseif ($baseChecksOk) {
        if ($markerRequired -and $activeEndpointDetected) {
            if ($historicalInstability -and $currentSummary.CriticalCount -eq 0) {
                $diagnosticState = "OK_RESTABLECIDA"
            } else {
                $diagnosticState = "OK_ACTIVA"
            }
        } elseif ($currentSummary.HasSuccess) {
            $diagnosticState = "OK"
        } else {
            $diagnosticState = "CONECTIVIDAD_OK_PENDIENTE_CONFIRMACION"
        }
    } else {
        $diagnosticState = "ADVERTENCIA"
    }

    Write-Host "Configuracion actual:" -ForegroundColor Cyan
    if ($null -ne $versionInfo -and $versionInfo.Available) {
        Write-Host "Version OneAgent: $($versionInfo.VersionText)"
    } else {
        Write-Host "Version OneAgent: [no determinada]" -ForegroundColor Yellow
    }

    if (-not [string]::IsNullOrWhiteSpace($tenant)) {
        Write-Host "Tenant: $tenant"
    } else {
        Write-Host "Tenant: [no disponible]" -ForegroundColor Yellow
    }

    if (-not [string]::IsNullOrWhiteSpace($server)) {
        Write-Host "Server: $server"
    } else {
        Write-Host "Server: [no disponible]" -ForegroundColor Yellow
    }

    if ($proxyConfigured) {
        Write-Host "Proxy OneAgent: $(Get-MaskedProxyDisplayText -ProxyText $runtimeInfo.Proxy)"
    } else {
        Write-Host "Proxy OneAgent: [no configurado explicitamente]"
    }

    if ($activeEndpointDetected) {
        Write-Host "Endpoint activo: $($activeEndpoint.Url)" -ForegroundColor Cyan
    } else {
        Write-Host "Endpoint activo: [no identificado]" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Ventana ACTUAL de diagnostico (determina el estado):" -ForegroundColor Cyan
    Write-Host "Desde:    $($diagnosticSinceUtc.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
    Write-Host "Hasta:    $($nowUtc.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
    Write-Host "Criterio: $diagnosticCriterion"

    Write-Host ""
    Write-Host "Historial de estabilidad (informativo):" -ForegroundColor Cyan
    Write-Host "Desde:    $($historySinceUtc.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
    Write-Host "Hasta:    $($nowUtc.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
    Write-Host "Criterio: $historyCriterion"

    if ($null -ne $tenantChangeUtc -and $tenantChangeUtc -gt $nowUtc.AddMinutes(-$historyWindowMinutes)) {
        Write-Host "Se detecto cambio al tenant actual a las $($tenantChangeUtc.ToString('yyyy-MM-dd HH:mm:ss.fff')) UTC." -ForegroundColor Green
        Write-Host "Los errores anteriores a ese cambio no se usan para evaluar el tenant actual." -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "Validaciones actuales:" -ForegroundColor Cyan

    if ($serviceRunning) {
        Write-Host "[OK] Servicio Dynatrace OneAgent: Running" -ForegroundColor Green
    } elseif ($serviceInstalled) {
        Write-Host "[ERROR] Servicio Dynatrace OneAgent: $($service.Status)" -ForegroundColor Red
    } else {
        Write-Host "[ERROR] Servicio Dynatrace OneAgent: no encontrado" -ForegroundColor Red
    }

    if ($tenantConfigured) {
        Write-Host "[OK] Environment ID configurado: $tenant" -ForegroundColor Green
    } else {
        Write-Host "[ERROR] Environment ID no disponible" -ForegroundColor Red
    }

    if ($serverConfigured) {
        Write-Host "[OK] Communication Endpoints configurados" -ForegroundColor Green
    } else {
        Write-Host "[ERROR] Communication Endpoints no disponibles" -ForegroundColor Red
    }

    if ($null -ne $serverSelection -and $serverSelection.Attempts.Count -gt 1) {
        Write-Host "Reintentos para identificar endpoint activo:" -ForegroundColor Cyan
        foreach ($attemptInfo in $serverSelection.Attempts) {
            if ($attemptInfo.ActiveFound) {
                Write-Host "  Intento $($attemptInfo.Attempt)/$($serverSelection.Attempts.Count): identificado" -ForegroundColor Green
            } else {
                Write-Host "  Intento $($attemptInfo.Attempt)/$($serverSelection.Attempts.Count): no identificado" -ForegroundColor Yellow
            }
        }
    }

    if ($activeEndpointDetected) {
        Write-Host "[OK] Endpoint activo identificado: $($activeEndpoint.HostName):$($activeEndpoint.Port)" -ForegroundColor Green
        Write-Host $(if ($activeDnsOk) { "[OK] DNS endpoint activo: $($activeEndpoint.HostName)" } else { "[ERROR] DNS endpoint activo: $($activeEndpoint.HostName)" }) -ForegroundColor $(if ($activeDnsOk) { 'Green' } else { 'Red' })
        Write-Host $(if ($activeTcpOk) { "[OK] TCP $($activeEndpoint.Port) endpoint activo: disponible" } else { "[ERROR] TCP $($activeEndpoint.Port) endpoint activo: no disponible" }) -ForegroundColor $(if ($activeTcpOk) { 'Green' } else { 'Red' })

        if ($null -ne $activeTls) {
            if ($activeTls.HandshakeOk) {
                $tlsExtra = if ([string]::IsNullOrWhiteSpace($activeTls.Protocol)) { '' } else { " ($($activeTls.Protocol))" }
                Write-Host "[OK] TLS Windows/.NET endpoint activo$tlsExtra" -ForegroundColor Green
            } else {
                Write-Host "[INFO] TLS Windows/.NET endpoint activo: no validado" -ForegroundColor Yellow
                if (-not [string]::IsNullOrWhiteSpace($activeTls.Error)) {
                    Write-Host "       $($activeTls.Error)" -ForegroundColor DarkYellow
                }
                Write-Host "       Esta prueba usa el trust store de Windows; la conclusion de OneAgent se toma de sus propios logs." -ForegroundColor DarkGray
            }
        }
    } else {
        if ($null -ne $versionInfo -and $versionInfo.Available -and -not $versionInfo.ActiveMarkerSupported) {
            Write-Host "[INFO] Esta version no requiere el marcador '*' para considerar valido --get-server." -ForegroundColor Cyan
        } else {
            Write-Host "[ADVERTENCIA] Endpoint activo no pudo ser confirmado mediante '*'" -ForegroundColor Yellow
        }
    }

    if ($endpointConnectivity.Count -gt 0) {
        Write-Host "Communication Endpoints interpretados:" -ForegroundColor Cyan
        foreach ($item in $endpointConnectivity) {
            $prefix = if ($item.Endpoint.IsActive) { '*' } else { '-' }
            if (-not $item.Connectivity.DnsOk) {
                Write-Host "  $prefix [ERROR] DNS $($item.Endpoint.HostName)" -ForegroundColor Red
            } elseif (-not $item.Connectivity.TcpOk) {
                Write-Host "  $prefix [ERROR] TCP $($item.Endpoint.HostName):$($item.Endpoint.Port)" -ForegroundColor Red
            } elseif ($item.TlsTested -and $item.TlsOk) {
                $protocolText = if ($null -ne $item.Tls -and -not [string]::IsNullOrWhiteSpace($item.Tls.Protocol)) { "; TLS $($item.Tls.Protocol)" } else { '; TLS OK' }
                Write-Host "  $prefix [OK] $($item.Endpoint.HostName):$($item.Endpoint.Port) - DNS/TCP OK$protocolText" -ForegroundColor Green
            } elseif ($item.TlsTested) {
                Write-Host "  $prefix [INFO] $($item.Endpoint.HostName):$($item.Endpoint.Port) - DNS/TCP OK; TLS Windows/.NET no validado" -ForegroundColor Yellow
            } else {
                Write-Host "  $prefix [OK] $($item.Endpoint.HostName):$($item.Endpoint.Port) - DNS/TCP OK" -ForegroundColor Green
            }
        }
    }

    if ($tenantConfigured -and $null -ne $tenantConnectivity) {
        Write-Host $(if ($tenantDnsOk) { "[OK] DNS endpoint Tenant: $($tenantConnectivity.HostName)" } else { "[ERROR] DNS endpoint Tenant: $($tenantConnectivity.HostName)" }) -ForegroundColor $(if ($tenantDnsOk) { 'Green' } else { 'Red' })
        Write-Host $(if ($tenantTcpOk) { "[OK] TCP 443 endpoint Tenant: disponible" } else { "[ERROR] TCP 443 endpoint Tenant: no disponible" }) -ForegroundColor $(if ($tenantTcpOk) { 'Green' } else { 'Red' })
        if ($null -ne $tenantTls) {
            if ($tenantTls.HandshakeOk) {
                Write-Host "[OK] TLS Windows/.NET endpoint Tenant" -ForegroundColor Green
            } else {
                Write-Host "[INFO] TLS Windows/.NET endpoint Tenant: no validado (prueba complementaria)" -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "[?] DNS/TCP endpoint Tenant: no evaluado" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Logs - estado actual:" -ForegroundColor Cyan

    if ($recoveredAfterError) {
        Write-Host "[ADVERTENCIA] Hubo errores de comunicacion, pero existe evidencia positiva posterior de recuperacion." -ForegroundColor Yellow
        Write-Host "  Ultimo error: $($currentSummary.LatestErrorEvent.EventTimeUtc.ToString('yyyy-MM-dd HH:mm:ss.fff')) UTC" -ForegroundColor Yellow
        Write-Host "  Ultimo exito: $($currentSummary.LatestSuccessEvent.EventTimeUtc.ToString('yyyy-MM-dd HH:mm:ss.fff')) UTC" -ForegroundColor Green
    } else {
        if ($currentSummary.Problem410) { Write-Host "[ERROR] HTTP 410 reciente detectado" -ForegroundColor Red } else { Write-Host "[OK] HTTP 410 reciente: no detectado" -ForegroundColor Green }
        if ($currentSummary.ProblemGateway) { Write-Host "[ERROR] 'Connection to all gateways failed' detectado" -ForegroundColor Red } else { Write-Host "[OK] Fallo total de gateways: no detectado" -ForegroundColor Green }
        if ($currentSummary.ProblemTls) {
            if ($currentSummary.ProblemSelfSigned) {
                Write-Host "[ERROR] TLS OneAgent: cadena con certificado autofirmado/no confiable detectada" -ForegroundColor Red
            } else {
                Write-Host "[ERROR] TLS OneAgent: errores SSL/TLS o de certificado detectados" -ForegroundColor Red
            }
        } else {
            Write-Host "[OK] Errores SSL/TLS o de certificado en OneAgent: no detectados" -ForegroundColor Green
        }
        if ($currentSummary.ProblemDns) { Write-Host "[ERROR] Errores DNS encontrados en logs" -ForegroundColor Red } else { Write-Host "[OK] Errores DNS en logs: no detectados" -ForegroundColor Green }
        if ($currentSummary.ProblemHeartbeat) { Write-Host "[ERROR] Heartbeat/comunicacion periodica fallando" -ForegroundColor Red } else { Write-Host "[OK] Heartbeat fallido reciente: no detectado" -ForegroundColor Green }
    }

    if ($markerRequired -and $activeEndpointDetected -and $activePathOk -and $currentSummary.CriticalCount -eq 0) {
        Write-Host "[OK] OneAgent reporta un Communication Endpoint activo mediante '*'." -ForegroundColor Green
        Write-Host "     Esta es evidencia actual de la ruta de comunicacion seleccionada por OneAgent." -ForegroundColor Green
    } elseif ($currentSummary.HasSuccess) {
        Write-Host "[OK] Evidencia positiva de comunicacion encontrada en logs" -ForegroundColor Green
    } else {
        Write-Host "[?] Envio efectivo de datos no confirmado mediante mensajes positivos recientes" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Historial de estabilidad - ultimos $historyWindowMinutes minutos:" -ForegroundColor Cyan
    if ($historySummary.CriticalCount -eq 0) {
        Write-Host "[OK] No se detectaron eventos criticos de comunicacion en el historial analizado." -ForegroundColor Green
    } else {
        Write-Host "[INFO] Eventos criticos detectados: $($historySummary.CriticalCount)" -ForegroundColor Yellow
        Write-Host "       HTTP 410: $($historySummary.Http410Count) | Gateway: $($historySummary.GatewayCount) | TLS: $($historySummary.TlsCount) | DNS: $($historySummary.DnsCount) | Heartbeat: $($historySummary.HeartbeatCount)" -ForegroundColor Yellow
        if ($null -ne $historySummary.LatestErrorEvent) {
            Write-Host "       Ultimo error del historial: $($historySummary.LatestErrorEvent.EventTimeUtc.ToString('yyyy-MM-dd HH:mm:ss.fff')) UTC" -ForegroundColor Yellow
        }
        if ($currentSummary.CriticalCount -eq 0) {
            Write-Host "[OK] Ninguno de esos eventos criticos pertenece a la ventana ACTUAL." -ForegroundColor Green
        }
    }

    if ($currentSummary.ProblemTls -or $historySummary.ProblemTls) {
        Write-Host ""
        Write-Host "Diagnostico TLS/certificados:" -ForegroundColor Cyan
        Write-Host "[INFO] DNS y TCP 443 correctos no garantizan que OneAgent acepte la cadena TLS." -ForegroundColor Cyan
        Write-Host "[INFO] La prueba TLS Windows/.NET es complementaria; los logs de OneAgent son la evidencia directa de su validacion de certificados." -ForegroundColor Cyan

        if ($currentSummary.ProblemSelfSigned) {
            Write-Host "[ERROR] El log actual reporta 'self-signed certificate in certificate chain'." -ForegroundColor Red
        } elseif ($historySummary.ProblemSelfSigned) {
            Write-Host "[INFO] El historial contiene 'self-signed certificate in certificate chain', pero no necesariamente pertenece a la ventana actual." -ForegroundColor Yellow
        }

        if ($proxyConfigured) {
            Write-Host "[INFO] OneAgent usa un proxy configurado explicitamente." -ForegroundColor Cyan
            if ($null -ne $certificateFiles) {
                if ($certificateFiles.CustomProxy.Exists -and $certificateFiles.CustomProxy.CertificateCount -gt 0 -and -not $certificateFiles.CustomProxy.PrivateKeyDetected) {
                    Write-Host "[INFO] custom-proxy.pem existe con $($certificateFiles.CustomProxy.ParsedCount) certificado(s) interpretable(s)." -ForegroundColor Cyan
                } else {
                    Write-Host "[ADVERTENCIA] Revisar $CustomProxyPemPath" -ForegroundColor Yellow
                }
            }
        } else {
            Write-Host "[INFO] OneAgent no tiene proxy configurado explicitamente." -ForegroundColor Cyan
            if ($null -ne $certificateFiles -and $certificateFiles.CustomProxy.Exists) {
                Write-Host "[ADVERTENCIA] custom-proxy.pem existe, pero OneAgent lo ignora cuando no tiene proxy explicito configurado." -ForegroundColor Yellow
            }
            Write-Host "Si existe inspeccion TLS transparente, solicitar exclusion/bypass de los endpoints Dynatrace o validar la arquitectura de proxy con Redes/Seguridad." -ForegroundColor Yellow
        }
    }

    Write-Host ""
    Write-Host "Resultado final:" -ForegroundColor Yellow

    switch ($diagnosticState) {
        "OK_ACTIVA" {
            Write-Host "ESTADO: OK - COMUNICACION ACTIVA CON DYNATRACE" -ForegroundColor Green
            Write-Host "OneAgent esta Running, tiene Tenant/Communication Endpoints validos, reporta un endpoint activo (*) y no hay errores criticos en la ventana actual." -ForegroundColor Green
            Write-Host "La presencia del host con datos recientes en Dynatrace sigue siendo la validacion end-to-end." -ForegroundColor Green
        }
        "OK_RESTABLECIDA" {
            Write-Host "ESTADO: OK - COMUNICACION ACTIVA / RESTABLECIDA" -ForegroundColor Green
            Write-Host "Actualmente no se detectan errores criticos y OneAgent reporta un endpoint activo (*)." -ForegroundColor Green
            Write-Host "El historial de 60 minutos contiene fallos anteriores; conviene observar estabilidad, pero esos eventos no convierten por si solos el estado actual en ERROR." -ForegroundColor Yellow
        }
        "OK" {
            Write-Host "ESTADO: OK" -ForegroundColor Green
            Write-Host "La configuracion local, la conectividad de red y los logs recientes son compatibles con comunicacion efectiva de OneAgent hacia Dynatrace." -ForegroundColor Green
        }
        "CONECTIVIDAD_OK_PENDIENTE_CONFIRMACION" {
            Write-Host "ESTADO: CONECTIVIDAD OK - COMUNICACION PENDIENTE DE CONFIRMACION" -ForegroundColor Yellow
            Write-Host "Servicio, Tenant y conectividad base estan disponibles y no se detectan errores criticos recientes." -ForegroundColor Yellow
            Write-Host "Sin embargo, no existe marcador activo aplicable ni evidencia positiva suficiente para confirmar envio efectivo de telemetria." -ForegroundColor Yellow
            Write-Host "Validar que el host aparezca en Dynatrace con datos recientes." -ForegroundColor Yellow
        }
        "ADVERTENCIA" {
            Write-Host "ESTADO: ADVERTENCIA" -ForegroundColor Yellow
            if ($recoveredAfterError) {
                Write-Host "La comunicacion mostro errores en la ventana actual, pero hay evidencia posterior de recuperacion. Conviene verificar estabilidad y datos recientes en Dynatrace." -ForegroundColor Yellow
            } else {
                Write-Host "No se detecto una falla critica concluyente en todas las capas, pero existen validaciones parciales o anomalias que requieren revision." -ForegroundColor Yellow
            }
            if ($warnings.Count -gt 0) {
                Write-Host ""
                Write-Host "Advertencias:" -ForegroundColor Yellow
                foreach ($warning in $warnings) { Write-Host "- $warning" -ForegroundColor Yellow }
            }
        }
        "ERROR" {
            Write-Host "ESTADO: ERROR" -ForegroundColor Red
            Write-Host "Se detectaron condiciones ACTUALES que pueden impedir la comunicacion de OneAgent con Dynatrace." -ForegroundColor Red
            Write-Host ""
            Write-Host "Problemas detectados:" -ForegroundColor Red
            foreach ($issue in $issues) { Write-Host "- $issue" -ForegroundColor Red }

            if ($currentSummary.ProblemTls) {
                Write-Host ""
                Write-Host "Accion recomendada para TLS:" -ForegroundColor Cyan
                if ($proxyConfigured) {
                    Write-Host "- Confirmar la CA raiz/intermedias que presenta el proxy e incluir las CA necesarias como certificados publicos en custom-proxy.pem cuando corresponda." -ForegroundColor Yellow
                    Write-Host "- Verificar que el archivo no tenga PRIVATE KEY, certificados expirados ni una CA distinta a la cadena real del proxy." -ForegroundColor Yellow
                    Write-Host "- Reiniciar OneAgent despues de corregir la configuracion/certificados y volver a ejecutar este diagnostico." -ForegroundColor Yellow
                } else {
                    Write-Host "- Confirmar con Redes/Seguridad si existe inspeccion TLS transparente entre el servidor y Dynatrace." -ForegroundColor Yellow
                    Write-Host "- Solicitar bypass/exclusion de inspeccion TLS para los endpoints Dynatrace, o definir un proxy explicito soportado si esa es la arquitectura requerida." -ForegroundColor Yellow
                    Write-Host "- No asumir que custom-proxy.pem sera leido mientras --get-proxy no muestre un proxy configurado." -ForegroundColor Yellow
                }
            }
        }
    }

    if ($observations.Count -gt 0) {
        Write-Host ""
        Write-Host "Observaciones:" -ForegroundColor Yellow
        foreach ($observation in $observations) { Write-Host "- $observation" -ForegroundColor Yellow }
    }

    if ($currentFindings.Count -gt 0) {
        Write-Host ""
        Write-Host "Eventos relevantes de la ventana ACTUAL:" -ForegroundColor Cyan
        $currentFindings |
            Sort-Object EventTimeUtc |
            Select-Object -Last 20 |
            ForEach-Object {
                $eventText = if ($null -ne $_.EventTimeUtc) {
                    $_.EventTimeUtc.ToString("yyyy-MM-dd HH:mm:ss.fff 'UTC'")
                } else {
                    $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
                }
                Write-Host "[$eventText] $($_.Line)" -ForegroundColor $_.Severity
            }
    } elseif ($historicalInstability -and $null -ne $historySummary.LatestErrorEvent) {
        Write-Host ""
        Write-Host "Ultimo evento critico del historial (fuera de la ventana actual):" -ForegroundColor Cyan
        Write-Host "[$($historySummary.LatestErrorEvent.EventTimeUtc.ToString("yyyy-MM-dd HH:mm:ss.fff 'UTC'"))] $($historySummary.LatestErrorEvent.Line)" -ForegroundColor Yellow
    }

    if ($currentSummary.Problem410 -and -not $recoveredAfterError) {
        Write-Host ""
        Write-Host "El HTTP 410 fue encontrado DESPUES del inicio de la ventana actual." -ForegroundColor Yellow
        Write-Host "Antes de cambiar nuevamente de tenant, valida que el Environment ID mostrado arriba sea el esperado." -ForegroundColor Yellow
        $answer = Read-Host "Quieres cambiar el OneAgent a un nuevo tenant? (S/N)"
        if ($answer -match "^[sS]$") { Set-NewTenant }
    }

    Pause-Menu
}

function Invoke-OneAgentCtlCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $rawOutput = & $OneAgentCtl @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $outputText = (($rawOutput | Out-String).Trim())

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $outputText
    }
}

function Get-OneAgentTenantTokenSnapshot {
    # El token se captura solo en memoria para comparar antes/despues.
    # Nunca se imprime en consola.
    $result = Invoke-OneAgentCtlCapture -Arguments @('--get-tenant-token')

    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{
            Available = $false
            Value     = $null
        }
    }

    return [pscustomobject]@{
        Available = $true
        Value     = [string]$result.Output
    }
}

function Test-ServerContainsEndpoint {
    param(
        [string]$CurrentServer,
        [string]$ExpectedServer
    )

    if ([string]::IsNullOrWhiteSpace($CurrentServer) -or
        [string]::IsNullOrWhiteSpace($ExpectedServer)) {
        return $false
    }

    $current = $CurrentServer.Trim()
    $expected = $ExpectedServer.Trim().TrimEnd('/')

    # Primero intenta una comparacion literal ignorando mayusculas/minusculas.
    if ($current.IndexOf($expected, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        return $true
    }

    # oneagentctl puede normalizar HTTPS agregando :443 al mostrar --get-server.
    # En ese caso validamos host + path para evitar un falso negativo.
    try {
        $expectedUri = [System.Uri]$expected
        $hostOk = ($current.IndexOf($expectedUri.Host, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
        $pathOk = ($current.IndexOf($expectedUri.AbsolutePath.TrimEnd('/'), [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
        return ($hostOk -and $pathOk)
    } catch {
        return $false
    }
}

function Wait-OneAgentRunning {
    param(
        [int]$TimeoutSeconds = 30
    )

    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        $service = Get-Service -Name 'Dynatrace OneAgent' -ErrorAction SilentlyContinue
        if ($null -ne $service -and $service.Status -eq 'Running') {
            return $true
        }

        Start-Sleep -Seconds 2
        $elapsed += 2
    }

    return $false
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

    # Captura de configuracion previa. El token nunca se imprime.
    $beforeInfo = Get-OneAgentRuntimeInfo
    $beforeToken = Get-OneAgentTenantTokenSnapshot

    Write-Host ""
    Write-Host "Configuracion actual antes del cambio:" -ForegroundColor Cyan
    Write-Host "Tenant: $($beforeInfo.Tenant)"
    Write-Host "Server: $($beforeInfo.Server)"
    Write-Host "TenantToken: [oculto; solo se compara internamente]"

    Write-Host ""
    Write-Host "Nueva configuracion a aplicar:" -ForegroundColor Yellow
    Write-Host "Tenant:      $newTenant"
    Write-Host "TenantToken: $(Mask-Secret -Value $tenantToken)"
    Write-Host "Server:      $newServer"
    Write-Host ""
    Write-Host "Importante: no se imprime el tenant token completo en esta confirmacion." -ForegroundColor Cyan
    Write-Host "Los tres parametros se aplicaran en una sola ejecucion de oneagentctl con --restart-service." -ForegroundColor Cyan
    Write-Host ""

    $confirm = Read-Host "Confirmas aplicar cambios y reiniciar OneAgent? (S/N)"

    if ($confirm -notmatch "^[sS]$") {
        Write-Host "Operacion cancelada. No se realizaron cambios." -ForegroundColor Yellow
        $tenantToken = ""
        Pause-Menu
        return
    }

    Write-Host ""
    Write-Host "Aplicando configuracion y reiniciando OneAgent..." -ForegroundColor Yellow

    $oaArguments = @(
        "--set-tenant=$newTenant",
        "--set-tenant-token=$tenantToken",
        "--set-server=$newServer",
        "--restart-service"
    )

    $applyResult = Invoke-OneAgentCtlCapture -Arguments $oaArguments

    if (-not [string]::IsNullOrWhiteSpace($applyResult.Output)) {
        foreach ($line in ($applyResult.Output -split "`r?`n")) {
            Write-Host $line
        }
    }

    # Ya no es necesario conservar el token de entrada despues de ejecutar oneagentctl.
    $tenantTokenExpected = $tenantToken
    $tenantToken = ""

    Write-Host ""
    Write-Host "Codigo de salida de oneagentctl: $($applyResult.ExitCode)" -ForegroundColor Cyan

    $serviceRunning = Wait-OneAgentRunning -TimeoutSeconds 30

    # Captura posterior para verificar lo que realmente quedo configurado.
    $afterInfo = Get-OneAgentRuntimeInfo
    $afterToken = Get-OneAgentTenantTokenSnapshot

    $tenantComparable = (-not [string]::IsNullOrWhiteSpace([string]$beforeInfo.Tenant) -and
                         -not [string]::IsNullOrWhiteSpace([string]$afterInfo.Tenant))
    $serverComparable = (-not [string]::IsNullOrWhiteSpace([string]$beforeInfo.Server) -and
                         -not [string]::IsNullOrWhiteSpace([string]$afterInfo.Server))

    $tenantChanged = $false
    if ($tenantComparable) {
        $tenantChanged = ($beforeInfo.Tenant -ne $afterInfo.Tenant)
    }

    $serverChanged = $false
    if ($serverComparable) {
        $serverChanged = ($beforeInfo.Server -ne $afterInfo.Server)
    }

    $tokenComparable = ($beforeToken.Available -and $afterToken.Available)
    $tokenChanged = $false
    if ($tokenComparable) {
        $tokenChanged = ($beforeToken.Value -ne $afterToken.Value)
    }

    if ($applyResult.ExitCode -ne 0) {
        Write-Host ""
        Write-Host "ERROR: oneagentctl no pudo aplicar la nueva configuracion." -ForegroundColor Red

        if ($tenantComparable -and $serverComparable -and $tokenComparable -and
            -not $tenantChanged -and -not $serverChanged -and -not $tokenChanged) {
            Write-Host "Verificacion: NO se realizaron cambios de configuracion." -ForegroundColor Green
            Write-Host "Tenant, Tenant Token y Server permanecen iguales a los valores previos." -ForegroundColor Green
        } elseif ($tenantComparable -and $serverComparable -and
                  -not $tenantChanged -and -not $serverChanged -and -not $tokenComparable) {
            Write-Host "No se detectaron cambios en Tenant ni Server." -ForegroundColor Green
            Write-Host "El Tenant Token no pudo compararse de forma automatica en esta version de OneAgent." -ForegroundColor Yellow
        } else {
            Write-Host "ADVERTENCIA: se detecto alguna diferencia entre la configuracion previa y posterior." -ForegroundColor Red
            Write-Host "Revisa el estado mostrado a continuacion antes de volver a ejecutar el cambio." -ForegroundColor Yellow
        }

        Write-Host ""
        Write-Host "Configuracion posterior al intento:" -ForegroundColor Cyan
        Write-Host "Tenant: $($afterInfo.Tenant)"
        Write-Host "Server: $($afterInfo.Server)"
        Write-Host "Servicio OneAgent: $(if ($serviceRunning) { 'Running' } else { 'No confirmado como Running' })"

        $tenantTokenExpected = ""
        Pause-Menu
        return
    }

    $tenantOk = ($afterInfo.Tenant.Trim() -eq $newTenant.Trim())
    $serverOk = Test-ServerContainsEndpoint -CurrentServer $afterInfo.Server -ExpectedServer $newServer

    $tokenOk = $null
    if ($afterToken.Available) {
        $tokenOk = ($afterToken.Value -eq $tenantTokenExpected)
    }

    Write-Host ""
    Write-Host "Validacion posterior:" -ForegroundColor Cyan
    Write-Host "Tenant esperado: $newTenant"
    Write-Host "Tenant actual:   $($afterInfo.Tenant)"
    Write-Host "Server esperado: $newServer"
    Write-Host "Server actual:   $($afterInfo.Server)"
    Write-Host "Servicio OneAgent: $(if ($serviceRunning) { 'Running' } else { 'No confirmado como Running' })"

    if ($null -ne $tokenOk) {
        Write-Host "Tenant Token:    $(if ($tokenOk) { 'Validado correctamente' } else { 'NO coincide' })"
    } else {
        Write-Host "Tenant Token:    No fue posible validarlo automaticamente" -ForegroundColor Yellow
    }

    $allVerified = $tenantOk -and $serverOk -and $serviceRunning -and (($null -eq $tokenOk) -or $tokenOk)

    if ($allVerified) {
        Write-Host ""
        Write-Host "Cambio de Tenant aplicado y validado correctamente." -ForegroundColor Green
        if ($null -eq $tokenOk) {
            Write-Host "Nota: el Tenant Token no pudo verificarse por lectura directa, pero oneagentctl finalizo con codigo 0." -ForegroundColor Yellow
        }
    } else {
        Write-Host ""
        Write-Host "ADVERTENCIA: oneagentctl finalizo sin error, pero la validacion posterior no confirma todos los valores esperados." -ForegroundColor Red
        Write-Host "No se mostrara el cambio como exitoso hasta que Tenant, Server y servicio queden validados." -ForegroundColor Yellow
    }

    $tenantTokenExpected = ""
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
        Write-Host "9. Revisar certificados custom.pem / custom-proxy.pem"
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
            "9" { Show-OneAgentCertificateTrustFiles }
            "0" { Write-Host "Saliendo..." }
            default {
                Write-Host "Opcion invalida." -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }

    } while ($option -ne "0")
}

Show-Menu
