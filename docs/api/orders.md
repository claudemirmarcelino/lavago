# Pedidos e reservas — contratos internos

Implementado em 20261004000200_orders_reservations.sql. São funções PostgreSQL
exclusivas de service_role; ainda não há Edge Function nem endpoint do aplicativo.
O backend futuro deverá validar o JWT e obter user_id da identidade autenticada,
nunca aceitar user_id arbitrário do corpo da solicitação. Nunca fornecer a chave
service_role ao cliente para chamar estas funções.

## create_order(user_id, machine_id, service_id, idempotency_key)

Argumentos UUID; retorna a linha do pedido. O consumidor gera uma chave por intenção
de compra e reutiliza em retries. O escopo é usuário + chave. Payload diferente com
a mesma chave retorna IDEMPOTENCY_CONFLICT. Uma chave usada por pedido cancelado ou
expirado retorna o pedido terminal; nova intenção requer nova chave.

Não aceita preço, moeda, estado ou prazo como argumentos. Captura preço e moeda do
catálogo e expira em 10 minutos. Máquina deve estar ACTIVE e ter heartbeat nos últimos
2 minutos; heartbeat futuro é rejeitado. Limites iniciais fixos serão revistos com o
protocolo de automação. Sem controlador real, somente fixtures de teste atualizam
last_seen_at; nenhum heartbeat é falsificado em produção.

Serviço deve estar ativo e associado à máquina. Um lock na máquina e um índice único
parcial impedem duas reservas abertas. A chave idempotente também recebe lock transacional.
O pedido e sua reserva são persistidos juntos ou ambos desfeitos.

## cancel_order(user_id, order_id)

Somente pedido do usuário informado. WAITING_PAYMENT vira CANCELLED ou EXPIRED se
o prazo já venceu; a reserva é liberada na mesma transação. Chamadas repetidas retornam
o estado terminal. Pedido inexistente e pedido de outro usuário retornam ORDER_NOT_FOUND.

## expire_order(order_id)

Operação interna de worker. Libera apenas WAITING_PAYMENT com prazo vencido.
Não há worker/cron ainda: o prazo por si só não libera a reserva. Nova criação em
máquina ainda reservada falha até cancelamento/expiração explícita. Isso evita um
efeito parcial de expiração seguido de erro na mesma transação de criação.

Esta versão não cria cobranças externas. Antes de conectar gateway, estender estados e
adicionar reconciliação e tratamento de pagamento tardio às operações de liberação.
Não autorizar ciclo com base apenas no status do pedido desta versão.

A terceira migration adiciona o modelo de cobranças e ciclos sem endpoints de escrita.
Se um registro financeiro ou ciclo existir, cancelamento/expiração que mudaria o
status falha com ORDER_REQUIRES_RECONCILIATION, preservando a reserva. Pedidos sem
esses registros mantêm o comportamento anterior. Não remover essa guarda ao integrar gateway.

## Erros de domínio

SQLSTATE 22023: INVALID_REQUEST, PROFILE_NOT_FOUND, MACHINE_NOT_FOUND,
ORDER_NOT_FOUND, IDEMPOTENCY_CONFLICT.

SQLSTATE P0001: MACHINE_UNAVAILABLE, MACHINE_OFFLINE, SERVICE_UNAVAILABLE,
SERVICE_INCOMPATIBLE, MACHINE_RESERVED.

O backend mapeará esses erros para respostas de API. Não retornar detalhes internos
de SQL ao cliente. Não repetir conflito de disponibilidade indefinidamente.

## Acesso

authenticated tem somente SELECT nos próprios pedidos. anon não tem acesso.
Reservas são internas. service_role tem SELECT e EXECUTE nestas funções, sem DML
direto em pedidos/reservas. postgres continua sendo o papel administrativo.

## Validação

`npm run db:test`: suíte anterior e 22 testes adicionais de pedidos/reservas.
`npm run db:test:concurrency`: três conexões PostgreSQL, duas transações concorrentes,
espera de lock confirmada em pg_stat_activity; valida disputa por máquina e retry da
mesma chave. Fixtures têm UUIDs aleatórios e limpeza restrita a esses IDs.
O teste usa a URL retornada pela CLI local, sem imprimir credenciais. Aceita também
LAVAGO_TEST_DATABASE_URL em ambiente, restrita a loopback e porta 54322.
Nunca apontar testes para um túnel de produção.
