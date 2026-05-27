# `secrets/vault/` — Volume host do Vault OMS

Esta pasta é **gerada em runtime** pelo container `oms-vault` e pelo `customer-agent`. NÃO commitar ficheiros sensíveis (`.gitignore` protege).

## Ficheiros em runtime (ADR-011)

| Ficheiro | Conteúdo | Acção |
|---|---|---|
| `autounseal.bin` | 3 shares Shamir cifradas (auto-unseal) | **Manter** no disco |
| `.recovery-backup-acknowledged` | Marker: operador confirmou backup | Criado após ack |
| `recovery-keys-FIRST-BOOT-ONLY.json` | **Legacy** — não deve existir em instalações novas | Apagar após migração / `ack-recovery` |

## Bootstrap (instalações novas)

1. UI Assessment → Cofre → **Activar cofre** → passo **Backup** (keys uma vez)
2. Ou CLI: `bash scripts/vault-ops.sh bootstrap` → guardar JSON no stdout offline
3. Confirmar: wizard «Concluir activação» ou `bash scripts/vault-ops.sh ack-recovery`

As **5 recovery keys** não são gravadas em plaintext no host. Ver [ADR-011](../../../documentacao/decisoes/ADR-011-vault-recovery-ceremony.md) e [vault-backup-checklist.md](../../../documentacao/operacoes/vault-backup-checklist.md).
