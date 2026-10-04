# Confirmação verificada e autorização

Implementação: migration 20261004000400_verified_payment_authorization.sql.

## Fronteira de confiança

`record_verified_payment(order_id, provider, payment_id, event_id, amount_cents, currency)`
é uma função PostgreSQL exclusiva de service_role. Não existe Edge Function, rota
de webhook, gateway conectado ou endpoint de simulação exposto. Os testes chamam
a função com fixtures; o aplicativo não tem permissão para executá-la.

O nome verified é uma pré-condição, não uma verificação feita pelo SQL. Antes de
usar a função em integração real, o adaptador backend deverá autenticar o evento,
validar assinatura e conta recebedora, consultar a cobrança quando necessário,
confirmar status aprovado e resolver o vínculo com o pedido a partir de dados
confiáveis. Nunca repassar body do aplicativo ou webhook sem validação para esta RPC.
Credenciais ficam no backend; valor, moeda e IDs vêm da resposta verificada do provedor.

## Transação

1. Valida argumentos e serializa evento e cobrança por locks transacionais.
2. Bloqueia máquina e pedido, na mesma ordem usada por cancelamento/expiração.
3. Confere a identidade de cobranças/eventos existentes; divergência retorna conflito.
4. Registra a aprovação observada, evento processado e auditoria.
5. Confere valor/moeda, prazo, estado do pedido, reserva e máquina conectada/ativa.
6. Em caso válido, grava AUTHORIZED, ciclo PENDING_START e comando START PENDING
   com validade de dois minutos, junto da auditoria, na mesma transação.

Falha em qualquer etapa desfaz todos os registros dessa chamada. O adaptador futuro
deverá permitir retry/reconciliação quando a chamada falhar; não confirmar entrega
ao provedor antes de persistir o resultado. Inbox durável anterior à validação
e processamento de eventos não aprovados ainda serão implementados.

## Idempotência e revisão

- Mesmo evento, cobrança e dados: retorna estado atual do pedido, sem efeitos novos.
- Outro evento para a mesma cobrança já aprovada: registra o novo evento, sem novo ciclo ou START.
- Mesma identidade com pedido/valor/moeda diferentes: PAYMENT_IDENTITY_CONFLICT ou EVENT_IDENTITY_CONFLICT.
- Cobrança em FAILED/CANCELLED/REFUNDED: PAYMENT_REQUIRES_RECONCILIATION; não regride estado.
- Evento já armazenado em estado não suportado: EVENT_REQUIRES_RECONCILIATION.

Pagamentos com divergência são registrados como APPROVED, pois esse é o estado
financeiro observado, mas recebem reconciliation_reason e não autorizam máquina.
Razões: AMOUNT_MISMATCH, ORDER_NOT_PAYABLE, RESERVATION_INVALID,
MACHINE_UNAVAILABLE ou EXTRA_PAYMENT. APPROVED sozinho nunca significa autorizado.

WAITING_PAYMENT passa a NEEDS_REVIEW nesses casos. Pedidos já AUTHORIZED, CANCELLED
ou EXPIRED mantêm seu estado; o pagamento adicional continua marcado para revisão.
Uma reserva ainda aberta é preservada. Não há estorno automático nem resolução
automática de revisão nesta etapa. Outro evento não tenta autorizar novamente um
pagamento que já foi registrado como aprovado e enviado para revisão.

## Auditoria e execução física

Eventos de auditoria correlacionam webhook, confirmação, autorização, criação do
ciclo e comando. Retentativa idêntica não duplica auditoria. Não há dados brutos,
assinaturas ou secrets no registro.

O comando só fica persistido. Não existe dispatcher; expiração do comando ainda
não altera automaticamente pedido/ciclo. Reconciliação de timeout, confirmação de
recebimento, início físico e finalização serão implementados antes de qualquer
controlador real. Não confundir AUTHORIZED com RUNNING.

## Testes

25 testes adicionais cobrem autorização, deduplicação, identidade, pagamento extra,
divergente/tardio, pedido cancelado, manutenção, reserva liberada, grants e rollback
integral por falha injetada na criação de comando, seguido de retry bem-sucedido.

O teste de concorrência contém cinco cenários: disputa por reserva, retry de pedido,
eventos simultâneos da mesma cobrança, aprovação antes do cancelamento e cancelamento
antes da aprovação. Os testes observam locks reais em conexões independentes.
