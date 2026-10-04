# Edge Functions

Nenhuma função de negócio implementada nesta etapa.

Aqui ficarão os pontos de entrada do backend. Requisições do aplicativo devem
autenticar o usuário e verificar autorização; nunca confiar em preço, proprietário,
status de pagamento ou autorização de máquina enviados pelo cliente.

Webhooks futuros precisam de validação específica do gateway, proteção contra
replay e processamento idempotente. Não desabilitar autenticação globalmente para
acomodar um webhook. Credenciais privilegiadas permanecem exclusivamente no backend.
