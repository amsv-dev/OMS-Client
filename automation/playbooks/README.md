# Playbooks Locais (Cliente)

Esta pasta contém o pack global de playbooks executados localmente pelo `Oms.CustomerAgent`.

Regras operacionais:

- Apenas playbooks whitelisted no agente podem ser executados.
- Sem credenciais OMS neste diretório.
- Sem shell arbitrária: cada ação deve mapear para um playbook conhecido.
- Versionamento do pack é publicado no bundle de release cliente.
