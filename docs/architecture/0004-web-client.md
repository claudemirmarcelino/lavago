# ADR 0004 — Primeiro cliente web responsivo

Decisão aprovada pelo usuário: começar com interface web para exercitar o backend,
mantendo Flutter/Android em aberto. A aplicação fica em apps/web, separada das
ferramentas da raiz, usando Vite e JavaScript com Supabase JS de versões fixadas.

## Fluxo disponível

Login/cadastro via Supabase Auth; catálogo via RLS; seleção de máquina e serviço;
criação/cancelamento pela Edge Function orders; leitura dos próprios pedidos,
pagamentos e ciclos via RLS. Atualização a cada 15 segundos quando a página está
visível, além de atualização manual. Não utiliza Realtime nesta primeira versão.

Não existe cobrança real, botão para aprovar pagamento nem acionamento de máquina
no cliente. AUTHORIZED continua distinto de RUNNING. A interface não promete
disponibilidade por heartbeat: o servidor decide sobre a reserva em transação.

## Segurança

A configuração do frontend contém apenas URL e chave pública publishable/anon.
A aplicação rejeita chave secret e JWT com papel diferente de anon como configuração.
Credenciais privilegiadas são lidas somente no ambiente da Edge Function.

orders aceita exclusivamente POST com action create/cancel e campos UUID permitidos.
Valida a sessão no Auth /user, deriva o dono desse resultado e chama a RPC privilegiada.
Não aceita user_id, preço, moeda ou status no corpo. Erros SQL internos não são
retornados ao navegador. Chave idempotente é reutilizada ao tentar novamente a mesma
reserva após falha de rede. Outros endpoints financeiros permanecem inacessíveis.

verify_jwt=false se aplica somente à função orders: a autenticação efetiva é feita
explicitamente no handler antes de qualquer operação privilegiada, compatível com
as chaves e tokens atuais do Supabase. Não se trata de função pública de negócio.
Origens permitidas vêm de LAVAGO_ALLOWED_ORIGINS, com localhost/127.0.0.1:3000 por
padrão. CORS não substitui autenticação. Rate limiting e implantação remota ainda
precisam de configuração antes de expor esse endpoint na internet.

Referências oficiais:
- https://supabase.com/docs/guides/functions/auth-legacy-jwt
- https://supabase.com/docs/guides/getting-started/migrating-to-new-api-keys

## Dados e ambiente de teste

A demonstração visual sem login usa fixtures claramente identificadas e não grava
pedidos. O catálogo local de desenvolvimento usa quatro máquinas com prefixo DEMO-WEB
e dois serviços fictícios. O script dev-catalog mantém heartbeat apenas desses IDs,
somente em banco loopback na porta 54322, enquanto está aberto. Não cria clientes
ou senhas e não gera pagamentos. Dados ficam no banco local até reset; no encerramento
do script o heartbeat deixa de atualizar e máquinas ficam offline após dois minutos.

O iniciador web:local configura .env.local ignorado pelo Git, inicia catálogo,
função orders e Vite. Não redefine banco, não aplica migrations nem faz deploy.
