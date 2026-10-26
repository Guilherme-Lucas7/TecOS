-- TecOS: cria a tabela de ordens de serviço e as regras de acesso.
-- Cole tudo no Supabase > SQL Editor > New query e clique em Run.

create table if not exists public.ordens (
  id            uuid primary key default gen_random_uuid(),
  numero        text not null unique,
  patrimonio    text,
  abertura      timestamptz not null,
  recebimento   timestamptz not null,
  setor         text not null,
  localizacao   text,
  equipamento   text not null,
  descricao     text not null,
  prioridade    text not null default 'media'
                check (prioridade in ('baixa','media','alta','urgente')),
  status        text not null default 'aberta'
                check (status in ('aberta','manutencao','pecas','concluida')),
  diagnostico   text,
  servico       text,
  pecas         text,
  conclusao     timestamptz,
  criado_por    uuid default auth.uid() references auth.users(id),
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

alter table public.ordens enable row level security;

-- Só quem fez login (usuários que você cadastrou) lê e altera as OS.
drop policy if exists "ler ordens" on public.ordens;
drop policy if exists "criar ordens" on public.ordens;
drop policy if exists "editar ordens" on public.ordens;
drop policy if exists "excluir ordens" on public.ordens;
create policy "ler ordens"     on public.ordens for select to authenticated using (true);
create policy "criar ordens"   on public.ordens for insert to authenticated with check (true);
create policy "editar ordens"  on public.ordens for update to authenticated using (true) with check (true);
create policy "excluir ordens" on public.ordens for delete to authenticated using (true);
