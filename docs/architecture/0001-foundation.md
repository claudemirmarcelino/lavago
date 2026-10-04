# ADR 0001 — Fundação do LavaGo

Status: fundação adotada; detalhes do domínio propostos para revisão antes do schema.

## Decisão

Usar um monorepositório com aplicativo, Supabase e documentação. PostgreSQL será
a fonte de verdade. Supabase Auth identifica usuários; RLS restringirá acesso
às tabelas expostas; Edge Functions executarão operações privilegiadas.
A escolha do framework mobile, gateway e transporte da automação permanece aberta.

## Fluxo e fronteiras de confiança

1. Cliente autenticado solicita pedido para uma máquina e serviço.
2. Backend valida disponibilidade e calcula valor a partir de dados confiáveis.
3. Backend cria cobrança no gateway com idempotência.
4. Webhook é autenticado conforme o gateway escolhido. Backend confere identificação
   da cobrança, conta recebedora, moeda, valor e vínculo com o pedido; consulta o
   provedor quando exigido pelo contrato ou para reconciliação.
5. Uma transação registra o pagamento confirmado e a intenção durável de autorizar
   a máquina. O aplicativo nunca confirma pagamento.
6. Um serviço entrega o comando autenticado ao controlador e acompanha confirmação.
7. Evidência do início físico e da finalização atualiza o ciclo, conforme sensores
   e protocolo a definir. Confirmação de recebimento não significa lavagem iniciada.

O controlador não acessa credenciais privilegiadas do Supabase nem decide aprovação
de pagamento. Realtime pode atualizar a tela, mas não é uma fila durável.

## Domínio a modelar no próximo incremento

- profiles referencia a identidade em auth.users; não duplica senhas.
- machines representa equipamento, disponibilidade operacional e conectividade.
- orders representa intenção de compra, reserva e expiração.
- payments representa tentativas de cobrança e confirmação do provedor.
- washing_cycles representa execução física vinculada a pedido e máquina.
- automation_commands representa intenção durável, entrega e resultado do comando.
- payment_webhook_events registra deduplicação e processamento de notificações.
- audit_logs registra transições críticas com ator e correlação, sem secrets.

Não usar uma única lista de estados para todos os objetos. WAITING_PAYMENT e
AUTHORIZED pertencem principalmente ao pedido; RUNNING e FINISHED ao ciclo;
MAINTENANCE à máquina. OFFLINE é conectividade e pode coexistir com um ciclo ativo.
Nomes finais, transições e restrições serão definidos no documento de modelagem.

## Concorrência e falhas

Proposta para o schema: exclusividade de reserva/ciclo ativo por máquina, garantida
no banco; preço capturado no pedido; identificadores externos únicos por provedor;
transações que persistam confirmação e comando pendente juntas (padrão outbox).

Notificações duplicadas ou fora de ordem não podem regredir pagamento nem produzir
nova autorização. Comandos têm ID único, prazo, máquina destinatária e confirmação.
Retries reutilizam o mesmo ID. O controlador precisará deduplicar de modo persistente
inclusive após reinício. Não prometer execução física exatamente uma vez apenas com
restrições SQL: quedas entre acionamento e confirmação exigem sensores/reconciliação.
Estado físico incerto impede reenvio cego de acionamento e libera intervenção segura.

Pagamento após expiração, indisponibilidade, falha de início e estorno exigirão
políticas explícitas antes da integração. Pagamento confirmado não basta para iniciar
uma máquina com reserva vencida ou ocupada.

## Segurança

RLS deverá nascer junto de cada tabela exposta. Cliente acessa apenas dados permitidos
e nunca escreve status críticos, preços ou comandos. Chaves públicas do Supabase são
configuração do cliente, não credenciais privilegiadas; dependem de Auth e RLS.
service_role e secrets ficam exclusivamente no backend e nos cofres de cada ambiente.

Automação exige TLS, identidade por dispositivo, autorização por máquina, expiração,
proteção contra replay e revogação/rotação. Transporte e provisionamento serão definidos
em ADR posterior. Interface elétrica e mecanismos de segurança física serão projetados
antes de conectar uma lavadora real.

Auditoria deve limitar dados pessoais e nunca registrar cartão, tokens ou assinaturas
secretas. Retenção e acesso aos eventos serão definidos na modelagem.
