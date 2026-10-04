# Ambientes e migrations

## Ambientes

- development: stack local, dados fictícios e configuração versionada.
- staging: projeto Supabase independente para homologação e sandbox do gateway.
- production: projeto separado, dados reais e acesso restrito.

Não compartilhar credenciais ou usar produção no desenvolvimento. Recursos remotos
ainda não foram provisionados. Configuração local não comprova configuração remota.
Mudanças futuras de Auth, secrets e infraestrutura remota terão procedimento versionado
próprio; migrations SQL não reproduzem toda a infraestrutura.

## Processo

1. Documentar entidades, invariantes e políticas antes do primeiro schema.
2. Criar migration com `npm run supabase -- migration new nome_descritivo`.
3. Escrever SQL em supabase/migrations, incluindo grants, constraints, índices e RLS
   aplicáveis. Não colocar DDL de negócio em seed.sql.
4. Executar `npm run db:reset` e `npm run db:lint` na stack local.
5. Validar permissões anônimas, usuário A contra B, operações privilegiadas,
   concorrência e idempotência. Incluir testes SQL quando o schema existir.
6. Revisar o diff e abrir PR. Não editar migrations já aplicadas em ambiente compartilhado;
   corrigir com nova migration.

Alterações manuais no dashboard não substituem migrations. Experimentos locais só
entram no projeto depois de convertidos em SQL revisado e reproduzidos do zero.
Seeds conterão apenas dados fictícios e deverão suportar o fluxo local documentado.

## Promoção futura

Aplicar o mesmo histórico aprovado em staging e depois production, com credenciais
distintas e controle de aprovação. CI será introduzido posteriormente com reconstrução
do banco, lint e testes de RLS/invariantes; não criar deploy automático nesta etapa.

Mudanças destrutivas exigem plano de backup/recuperação e avaliação dos dados existentes.
Preferir expandir → migrar dados → remover em etapas. Não executar reset remoto como rollback.
