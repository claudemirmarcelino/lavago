# ADR 0003 — Base financeira e execução física

Status: modelo implementado em 20261004000300_payments_cycles_commands.sql;
operações financeiras, processamento de webhook e despacho ainda não implementados.

Evolução posterior: a quarta migration acrescentou confirmação verificada e
autorização transacional, documentadas em [contrato de pagamentos](../api/verified-payments.md).
As limitações abaixo descrevem a terceira migration; dispatcher e integração
de gateway continuam ausentes.

## Decisão e limites

Criar payments, washing_cycles, automation_commands, payment_webhook_events e
audit_logs com RLS e restrições estruturais. service_role tem somente leitura nessas
tabelas. Não há RPC de aprovação, callback público, worker, conexão a gateway ou ESP32.
Somente o papel administrativo postgres pode inserir fixtures nesta etapa.

Isso permite validar o modelo antes de introduzir efeitos financeiros ou físicos.
Não ampliar os grants para implementar endpoints rapidamente: o próximo incremento
precisará de funções transacionais revisadas, com idempotência e auditoria.

## Pagamentos

Uma cobrança externa é única por provider + provider_payment_id; várias tentativas
podem pertencer ao mesmo pedido. O ID externo é obrigatório; intenção anterior à
resposta do gateway e sua idempotência serão modeladas quando o provedor for escolhido.

amount_cents e currency representam o valor observado no provedor. Não há constraint
que os iguale ao pedido: divergências devem poder ser registradas para reconciliação,
sem autorizar máquina. O futuro fluxo de autorização deverá conferir preço, moeda,
conta recebedora, assinatura, cobrança, pedido e validade da reserva.

APPROVED/REFUNDED exigem confirmed_at. Isso é consistência estrutural, não comprovação
de aprovação externa. O cliente não pode gravar esses campos. Reembolsos parciais,
chargebacks e conta do gateway ainda precisarão de modelagem própria.

## Ciclos e comandos

Um ciclo por pedido; chave estrangeira composta mantém a máquina coerente com o
pedido. Um índice impede mais de um ciclo PENDING_START/RUNNING/UNKNOWN por máquina.
UNKNOWN representa incerteza física e mantém exclusividade.

Cada ciclo tem no máximo um comando START e o destinatário corresponde à máquina do
ciclo. Retries futuros reutilizarão o ID do comando. O registro contém prazo,
tentativas e par de campos lease_token/lease_until para uma futura posse temporária
pelo worker. Ainda não há aquisição, renovação ou recuperação de leases.

ACKNOWLEDGED registra recebimento; não muda o ciclo para RUNNING. Início e fim exigirão
evidência física e protocolo autenticado. Unicidade SQL não garante execução física
exatamente uma vez. Validação de transições, reservas e reconciliação será feita
pelas operações futuras, não apenas pelos CHECKs deste modelo.

## Webhooks e auditoria

Eventos são únicos por provedor e ID normalizado. Falha permanece reprocessável;
processed_at só acompanha PROCESSED/IGNORED. Sem payload bruto ou assinaturas
persistidos. A estratégia de normalização e recuperação do evento será definida
com o gateway; esta tabela ainda não representa uma inbox operacional completa.

Auditoria contém ator, tipo de evento, entidade e correlação; não contém campos
livres para cartão ou secrets. Não há escrita automática de auditoria neste
incremento. As futuras operações críticas deverão inserir o evento na mesma
transação da mudança; não serão consideradas completas sem isso.

## Proteção de reservas existente

O trigger guard_order_release recusa transições para CANCELLED/EXPIRED quando o
pedido tem qualquer pagamento ou ciclo. Retorna ORDER_REQUIRES_RECONCILIATION sem
liberar a reserva. A regra é conservadora inclusive para cobranças FAILED ou ciclos
FINISHED; a liberação reconciliada será acrescentada com as operações de pagamento.

Pedidos sem esses registros continuam cancelando e expirando normalmente. Não
alteramos migrations já aplicadas nem ampliamos estados do pedido prematuramente.
Qualquer futura operação de inserção financeira deve seguir a ordem de locks
máquina → pedido e validar o estado sob lock, evitando corrida com cancelamento.

## Verificação

28 novos testes pgTAP: unicidade, vínculos de máquina, timestamps, isolamento de
leitura, bloqueio de escrita do cliente e backend, liberação bloqueada e distinção
entre ACK e início físico. As 35 verificações anteriores permanecem no conjunto.
Os testes usam fixtures e rollback; não fazem chamadas a provedores externos.
