# OMS Client installer for Windows Server (ADR-006).
# Requires: Docker Desktop or Docker Engine on Windows, PowerShell 5.1+.
param(
    [Parameter(Mandatory = $true)][string]$Token,
    [Parameter(Mandatory = $true)][string]$CloudUrl,
    [string]$RuntimeAssetId = "",
    [string]$InstallDir = "$env:USERPROFILE\oms-client"
)

$ErrorActionPreference = "Stop"

Write-Host "OMS Client Windows installer"
Write-Host "  Cloud URL: $CloudUrl"
Write-Host "  Install dir: $InstallDir"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error "Docker nao encontrado. Instale Docker Desktop/Engine antes de continuar."
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Set-Location $InstallDir

if (-not (Test-Path ".\compose\docker-compose.yml")) {
    Write-Error "Execute este script a partir do repositorio OMS client (pasta compose/) ou copie client/ para $InstallDir"
}

$envContent = @"
ASSESSMENT_TOKEN=$Token
CENTRAL_API_URL=$CloudUrl
ASSESSMENT_API_URL=$CloudUrl
RUNTIME_ASSET_ID=$RuntimeAssetId
TENANT_ID=
CUSTOMER_ID=
OBSERVABILITY_MODE=centralized-runtime
"@
Set-Content -Path ".\compose\.env" -Value $envContent -Encoding UTF8

Push-Location compose
docker compose pull
docker compose up -d
Pop-Location

Write-Host "Instalacao concluida. Assessment: http://localhost:3111 (ajuste portas no compose se necessario)."
