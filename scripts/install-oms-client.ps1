# OMS Client installer for Windows Server (ADR-006).
# Requires: Docker Engine/Desktop in Linux containers mode, Git, PowerShell 5.1+.
# Prefer Git Bash to reuse install-oms-client.sh (same Central onboarding as Linux).
# Encoding: UTF-8 with BOM (Windows PowerShell 5.1 cannot parse UTF-8 without BOM).
param(
    [Parameter(Mandatory = $true)][string]$Token,
    [Parameter(Mandatory = $true)][string]$CloudUrl,
    [string]$RuntimeAssetId = "",
    [string]$SiteCode = "",
    [string]$InstallDir = "",
    [string]$LogicalHostIp = ""
)

$ErrorActionPreference = "Stop"

function Write-Status([string]$Message) {
    Write-Host "[install] $Message"
}

function Write-Err([string]$Message) {
    Write-Host "[erro] $Message" -ForegroundColor Red
}

Write-Host "OMS Client Windows installer"
Write-Host "  Cloud URL: $CloudUrl"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Err "Docker nao encontrado. Instale Docker Desktop/Engine com Linux containers."
    exit 1
}

$dockerOs = ""
try {
    $dockerOs = (docker info --format "{{.OSType}}" 2>$null | Out-String).Trim()
} catch {
    $dockerOs = ""
}
if ($dockerOs -and $dockerOs -ne "linux") {
    Write-Err "Docker esta em modo '$dockerOs'. Troque para Linux containers (nao Windows containers)."
    exit 1
}
Write-Status "Docker OSType=$(if ($dockerOs) { $dockerOs } else { 'desconhecido (a assumir Linux containers)' })."

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoFromScript = Split-Path -Parent $scriptDir
if (-not $InstallDir) {
    if (Test-Path (Join-Path $repoFromScript "compose\docker-compose.yml")) {
        $InstallDir = $repoFromScript
    } else {
        $InstallDir = Join-Path $env:USERPROFILE "oms-client"
    }
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Set-Location $InstallDir

if (-not (Test-Path ".\compose\docker-compose.yml")) {
    Write-Status "Repo incompleto em $InstallDir - a clonar OMS-Client..."
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Err "git nao encontrado. Instale Git for Windows e volte a correr este script."
        exit 1
    }
    if ((Get-ChildItem -Force $InstallDir | Measure-Object).Count -gt 0) {
        Write-Err "A pasta $InstallDir nao esta vazia e nao tem compose/docker-compose.yml."
        exit 1
    }
    git clone --depth 1 https://github.com/amsv-dev/OMS-Client.git $InstallDir
    if ($LASTEXITCODE -ne 0) {
        Write-Err "git clone falhou."
        exit 1
    }
}

$bashCandidates = @(
    "$env:ProgramFiles\Git\bin\bash.exe",
    "${env:ProgramFiles(x86)}\Git\bin\bash.exe"
)
$bash = $bashCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $bash -and (Get-Command bash -ErrorAction SilentlyContinue)) {
    $bash = (Get-Command bash).Source
}

if ($bash) {
    Write-Status "A reutilizar install-oms-client.sh via $bash (mesmo onboarding que Linux)."
    $unixDir = ($InstallDir -replace '\\', '/')
    if ($unixDir -match '^([A-Za-z]):') {
        $unixDir = "/$($Matches[1].ToLower())$($unixDir.Substring(2))"
    }
    $argsList = @(
        "$unixDir/scripts/install-oms-client.sh",
        $Token,
        $CloudUrl
    )
    if ($SiteCode) { $argsList += @("--site-code", $SiteCode) }
    if ($LogicalHostIp) { $argsList += @("--logical-host-ip", $LogicalHostIp) }
    & $bash @argsList
    exit $LASTEXITCODE
}

Write-Status "Git Bash nao encontrado - caminho nativo PowerShell (sem runtime-smoke.sh)."

$apiUrl = $CloudUrl.TrimEnd("/")
$validateUrl = "$apiUrl/api/console/validate"
if ($SiteCode) {
    $validateUrl = "${validateUrl}?siteCode=$SiteCode"
}

Write-Status "A validar token na Central..."
try {
    $headers = @{ "X-Tenant-Token" = $Token }
    $identity = Invoke-RestMethod -Uri $validateUrl -Headers $headers -Method Get
} catch {
    Write-Err "Falha em $validateUrl : $($_.Exception.Message)"
    exit 1
}

$tenantId = $identity.runtimeIdentity.tenantId
$assetId = $identity.runtimeIdentity.assetId
if (-not $assetId -and $RuntimeAssetId) { $assetId = $RuntimeAssetId }
$siteCodeResolved = $identity.runtimeIdentity.siteCode
if (-not $tenantId -or -not $assetId) {
    Write-Err "Resposta invalida da API. Token pode estar expirado."
    exit 1
}

function Get-RuntimeLanIp {
    $addrs = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notmatch '^127\.' -and $_.IPAddress -notmatch '^169\.254\.' }
    $preferred = $addrs | Where-Object { $_.IPAddress -like '10.*' -or $_.IPAddress -like '192.168.*' -or $_.IPAddress -like '172.*' } |
        Select-Object -First 1
    if ($preferred) { return $preferred.IPAddress }
    if ($addrs) { return ($addrs | Select-Object -First 1).IPAddress }
    return $null
}

$lanIp = if ($LogicalHostIp) { $LogicalHostIp } else { Get-RuntimeLanIp }
if (-not $lanIp) {
    Write-Err "Nao foi possivel detetar IP LAN. Passe -LogicalHostIp."
    exit 1
}
$logicalHostInflux = "http://${lanIp}:8087"
Write-Status "LOGICAL_HOST_INFLUX_URL=$logicalHostInflux"

$composeDir = Join-Path $InstallDir "compose"
$secretsDir = Join-Path $composeDir "secrets"
New-Item -ItemType Directory -Force -Path $secretsDir | Out-Null
Set-Content -Path (Join-Path $secretsDir "console-token.txt") -Value $Token -Encoding ascii -NoNewline

docker network create oms-shared-network 2>$null | Out-Null
docker volume create compose_influxdb-local-data 2>$null | Out-Null

$solaceHost = $identity.solace.host
$solaceUser = $identity.solace.username
$solacePass = $identity.solace.password
$tenantName = $identity.tenantName
$issuedAt = $identity.runtimeIdentity.issuedAtUtc
$expiresAt = $identity.runtimeIdentity.expiresAtUtc
$nonce = $identity.runtimeIdentity.nonce
$signature = $identity.runtimeIdentity.signature
$hostName = $env:COMPUTERNAME.ToLowerInvariant()

$envContent = @"
TENANT_ID=$tenantId
TENANT_NAME=$tenantName
ASSET_ID=$assetId
SITE_CODE=$siteCodeResolved
RUNTIME_ASSET_ID=$assetId
COLLECTOR_TYPE=telegraf
ORIGIN_SCOPE=local
SERVICE_TYPE=host
OBSERVABILITY_MODE=distributed-logical-hosts
MAX_SERVICES=25
SERVICE_LIMIT_SCOPE=total
COLLECTOR_PLACEMENT_STRATEGY=per-host-group
COLLECTOR_AUTO_SCALE_ENABLED=false
OMS_COMPOSE_PROJECT_NAME=compose
OMS_COMPOSE_HOST_PROJECT_DIR=/app/oms-compose-workdir
CENTRAL_API_URL=$apiUrl
CONSOLE_TOKEN=$Token
CONSOLE_TOKEN_FILE=/app/secrets/console-token.txt
LOGICAL_HOST_INFLUX_URL=$logicalHostInflux
LOGICAL_HOST_CONFIG_DIR=/opt/oms/telegraf
LOCAL_RUNTIME_API_PORT=5808
LOCAL_RUNTIME_API_URL=/runtime-local
SOLACE__HOST=$solaceHost
SOLACE__PORT=1883
SOLACE__VPN=default
SOLACE__USERNAME=$solaceUser
SOLACE__PASSWORD=$solacePass
ASPNETCORE_ENVIRONMENT=Production
INFLUXDB_LOCAL_ORG=client
INFLUXDB_LOCAL_BUCKET=metrics
INFLUXDB_LOCAL_TOKEN=client-local-token
INFLUXDB_ADMIN_PASSWORD=localpass123
"@
Set-Content -Path (Join-Path $composeDir ".env") -Value $envContent -Encoding utf8

$validateBody = @{
    consoleToken = $Token
    activateRuntime = $false
    runtimeHealthStatus = "bootstrap-validated"
    bundle = @{
        tenantId = $tenantId
        assetId = $assetId
        siteCode = $siteCodeResolved
        issuedAtUtc = $issuedAt
        expiresAtUtc = $expiresAt
        nonce = $nonce
        signatureVersion = "hmac-sha256-v1"
        signature = $signature
    }
    hostname = $hostName
    address = $lanIp
    assetName = $hostName
    instanceLabel = $hostName
} | ConvertTo-Json -Depth 6

Write-Status "A validar bundle..."
try {
    Invoke-RestMethod -Uri "$apiUrl/api/console/runtime/validate-bundle" -Method Post -ContentType "application/json" -Body $validateBody | Out-Null
} catch {
    Write-Err "Validacao do bundle falhou: $($_.Exception.Message)"
    Write-Err "Dica: siteCode unico por VM (-SiteCode)."
    exit 1
}

Push-Location $composeDir
try {
    Write-Status "A atualizar imagens (docker compose pull)..."
    docker compose --env-file .env pull
    Write-Status "A arrancar stack (Linux containers)..."
    docker compose --env-file .env up -d --remove-orphans
} finally {
    Pop-Location
}

$activateBody = @{
    consoleToken = $Token
    activateRuntime = $true
    runtimeHealthStatus = "active"
    runtimeCheckedAtUtc = [DateTime]::UtcNow.ToString("o")
    bundle = @{
        tenantId = $tenantId
        assetId = $assetId
        siteCode = $siteCodeResolved
        issuedAtUtc = $issuedAt
        expiresAtUtc = $expiresAt
        nonce = $nonce
        signatureVersion = "hmac-sha256-v1"
        signature = $signature
    }
    hostname = $hostName
    address = $lanIp
    assetName = $hostName
    instanceLabel = $hostName
} | ConvertTo-Json -Depth 6

Write-Status "A ativar runtime na Central..."
try {
    Invoke-RestMethod -Uri "$apiUrl/api/console/runtime/validate-bundle" -Method Post -ContentType "application/json" -Body $activateBody | Out-Null
} catch {
    Write-Host "[aviso] Ativacao do runtime falhou (stack ja pode estar a correr): $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host "Instalacao concluida. Oramix Console: http://localhost:3122"
Write-Host "Nota: /proc /sys /var/log no compose medem a VM Linux do Docker, nao o Event Log do Windows Server."
