# Logical assets collectors

Este diretório é gerido automaticamente pelo `LogicalAssetReconcilerService` do `customer-agent`.

- Não guardar passwords neste diretório.
- Guardar apenas configuração de collector e tags V2 por logical asset.
- Segredos reais devem ficar em `client/compose/secrets/logical-secret-store.json`.
- Ficheiros `oms-logical-*.conf` são reconciliados por desired state vindo da central.
