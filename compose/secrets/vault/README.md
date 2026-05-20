# `secrets/vault/` — Volume host do Vault OMS

Esta pasta é **gerada em runtime** pelo container `oms-vault` na primeira execução. NÃO commitar nenhum ficheiro além deste README.

## Ficheiros que vais ver depois do primeiro arranque

| Ficheiro | Conteúdo | Acção do cliente |
|---|---|---|
| `recovery-keys-FIRST-BOOT-ONLY.json` | 5 recovery keys Shamir + root token | **Copiar IMEDIATAMENTE para 2 cofres offline e depois apagar** |
| `autounseal.key` | 3 das 5 shares cifradas com a chave SO local | Manter no disco; é usado pelo auto-unseal |
| `.autounseal-key` | Chave AES-256 random de 32 bytes para cifrar/decifrar `autounseal.key` | Manter no disco; perdê-la força DR via recovery keys |
| `.initialized` | Marker booleano | Não tocar |
| `.unsealed` | Marker para healthcheck do docker | Não tocar |

## Procedimento de backup (resumo)

Detalhe completo em [documentacao/operacoes/vault-backup-checklist.md](../../../../documentacao/operacoes/vault-backup-checklist.md).

1. Abrir `recovery-keys-FIRST-BOOT-ONLY.json`
2. Copiar os 5 valores `unseal_keys_b64[]` e o `root_token` para:
   - Pen USB encriptada (VeraCrypt/BitLocker)
   - Gestor de passwords corporativo (KeePass/1Password)
   - Opcionalmente impresso em papel num cofre físico
3. **Apagar o ficheiro `recovery-keys-FIRST-BOOT-ONLY.json` deste directório**:
   ```bash
   rm client/compose/secrets/vault/recovery-keys-FIRST-BOOT-ONLY.json
   ```

O `.gitignore` da raiz já protege estes ficheiros contra commit acidental, mas a recomendação é remover do disco após backup.
