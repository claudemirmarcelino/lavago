# ADR 0002 — Modelo inicial de domínio

Status: primeiro incremento implementado; reset, lint e 13 testes locais aprovados em 2026-10-04.
O restante permanece como proposta para os próximos incrementos.

Terceiro incremento: tabelas financeiras e de execução protegidas, sem operações
de aprovação ou despacho. Decisões e limites estão no
[ADR 0003](0003-payments-automation-foundation.md).

Segundo incremento implementado em 20261004000200_orders_reservations.sql:
orders, machine_reservations e operações backend de criação, cancelamento e expiração.
O segundo incremento aceita WAITING_PAYMENT, CANCELLED e EXPIRED; a quarta migration
acrescenta AUTHORIZED e NEEDS_REVIEW com suas operações controladas. Demais estados
de execução serão adicionados com suas invariantes em migrations futuras.
Locks seguem a ordem máquina → pedido nas liberações;
criação serializa também a chave idempotente antes da máquina.
Expiração exige chamada explícita, sem cron instalado. Ver [contratos](../api/orders.md).

## Implementação do primeiro incremento

A migration 20261004000100_profiles_catalog.sql cria profiles, machines, services
e machine_services. O perfil nasce com nome vazio via trigger em auth.users;
usuários preexistentes recebem perfil por backfill. Somente o nome é editável pelo
próprio usuário. O catálogo é legível por usuários autenticados, ocultando máquinas
DISABLED, serviços inativos e suas associações. Máquinas em manutenção continuam
visíveis; ACTIVE não autoriza reserva nem acionamento. Novos equipamentos e serviços
nascem desabilitados/inativos. Backend privilegiado administra catálogo.

Não há seed de catálogo ainda: testes criam fixtures dentro de transação e desfazem
ao terminar. Não há endpoint de escrita de pedidos nem comando de automação.

## Escopo e decisões

O primeiro schema será dividido em incrementos. Começaremos por profiles, machines
e catálogo de serviços; depois pedidos/reservas; por último pagamentos, ciclos,
comandos e auditoria. Cada migration inclui permissões e testes do que introduz.
O documento descreve o destino do modelo, não funcionalidades já implementadas.

Usar UUIDs internos, timestamptz em UTC e valores monetários inteiros em centavos.
Moeda inicial BRL, explícita nos preços e pedidos. Nunca usar float para dinheiro.
Registros transacionais não terão exclusão em cascata a partir do usuário ou máquina.
Política de anonimização e retenção deve ser definida antes de produção.

## Entidades e relações

| Entidade | Conteúdo principal | Relações e restrições previstas |
| --- | --- | --- |
| profiles | id, display_name, created_at | id referencia auth.users; sem senhas e sem papel administrativo editável pelo usuário |
| machines | id, code, label, operational_status, last_seen_at, created_at | code único; não expor secrets de dispositivo nesta tabela |
| services | id, name, price_cents, currency, active | preço positivo; alterações não modificam pedidos já criados |
| machine_services | machine_id, service_id | chave composta; define compatibilidade entre equipamento e serviço |
| orders | id, user_id, machine_id, service_id, price_cents, currency, status, expires_at, idempotency_key, created_at | cópia do preço; idempotência única por usuário; vínculo com perfil, máquina e serviço |
| machine_reservations | id, machine_id, order_id, acquired_at, released_at | no máximo uma reserva não liberada por máquina; order_id único |
| payments | id, order_id, provider, provider_payment_id, amount_cents, currency, status, confirmed_at | várias tentativas por pedido; ID externo único por provedor |
| washing_cycles | id, order_id, machine_id, status, started_at, finished_at | um ciclo por pedido nesta versão; máquina consistente com o pedido |
| automation_commands | id, cycle_id, machine_id, command_type, status, expires_at, attempts, acknowledged_at | uma intenção START por ciclo; retries reutilizam o mesmo ID |
| payment_webhook_events | id, provider, provider_event_id, received_at, processed_at, processing_status | ID de evento único por provedor; acesso exclusivo do backend |
| audit_logs | id, actor_type, actor_id, event_type, entity_id, correlation_id, created_at | eventos mínimos estruturados; sem tokens, cartão ou payload bruto indiscriminado |

machine_reservations foi separada de orders para manter a ocupação bloqueada durante
incerteza física, mesmo que o estado comercial do pedido mude. Uma reserva vencida
não fica disponível apenas pela passagem do tempo: uma transação precisa liberá-la.
Não usar now() em predicado de índice para tentar automatizar expiração.

Começaremos sem multitenancy comercial. A operação de múltiplas empresas/franquias
exigirá ADR de isolamento antes de introduzir clientes de empresas diferentes.
Não inventar permissões de administrador usando dados editáveis do perfil.

## Estados independentes

| Objeto | Estados propostos |
| --- | --- |
| Máquina (operação) | ACTIVE, MAINTENANCE, DISABLED |
| Pedido | WAITING_PAYMENT, AUTHORIZED, IN_PROGRESS, COMPLETED, EXPIRED, CANCELLED, NEEDS_REVIEW |
| Pagamento | PENDING, APPROVED, FAILED, CANCELLED, REFUNDED |
| Ciclo | PENDING_START, RUNNING, FINISHED, FAILED, UNKNOWN |
| Comando | PENDING, DISPATCHED, ACKNOWLEDGED, FAILED, EXPIRED, UNKNOWN |
| Evento webhook | RECEIVED, PROCESSED, FAILED, IGNORED |

Conectividade será calculada pelo heartbeat (last_seen_at) e um limite configurável.
OFFLINE não encerra ciclo nem libera reserva. AVAILABLE será uma disponibilidade
derivada da operação, conectividade e ausência de reserva, não um status que o
cliente pode escrever. FINISHED pertence ao ciclo.

Transições comerciais e físicas serão implementadas por operações controladas,
não por UPDATE arbitrário do cliente. Uma transição inválida falha sem mudança parcial.
APPROVED não volta a PENDING por chegada de evento antigo. REFUNDED exige confirmação
do provedor; cancelamento de pedido não implica estorno já realizado.

## Reserva e criação de pedido

Em transação: autenticar usuário, bloquear a linha da máquina, conferir operação,
conectividade e compatibilidade de serviço, verificar/liberar apenas reservas que
possam expirar com segurança, capturar preço vigente e criar pedido e reserva.
Um índice único parcial em machine_id WHERE released_at IS NULL protege contra
reservas concorrentes. Encerrar por vencimento exige verificar o estado do pagamento.

O backend recebe uma chave de idempotência por tentativa lógica. Repetir com os
mesmos parâmetros retorna o mesmo pedido; reutilizar a chave com outro conteúdo
gera conflito. Não permitir que o cliente escolha preço, dono ou status.

## Confirmação e autorização

Só o backend processa pagamento após validação específica do gateway. Registrar
evento duravelmente; erro permite reprocessamento, sem marcar evento como concluído
antes da transação de negócio. Duplicação de evento não perde a possibilidade de retry.

Bloquear pedido/reserva, validar valor e moeda e registrar pagamento. Se a reserva
continua válida e a máquina apta, criar ciclo PENDING_START e comando START na mesma
transação da autorização. A unicidade do ciclo por pedido e do comando START por ciclo
impede gerar duas lavagens com eventos diferentes da mesma cobrança.

Pagamento tardio, divergente ou uma segunda cobrança aprovada são registrados como
ocorrências financeiras e enviados a revisão; nunca reutilizam máquina já reservada
por outro pedido nem iniciam outro ciclo. Estornos e chargebacks terão modelagem
adicional quando o gateway for escolhido; não tratar este desenho como integração pronta.

## Entrega e resultado físico

Um worker buscará comandos pendentes com posse temporária (lease), tentativas e
retentativas limitadas. Campos de lease serão detalhados na migration de automação.
Entrega pode se repetir; execução precisa de deduplicação persistente no controlador.
O comando terá identidade, destinatário, expiração e autenticação verificável.

ACKNOWLEDGED só confirma recebimento. Evidência física estabelece RUNNING; ausência
de evidência após timeout gera UNKNOWN e mantém a reserva. Finalização confirmada
encerra ciclo/pedido e libera reserva em transação. Falha e revisão exigem reconciliação
antes de liberar equipamento. Banco sozinho não garante acionamento exatamente uma vez.

## Acesso e RLS

| Papel | Acesso previsto |
| --- | --- |
| anon | nenhum acesso a tabelas de negócio no primeiro incremento |
| authenticated | ler próprio perfil, próprios pedidos/pagamentos/ciclos; ler catálogo e dados públicos de máquinas |
| authenticated — escrita | somente nome do próprio perfil, com grant de coluna; operações de pedido via backend |
| backend privilegiado | executar operações de negócio verificando usuário, invariantes e auditoria |
| controlador | nenhuma conexão direta ao banco; somente protocolo de automação autenticado |

Toda tabela exposta nasce com RLS e grants explícitos. Tabelas internas (comandos,
reservas, webhooks e auditoria) não terão grants a anon/authenticated; acesso via
backend. service_role ignora RLS: validação no backend continua obrigatória.
Metadados sensíveis de máquina/dispositivo não devem entrar no catálogo público.

## Critérios de aceitação por incremento

1. Perfis/catálogo: usuário A não lê nem altera B; anon não acessa dados; cliente
   não altera catálogo ou identificador do perfil; criação de perfil autenticado
   funciona com os mecanismos definidos na migration; reset reconstrói tudo.
2. Pedidos: duas reservas simultâneas na mesma máquina produzem um único vencedor;
   retry idempotente retorna o pedido original; preço adulterado não é aceito;
   expiração não libera máquina com ciclo incerto.
3. Pagamentos/comandos: evento duplicado ou fora de ordem não gera novo START;
   pagamento tardio vai a revisão; rollback não deixa aprovação sem intenção durável;
   timeout/reinício do controlador não provoca reenvio cego de acionamento.

Os testes SQL usarão identidades distintas, roles reais e transações isoladas.
Testes de concorrência usarão conexões independentes; testes físicos ficarão para
o simulador/controlador futuro. Nenhuma integração real será adicionada nesta etapa.
