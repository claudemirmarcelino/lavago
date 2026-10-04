# Validação da fundação

## Resultado confirmado em 2026-10-04

Evidência: captura do terminal enviada pelo usuário após executar os comandos
na branch chore/project-foundation.

- Supabase local iniciou após recuperação do Docker e liberação de espaço.
- db:reset aplicou 20261004000100_profiles_catalog.sql e terminou com sucesso.
- db:lint informou No schema errors found.
- db:test informou All tests successful, Files=1, Tests=13, Result: PASS.

A suíte cobre criação automática de perfis, isolamento entre dois usuários,
edição de nome próprio, bloqueio de alteração de identidade/preço/máquina,
filtragem do catálogo e bloqueio de acesso anônimo. Não comprova comportamentos
futuros de reservas, pagamentos ou automação.

O arquivo migrations/.gitkeep foi removido após a validação: a pasta já contém
SQL versionado, e o placeholder gerava apenas um aviso de nome ignorado.
A CLI permanece fixada em 2.118.0; o aviso de atualização não é falha de validação.

## Segundo incremento — pedidos e reservas

Em 2026-10-04, o agente acessou diretamente o PostgreSQL local e executou a segunda
migration dentro de uma transação posteriormente revertida. As duas suítes pgTAP
passaram: 13 testes anteriores + 22 novos, total 35. Nenhuma alteração persistente
foi feita no schema nem no histórico de migrations dessa stack por esse teste.

Os dois cenários concorrentes passaram em banco temporário separado no mesmo
PostgreSQL local, com todas as migrations aplicadas. Esse banco usou auth.users mínimo
(somente id) e a definição real de auth.uid copiada da stack: comprova os locks e
invariantes de reserva, não todo o Supabase Auth. Banco temporário removido ao terminar.

Validação final confirmada pela captura do terminal enviada pelo usuário em 2026-10-04:

- migration up --local aplicou 20261004000200_orders_reservations.sql e confirmou banco atualizado.
- db:lint terminou com No schema errors found.
- db:test passou com Files=2, Tests=35, Result: PASS.
- db:test:concurrency passou nos dois cenários na stack completa: uma única reserva
  na disputa pela máquina e o mesmo pedido nos retries concorrentes.

A segunda migration está aplicada e validada localmente. Não repetir reset em produção.

## Terceiro incremento — base financeira e execução física

A migration 20261004000300_payments_cycles_commands.sql foi testada pelo agente
no PostgreSQL local, dentro de transação revertida. As três suítes passaram:
13 + 22 + 28 = 63 verificações. Não houve aplicação persistente nem alteração
do histórico de migrations por esse teste.

Os dois cenários de concorrência anteriores também passaram em banco temporário
com as três migrations, usando o bootstrap mínimo de Auth já descrito acima.
O banco temporário foi removido.

Validação final pelo agente: após concessão de acesso à pasta de estado da CLI,
migration up --local aplicou a terceira migration e db:lint retornou No schema errors
found. O wrapper db:test ainda foi bloqueado com EPERM ao iniciar docker.exe.
As mesmas três suítes pgTAP foram então executadas diretamente contra a stack local
com a migration já aplicada, em transação revertida: 63 testes aprovados. Os dois
cenários concorrentes também passaram nessa stack completa, com limpeza das fixtures.
Não há ação pendente do usuário para essa validação; a restrição restante afeta
o wrapper Docker dos testes, não a aplicação da migration ou o resultado das suítes.

## Quarto incremento — confirmação e autorização

O agente aplicou 20261004000400_verified_payment_authorization.sql com a CLI local
e executou db:lint, sem erros. As quatro suítes pgTAP passaram diretamente no
PostgreSQL da stack após a aplicação: 13 + 22 + 28 + 25 = 88 testes, com rollback
das fixtures. Os cinco cenários concorrentes passaram na stack completa; fixtures
removidas ao final. Não foram usadas APIs de pagamento nem dispositivos externos.

Também houve validação anterior à aplicação em transação revertida e banco temporário.
Esta etapa foi executada integralmente pelo agente, sem comandos manuais do usuário.

## Quinto incremento — execução simulada

Migration 20261004000500_simulated_cycle_execution.sql aplicada pelo agente usando
a CLI local. db:lint sem erros. Runner direto versionado passou nas cinco suítes,
com plano TAP validado: 120 verificações SQL. Sete cenários de concorrência passaram,
incluindo dois workers tentando entregar o mesmo comando e finalizações simultâneas.
Simulador executável validou fluxo normal até liberar a reserva e timeout de entrega
mantendo a reserva. Tudo executado contra a stack local; fixtures removidas/revertidas.

Os scripts db:test:direct e simulate:controller agora fazem parte do repositório,
permitindo reproduzir validações sem depender dos scripts temporários anteriores.

### Comandos locais

```sh
npm run db:reset
npm run db:lint
npm run db:test
npm run db:test:concurrency
npm run db:test:direct
npm run simulate:controller
```

Reset apaga somente os dados locais. A execução via CLI nesta sessão do agente encontrou
restrições de acesso ao Docker e ao estado da CLI; a validação final da stack foi
executada no terminal do usuário. Os testes preliminares via PostgreSQL direto foram
executados pelo agente conforme descrito acima.

## Histórico

A primeira tentativa falhou com disco cheio e erros de filesystem somente leitura.
Depois houve erro 500 do Docker. Liberação de espaço e recuperação do Docker
permitiram executar hello-world e iniciar a stack. A seção [inbucket] foi
atualizada para [local_smtp]. Esses bloqueios anteriores não representam o
resultado atual da validação.
