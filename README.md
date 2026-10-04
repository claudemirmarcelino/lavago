# LavaGo

Sistema de gerenciamento e automação de lavanderias self-service.

Fluxo previsto: escolha da máquina e serviço → pedido → pagamento → confirmação
validada pelo backend → autorização → início físico do ciclo → acompanhamento → fim.

## Estado atual

Fundação inicial: estrutura, ferramentas do Supabase, configuração local e documentação.
Primeira migration preparada: perfis, máquinas, serviços e compatibilidade entre
máquinas e serviços, com RLS e testes pgTAP. Reset e lint concluídos; 13 testes
aprovados no ambiente local em 2026-10-04.
Segunda migration aplicada localmente: pedidos e reservas com operações exclusivas
do backend. Lint sem erros, 35 testes SQL e dois cenários de concorrência aprovados
na stack completa em 2026-10-04.
Terceira migration aplicada localmente: modelo de pagamentos, ciclos, comandos,
webhooks e auditoria, sem operações financeiras ou acionamento. Lint sem erros;
63 testes SQL e dois cenários concorrentes passaram na stack local via conexão direta.
Ainda não há aplicativo, Edge Functions de pedidos, gateway, automação ou CI.

Quarta migration aplicada: confirmação de pagamento previamente verificado pelo
backend, autorização, ciclo, comando pendente e auditoria em uma única transação.
88 testes SQL e cinco cenários concorrentes passaram; lint sem erros. Não há cobrança
real, endpoint público de confirmação ou envio de comandos físicos.

## Estrutura

```text
apps/mobile/             Aplicativo futuro, tecnologia ainda aberta
supabase/config.toml     Configuração local
supabase/migrations/     Histórico SQL versionado
supabase/functions/      Backend futuro
supabase/seed.sql        Dados fictícios, inicialmente vazio
docs/architecture/       Decisões e estratégia de banco
docs/api/                Contratos futuros
```

## Desenvolvimento local

Pré-requisitos: Git, Node.js 22 com npm e Docker Desktop com engine Linux em execução.
A CLI Supabase está fixada no package.json e package-lock.json. Node serve às
ferramentas de desenvolvimento; não é uma decisão sobre o frontend.

Na raiz do repositório:

```sh
npm ci
npm run dev:start
npm run dev:status
```

No PowerShell, se a política bloquear npm.ps1, utilize `npm.cmd` nos comandos.
O primeiro start baixa imagens e pode levar alguns minutos. Não é necessário
executar init: a configuração já está versionada.

Copie `.env.example` para `.env` quando houver um consumidor dessas variáveis.
Não publique a saída de status: ela pode conter credenciais locais. O exemplo
não é carregado automaticamente pela CLI nem pelos scripts. Não forneça chaves
de staging ou produção ao ambiente local.

Serviços locais previstos: API em http://127.0.0.1:54321, Studio em
http://127.0.0.1:54323 e caixa de emails de teste em http://127.0.0.1:54324.
A confirmação de email está habilitada; mensagens locais serão capturadas na caixa de teste.
Os endereços são para a máquina de desenvolvimento; acesso por Android será configurado depois.

```sh
npm run db:reset
npm run db:lint
npm run db:test
npm run db:test:concurrency
npm run dev:stop
```

`db:reset` apaga os dados do banco LOCAL e reaplica migrations e seed.
Não há scripts de deploy remoto neste incremento.

## Documentação e próximos passos

- [Arquitetura e decisões](docs/architecture/0001-foundation.md)
- [Proposta do modelo de domínio](docs/architecture/0002-domain-model.md)
- [Ambientes e migrations](docs/architecture/migrations.md)
- [Contratos de pedidos e reservas](docs/api/orders.md)
- [Base financeira e execução física](docs/architecture/0003-payments-automation-foundation.md)
- [Confirmação verificada e autorização](docs/api/verified-payments.md)
- [Validação desta fundação](docs/architecture/validation.md)

Próxima sequência: entrega e confirmação de comandos/ciclo com simulação,
reconciliação de timeout → introduzir CI → integrações.
Cada tarefa deve seguir branch → desenvolvimento → testes → commit → PR → revisão → merge.

Referências oficiais: [CLI e desenvolvimento local](https://supabase.com/docs/guides/local-development/cli/getting-started)
e [migrations](https://supabase.com/docs/guides/local-development/database-migrations).
