# Scripts OMS Client (VM)

Canal único de instalação e manutenção: **GitHub clone** + scripts desta pasta.

## Fluxo típico

```bash
git clone https://github.com/amsv-dev/OMS-Client.git ~/oms-client
cd ~/oms-client
bash scripts/install-oms-client.sh <TOKEN> "http://<API>:8443"
```

Depois: Assessment v2 em `http://<IP-VM>:3122/` (Entrada → Cofre → Bases lógicas).

## Scripts canónicos

| Script | Quando usar |
|--------|-------------|
| `install-oms-client.sh` | **Primeira instalação** — regista runtime host na central (só precisa do token) |
| `update-oms-client.sh` | Após `git pull` — pull imagens + recreate stack |
| `reset-client.sh` | `--runtime` limpa Vault/Influx/secrets; `--validate` QA; `--vm-nuke` apaga `~/oms-client` |
| `vault-ops.sh` | `bootstrap`, `status`, `unseal`, `recovery-path` |

## O que cada parte faz

- **Runtime host (catálogo central):** `install-oms-client.sh` — não é a UI.
- **Cofre Vault:** wizard na UI (Cofre) ou `vault-ops.sh bootstrap`.
- **Logical assets:** Assessment v2 (UI) — o agent gera Telegraf em `compose/telegraf/dynamic/`.

## Pasta `e2e/` (QA interna)

| Script | Uso |
|--------|-----|
| `e2e/reset-runtime.sh` | Implementação de `reset-client.sh --runtime` |
| `e2e/reset-and-validate-e2e.sh` | `reset-client.sh --validate` |
| `e2e/e2e-client-setup.sh` | Lab sem token (`--solace-host`) |

## Documentação completa

- Repo OMSv2: `documentacao/operacoes/comandos-operacionais.md`
- E2E virgem: `documentacao/operacoes/e2e-virgem-completo-reset-e-browser-passo-a-passo.md`
