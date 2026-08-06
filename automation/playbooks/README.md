# Playbooks Locais (Cliente)

Pack global de playbooks executados pelo `Oms.CustomerAgent` (ADR-017).

## Modelo

- **Inventário canónico:** CMDB (Oramix Console). Sem inventário Ansible estático.
- **Runtime (local):** `ansible-playbook -i localhost, -c local`
- **Alvo remoto:** inventory efémero + SSH (PEM no Vault do client); agentless — sem Ansible agent nos hosts lógicos.
- Whitelist no `CommandReceiverService`; parâmetros sanitizados.

## Playbooks

| Playbook | Notas |
|----------|--------|
| `rotate_logs` | Template seguro |
| `restart_service` | Extra-var `service_name` (unidade systemd) |
| `reboot_host` | Só âmbito alvo (remoto); skip em local |
| `backup_database` | Template no-op |
| `deploy_nginx` / `update_packages` / `configure_monitoring` | Templates |

YAML usa `hosts: all`; a connection vem do CLI/inventory.
