# Logical assets collectors

Este diretório é usado para snippets gerados por asset lógico remoto (`postgresql`, `mysql`, `sqlserver`, `oracle`).

- Não guardar passwords neste diretório.
- Guardar apenas configuração de collector e tags V2 por logical asset.
- Segredos reais devem ficar em `client/compose/secrets/logical-assets.env`.

Use o script `client/scripts/add-logical-db-collector.sh` para gerar snippets consistentes.
