# LavaGo Web

Interface responsiva inicial para o backend local. A escolha de tecnologia Android
continua aberta; esta aplicação não é um aplicativo Flutter.

## Iniciar

Na raiz do repositório, com Docker e Supabase em execução:

```powershell
npm.cmd run web:local
```

Abra http://127.0.0.1:3000 e mantenha o terminal aberto. O iniciador prepara a chave
pública local, quatro máquinas de teste, a Edge Function orders e a interface.
Caso as dependências web não estejam instaladas, rode npm ci dentro de apps/web antes.

Crie sua conta pela tela de cadastro. Confirme o e-mail no Mailpit em
http://127.0.0.1:54324 e faça login. Use senha de teste exclusiva com pelo menos
12 caracteres. Selecione máquina, serviço e confirme a reserva. Veja o pedido
em Meus pedidos e cancele enquanto aguarda pagamento.

Não é possível pagar por esta interface ainda. A tela mostra estados já existentes
no backend, mas não confirma pagamentos nem aciona equipamentos.

## Interface isolada

`npm run web:dev` na raiz inicia só a interface. Sem configuração ou sem login,
Explorar demonstração mostra dados fictícios sem gravações. Para configurar
manualmente, copie .env.example para .env.local e preencha somente a chave pública.
Nunca use service_role ou secret. A aplicação não lê o .env da raiz.

## Verificações

`npm run web:build` compila a interface. `npm run test:edge` testa o contrato e
autenticação do handler de pedidos com mocks; isso não substitui teste de integração
do runtime Edge com Auth, PostgreSQL e navegador.
