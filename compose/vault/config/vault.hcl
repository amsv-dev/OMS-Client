# OMS — HashiCorp Vault OSS configuration
# Storage: file backend, persisted in /vault/file (Docker volume)
# Listener: tcp 8200, TLS disabled (rede client-network apenas, sem exposicao ao host)
# UI: desactivado por defeito (cliente pode activar com VAULT_UI=true e mapeamento de porta)

ui = false

# disable_mlock = false faz o Vault chamar mlock() para impedir swap de
# chaves master. Requer IPC_LOCK no docker-compose (cap_add). Em ambientes
# Docker Desktop / WSL pode falhar; nesse caso, o operador ajusta para true
# como excepcao documentada e aceita o risco residual.
disable_mlock = false

api_addr     = "http://oms-vault:8200"
cluster_addr = "http://oms-vault:8201"

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = "true"
}

storage "file" {
  path = "/vault/file"
}

# Audit log file backend e activado em runtime pelo entrypoint.sh apos init,
# nao em config estatico (Vault rejeita audit em config file). Ver:
#   vault audit enable file file_path=/vault/logs/audit.log
