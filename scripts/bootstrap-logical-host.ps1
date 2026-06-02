# Preparar Windows Server (bases de dados) para modo distributed-logical-hosts.
# Executar UMA VEZ como Administrador na VM remota.
# Depois use a conta de serviço no Assessment (passo «Acesso à máquina»).
#Requires -Version 5.1
param(
    [string]$ServiceUser = "oms-telegraf",
    [string]$InstallDir = "C:\Program Files\Telegraf"
)

$ErrorActionPreference = "Stop"

function Write-Status([string]$Message) {
    Write-Host "[bootstrap-logical-host] $Message"
}

function Write-ErrorStatus([string]$Message) {
    Write-Host "[bootstrap-logical-host][erro] $Message" -ForegroundColor Red
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-ErrorStatus "Execute como Administrador nesta VM remota."
    exit 1
}

if (-not (Test-Path -LiteralPath $InstallDir)) {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
}

$localUser = $null
try {
    $localUser = Get-LocalUser -Name $ServiceUser -ErrorAction SilentlyContinue
} catch {
    $localUser = $null
}

if (-not $localUser) {
  $tempPassword = [Guid]::NewGuid().ToString("N") + "Aa1!"
  $sec = ConvertTo-SecureString $tempPassword -AsPlainText -Force
  New-LocalUser -Name $ServiceUser -Password $sec -AccountNeverExpires | Out-Null
  Write-Status "Conta local $ServiceUser criada."
  Write-Status "Defina uma password permanente e use essa conta no Assessment."
  Write-Status "Password temporária (anote agora): $tempPassword"
}

$acl = Get-Acl -LiteralPath $InstallDir
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $ServiceUser,
    "Modify",
    "ContainerInherit,ObjectInherit",
    "None",
    "Allow"
)
$acl.SetAccessRule($rule)
Set-Acl -LiteralPath $InstallDir -AclObject $acl

$telegrafSvc = Get-Service -Name telegraf -ErrorAction SilentlyContinue
if ($telegrafSvc) {
    Write-Status "Serviço telegraf encontrado ($($telegrafSvc.Status))."
} else {
    Write-Status "AVISO: serviço telegraf não instalado. Instale o agente Telegraf antes de registar no Assessment."
    Write-Status "  https://docs.influxdata.com/telegraf/v1/install/"
}

Write-Status "OK: $ServiceUser pode escrever em $InstallDir."
Write-Status "Configure WinRM para essa conta e use-a no passo «Acesso à máquina» do Assessment."
