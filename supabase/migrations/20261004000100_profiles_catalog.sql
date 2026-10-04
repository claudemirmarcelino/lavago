begin;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete restrict,
  display_name text not null default '' check (char_length(display_name) <= 100),
  created_at timestamptz not null default now()
);

create table public.machines (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (char_length(btrim(code)) between 1 and 50),
  label text not null check (char_length(btrim(label)) between 1 and 100),
  operational_status text not null default 'DISABLED'
    check (operational_status in ('ACTIVE', 'MAINTENANCE', 'DISABLED')),
  last_seen_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.services (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 100),
  price_cents integer not null check (price_cents > 0),
  currency text not null default 'BRL' check (currency = 'BRL'),
  active boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.machine_services (
  machine_id uuid not null references public.machines(id) on delete restrict,
  service_id uuid not null references public.services(id) on delete restrict,
  primary key (machine_id, service_id)
);
create index machine_services_service_id_idx on public.machine_services(service_id);

alter table public.profiles enable row level security;
alter table public.machines enable row level security;
alter table public.services enable row level security;
alter table public.machine_services enable row level security;

-- Remove inclusive grants herdados dos defaults do Supabase.
revoke all on public.profiles, public.machines, public.services,
  public.machine_services from public, anon, authenticated;
grant select on public.profiles, public.machines, public.services,
  public.machine_services to authenticated;
grant update (display_name) on public.profiles to authenticated;
grant all on public.profiles, public.machines, public.services,
  public.machine_services to service_role;

create policy profiles_read_own on public.profiles for select to authenticated
  using (id = (select auth.uid()));
create policy profiles_update_own on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));
create policy machines_read_catalog on public.machines for select to authenticated
  using (operational_status <> 'DISABLED');
create policy services_read_catalog on public.services for select to authenticated
  using (active);
create policy machine_services_read_catalog on public.machine_services
  for select to authenticated using (
    exists (select 1 from public.machines m where m.id = machine_id)
    and exists (select 1 from public.services s where s.id = service_id)
  );

-- Sem leitura de user_metadata: o cliente não define privilégios nem campos internos.
create function public.create_profile_for_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id) values (new.id);
  return new;
end;
$$;
revoke all on function public.create_profile_for_user() from public, anon, authenticated;
create trigger on_auth_user_created_lavago after insert on auth.users
  for each row execute function public.create_profile_for_user();

-- Preserva usuários de teste que já existam ao aplicar a primeira migration.
insert into public.profiles (id) select id from auth.users on conflict (id) do nothing;

comment on table public.machines is 'Catálogo sem credenciais de dispositivos; ACTIVE não significa disponível para reserva.';
comment on table public.profiles is 'Identidade pública mínima; exclusão de conta exige política de retenção explícita.';

commit;
