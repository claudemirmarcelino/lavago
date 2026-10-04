# Aplicativo mobile

Destino inicial: Android. Flutter é candidato, ainda sem decisão definitiva.
Não há aplicativo executável nesta fundação. O package.json da raiz serve somente
às ferramentas do Supabase e não define a tecnologia do aplicativo.

O cliente poderá usar URL e chave pública do Supabase com Auth e RLS.
Chaves secretas, service_role, credenciais de gateway e de dispositivos são proibidas
no aplicativo. Nunca persistir aprovação de pagamento ou emitir comando de máquina
diretamente a partir do cliente.
