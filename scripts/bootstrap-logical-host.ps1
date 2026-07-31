# Preparar Windows Server (bases de dados) para modo distributed-logical-hosts.
# Autenticação SSH exclusiva por chave PEM (OpenSSH Server).
#Requires -Version 5.1
param(
    [string]$ServiceUser = "oms-telegraf",
    [string]$InstallDir = "C:\Program Files\Telegraf",
    [string]$KeyDir = "C:\ProgramData\oms\bootstrap-keys",
    [switch]$GenerateKeypair,
    [string]$AuthorizedKey = "",
    [string]$AuthorizedKeyFile = "",
    [switch]$NonInteractive
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

function Ensure-OpenSshServer {
    $cap = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue
    if ($cap -and $cap.State -ne "Installed") {
        Write-Status "A instalar OpenSSH Server..."
        Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
    }
    $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-ErrorStatus "Serviço sshd não encontrado após instalação OpenSSH."
        exit 1
    }
    if ($svc.StartType -ne "Automatic") {
        Set-Service -Name sshd -StartupType Automatic
    }
    if ($svc.Status -ne "Running") {
        Start-Service sshd
    }
    try {
        New-NetFirewallRule -Name "OMS-OpenSSH-Server-In" -DisplayName "OMS OpenSSH Server (TCP 22)" `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -ErrorAction Stop | Out-Null
    } catch {
        if ($_.Exception.Message -notmatch "already exists") {
            Write-Status "AVISO: não foi possível criar regra firewall (pode já existir): $($_.Exception.Message)"
        }
    }
    Write-Status "OpenSSH Server activo (porta 22)."
}

function Ensure-ServiceUser {
    $localUser = Get-LocalUser -Name $ServiceUser -ErrorAction SilentlyContinue
    if (-not $localUser) {
        $random = [Guid]::NewGuid().ToString("N")
        $sec = ConvertTo-SecureString $random -AsPlainText -Force
        New-LocalUser -Name $ServiceUser -Password $sec -AccountNeverExpires -UserMayNotChangePassword | Out-Null
        Write-Status "Conta local $ServiceUser criada (login apenas por chave SSH)."
    }
}

function Set-InstallDirAcl {
    if (-not (Test-Path -LiteralPath $InstallDir)) {
        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    }
    $acl = Get-Acl -LiteralPath $InstallDir
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $ServiceUser, "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")
    $acl.SetAccessRule($rule)
    Set-Acl -LiteralPath $InstallDir -AclObject $acl
    Write-Status "OK: $ServiceUser pode escrever em $InstallDir."
}

function Install-AuthorizedKeyLine {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    $profile = Get-CimInstance Win32_UserProfile | Where-Object { $_.LocalPath -like "*\$ServiceUser" } | Select-Object -First 1
    $home = $null
    if ($profile) {
        $home = $profile.LocalPath
    } else {
        $home = "C:\Users\$ServiceUser"
    }
    $sshDir = Join-Path $home ".ssh"
    New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
    $authKeys = Join-Path $sshDir "authorized_keys"
    if (-not (Test-Path $authKeys)) {
        New-Item -ItemType File -Force -Path $authKeys | Out-Null
    }
  $content = Get-Content $authKeys -ErrorAction SilentlyContinue
    if ($content -notcontains $Line.Trim()) {
        Add-Content -Path $authKeys -Value $Line.Trim()
        Write-Status "Chave pública adicionada a $authKeys"
    } else {
        Write-Status "Chave pública já presente em authorized_keys."
    }
    icacls $sshDir /inheritance:r /grant "Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)F" "$ServiceUser:(OI)(CI)F" | Out-Null
}

function Show-PrivateKeyBanner {
    param([string]$PrivateKeyPath)
    Write-Status ""
    Write-Status "======== COLE ESTA CHAVE PRIVADA NO ASSESSMENT (passo Acesso à máquina) ========"
    Get-Content -LiteralPath $PrivateKeyPath -Raw
    Write-Status "======== FIM DA CHAVE PRIVADA — guarde em local seguro ========"
    Write-Status ""
}

function New-OmsKeypair {
    if (-not (Test-Path $KeyDir)) {
        New-Item -ItemType Directory -Force -Path $KeyDir | Out-Null
    }
    $priv = Join-Path $KeyDir "$ServiceUser-oms-bootstrap"
    $pub = "$priv.pub"
    if (-not (Test-Path $priv)) {
        ssh-keygen -t ed25519 -f $priv -N [string]::Empty -C "oms-bootstrap-$ServiceUser@$env:COMPUTERNAME"
    }
    $pubLine = Get-Content $pub -Raw
    Install-AuthorizedKeyLine $pubLine.Trim()
    Show-PrivateKeyBanner $priv
}

Ensure-OpenSshServer
Ensure-ServiceUser
Set-InstallDirAcl

if ($GenerateKeypair) {
    New-OmsKeypair
} elseif ($AuthorizedKey) {
    Install-AuthorizedKeyLine $AuthorizedKey
    Write-Status "Chave pública configurada. Use a chave privada correspondente no Oramix Console."
} elseif ($AuthorizedKeyFile) {
    if (-not (Test-Path $AuthorizedKeyFile)) {
        Write-ErrorStatus "Ficheiro não encontrado: $AuthorizedKeyFile"
        exit 1
    }
    Install-AuthorizedKeyLine (Get-Content $AuthorizedKeyFile -Raw)
} elseif ($NonInteractive) {
    Write-ErrorStatus "Modo não-interactivo: use -GenerateKeypair ou -AuthorizedKey / -AuthorizedKeyFile"
    exit 1
} else {
    Write-Status "Como configurar autenticação SSH para $ServiceUser ?"
    Write-Status "  1) Gerar novo par de chaves (recomendado)"
    Write-Status "  2) Ficheiro de chave pública (.pub)"
    Write-Status "  3) Colar linha authorized_keys"
    $choice = Read-Host "Escolha [1]"
    switch ($choice) {
        "2" {
            $path = Read-Host "Caminho para ficheiro .pub"
            if (-not (Test-Path $path)) { Write-ErrorStatus "Ficheiro não encontrado."; exit 1 }
            Install-AuthorizedKeyLine (Get-Content $path -Raw)
        }
        "3" {
            $line = Read-Host "Cole a linha authorized_keys"
            Install-AuthorizedKeyLine $line
        }
        default { New-OmsKeypair }
    }
}

$telegrafSvc = Get-Service -Name telegraf -ErrorAction SilentlyContinue
if ($telegrafSvc) {
    Write-Status "Serviço telegraf encontrado ($($telegrafSvc.Status))."
} else {
    Write-Status "AVISO: serviço telegraf não instalado. Instale antes de registar no Oramix Console."
    Write-Status "  https://docs.influxdata.com/telegraf/v1/install/"
}

Write-Status "Concluído. No Oramix Console: utilizador «$ServiceUser», porta SSH 22, chave PEM privada."
