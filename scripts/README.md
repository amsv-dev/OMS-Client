# Scripts OMS Client (VM)

Canal único de instalação e manutenção: **GitHub clone** + scripts desta pasta.

## Fluxo típico

```bash
git clone https://github.com/amsv-dev/OMS-Client.git ~/oms-client
cd ~/oms-client
bash scripts/install-oms-client.sh <TOKEN> "http://<API>:8443"
```

Depois: **Oramix Console** em `http://<IP-VM>:3122/` (Vault → conta admin → Hosts → Serviços).

## Scripts canónicos

| Script | Quando usar |
|--------|-------------|
| `install-oms-client.sh` | **Primeira instalação** — regista runtime host na central (só precisa do token) |
| `update-oms-client.sh` | Após `git pull` — pull imagens + recreate stack |
| `reset-client.sh` | `--runtime` limpa Vault/Influx/secrets; `--validate` QA; `--vm-nuke` apaga `~/oms-client` |
| `vault-ops.sh` | `check` (gate), `bootstrap`, `status`, `unseal`, `recovery-path` — requer API do agent em `127.0.0.1:LOCAL_RUNTIME_API_PORT` (publicada no compose) |

## O que cada parte faz

- **Runtime host (catálogo central):** `install-oms-client.sh` — não é a UI.
- **Cofre Vault:** wizard no Oramix Console ou `vault-ops.sh bootstrap`.
- **Hosts e serviços:** Oramix Console — o agent gera Telegraf em `compose/telegraf/dynamic/`.

## Pasta `e2e/` (QA interna)

| Script | Uso |
|--------|-----|
| `e2e/reset-runtime.sh` | Implementação de `reset-client.sh --runtime` |
| `e2e/reset-and-validate-e2e.sh` | `reset-client.sh --validate` |
| `e2e/e2e-client-setup.sh` | Lab sem token (`--solace-host`) |

## Documentação completa

- Repo OMSv2: `documentacao/operacoes/comandos-operacionais.md`
- E2E virgem: `documentacao/operacoes/e2e-virgem-completo-reset-e-browser-passo-a-passo.md`
