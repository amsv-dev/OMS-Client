# Telegraf no runtime (métricas da VM OMS)

O `client-telegraf` mede CPU/mem/disco **desta** VM. Plugins de BD e SO remoto correm no `oms-telegraf` de cada host lógico (ADR-018).

- Não guardar passwords neste diretório.
- Não deixar snippets `oms-service-*.conf` / `oms-logical-*.conf` de BD em `dynamic/runtime/` — o reconciler apaga-os.
