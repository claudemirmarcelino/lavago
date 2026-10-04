# Execução e controlador simulado

Migration: 20261004000500_simulated_cycle_execution.sql.
Não há transporte de rede, dispatcher permanente, cron, firmware ou interface elétrica.
As funções são exclusivas do backend service_role; o controlador nunca recebe essa chave.
O backend futuro deve autenticar o dispositivo, vincular identidade à máquina e
validar evidência antes de chamar record_controller_event. O token de entrega
correlaciona a execução, mas não substitui identidade do dispositivo, TLS ou assinatura.

## Operações

`claim_start_command(machine_id)` bloqueia a máquina e busca START pendente,
não vencido, com pedido autorizado e reserva aberta. Máquina deve estar ativa
e ter heartbeat recente. A operação registra DISPATCHED, incrementa attempts e
gera lease_token com lease_until de até 30 segundos, limitado pelo prazo do comando.
Sem comando elegível, retorna registro nulo. Dois workers simultâneos não recebem
duas entregas. DISPATCHED nunca é redistribuído nesta versão, mesmo após timeout.

`record_controller_event(machine_id, command_id, lease_token, event_id, event_type)`
aceita ACK, STARTED, HEARTBEAT e FINISHED. O ID do evento deve ser estável em retries;
reutilizar o mesmo ID com outro comando/tipo falha. Uma nova linha em controller_events
e a auditoria são persistidas junto da mudança. Nenhum evento contém payload bruto
ou secrets; a função não precisa gravar o token na auditoria.

- ACK confirma recebimento, mantendo PENDING_START.
- STARTED confirma início físico, muda ciclo para RUNNING e pedido para IN_PROGRESS.
  Pode chegar antes do ACK, pois início físico implica recebimento. Repetir início
  não reinicia relógio nem ciclo.
- HEARTBEAT renova a evidência do ciclo RUNNING. Não resolve sozinho um ciclo UNKNOWN.
- FINISHED exige início registrado, conclui ciclo/pedido e libera a reserva na mesma
  transação. Pode resolver UNKNOWN quando existe início registrado. Evento atrasado
  para ciclo já finalizado não afeta uma nova reserva da máquina.

O horário armazenado é o recebimento no servidor. Ordenação confiável por sequência
e timestamps do dispositivo ainda deve ser projetada antes do protocolo real.
Um FINISHED sem STARTED é rejeitado; o adaptador deve reenviar evidências na ordem
correta ou abrir reconciliação, não inferir início inexistente.

`mark_cycle_timeout(cycle_id)` é uma operação explícita do futuro monitor. Ela marca
UNKNOWN e pedido NEEDS_REVIEW ao vencer o prazo de início, a posse de entrega sem
ACK, a evidência do ciclo (2 minutos) ou o limite de execução (2 horas). Repetir
timeout é idempotente. Reserva nunca é liberada por timeout.

Esses prazos são valores iniciais de simulação, não parâmetros certificados de
lavadoras. Deverão ser ajustados por serviço/equipamento antes de uso físico. O
heartbeat de ciclo não atualiza machines.last_seen_at; a conectividade geral da
máquina continua dependente do futuro canal de heartbeat autenticado.

## Recuperação conservadora

START nunca é reenviado cegamente. Mesmo que o worker caia entre a aquisição e o
envio, não é possível distinguir ausência de envio de envio sem resposta; a
reserva fica para revisão. Deduplicação persistente no dispositivo e protocolo
de consulta serão necessários para permitir retries de transporte seguros.

Se o comando foi entregue, evidência tardia válida de início pode resolver UNKNOWN
quando ainda não havia início registrado e a reserva permanece aberta. Aceitar
evidência observada não é emitir nova autorização para executar comando vencido.
O controlador real deverá rejeitar novas execuções após expires_at.

Se o comando venceu sem entrega, fica EXPIRED, o ciclo UNKNOWN e a reserva retida
para revisão financeira/operacional. Não há liberação administrativa ou estorno
automáticos. O monitor não está agendado: sem chamadas explícitas não há transição
automática de timeout. Nenhuma destas funções implementa segurança elétrica.

## Executar a simulação

Com a stack local iniciada:

```sh
npm run simulate:controller
npm run db:test:direct
npm run db:test:concurrency
```

O simulador cria usuário, catálogo, pedidos e aprovação fictícios em uma transação,
simula ciclo normal e perda de confirmação e desfaz tudo ao terminar. Não há
cobrança externa nem alteração persistente de fixtures.

Os scripts obtêm a URL local da CLI sem imprimir credenciais. Se a CLI estiver
bloqueada, pode-se fornecer LAVAGO_TEST_DATABASE_URL apenas no ambiente do processo;
o destino deve ser loopback e porta 54322. Não usar túnel para banco remoto.
O runner direto valida as saídas TAP e seus planos, retornando erro se houver falha
ou contagem inconsistente; ele executa as mesmas suítes de supabase test db.
