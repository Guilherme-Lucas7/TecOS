-- TecOS: alertas de OS atrasadas por notificação no celular (app ntfy).
-- Cole tudo no Supabase > SQL Editor > New query e clique em Run.
-- Pode rodar de novo sem problema: o comando não apaga OS nem configurações.

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

-- Campos do solicitante da OS.
alter table public.ordens add column if not exists solicitante text;
alter table public.ordens add column if not exists ramal text;

-- "Aberta" foi unificada com "Em manutenção": a OS entra direto em manutenção.
update public.ordens set status = 'manutencao' where status = 'aberta';
alter table public.ordens alter column status set default 'manutencao';

-- Compra de peças: o que falta, pedido, previsão e quanto tempo a OS esperou pela peça.
alter table public.ordens add column if not exists peca_necessaria text;
alter table public.ordens add column if not exists pedido_compra text;
alter table public.ordens add column if not exists previsao_peca date;
alter table public.ordens add column if not exists pecas_desde timestamptz;
alter table public.ordens add column if not exists espera_pecas_seg bigint not null default 0;
-- Data em que a OS foi enviada para compra (fica guardada mesmo depois que a peça chega).
alter table public.ordens add column if not exists pedido_peca_em timestamptz;
-- OS que já passaram por compra antes desta coluna existir: data aproximada.
update public.ordens
   set pedido_peca_em = coalesce(pecas_desde, recebimento + make_interval(secs => greatest(0, extract(epoch from (coalesce(conclusao, now()) - recebimento)) - espera_pecas_seg)), recebimento)
 where pedido_peca_em is null and (status = 'pecas' or espera_pecas_seg > 0);

-- Guarda quando cada OS recebeu o último alerta, para não repetir toda hora.
alter table public.ordens add column if not exists ultimo_alerta timestamptz;

-- Configuração dos alertas (uma linha só). O app edita estes valores.
create table if not exists public.alertas_config (
  id            int primary key default 1 check (id = 1),
  ativo         boolean not null default true,
  topico        text not null default 'tecos-' || substr(md5(random()::text || clock_timestamp()::text), 1, 16),
  horas_urgente int not null default 120  check (horas_urgente between 1 and 2000),
  horas_alta    int not null default 120 check (horas_alta    between 1 and 2000),
  horas_media   int not null default 120 check (horas_media   between 1 and 2000),
  horas_baixa   int not null default 120 check (horas_baixa   between 1 and 2000),
  repetir_horas int not null default 24  check (repetir_horas between 1 and 2000),
  hora_inicio   int not null default 7   check (hora_inicio between 0 and 23),
  hora_fim      int not null default 22  check (hora_fim between 1 and 24),
  site_url      text not null default 'https://guilherme-lucas7.github.io/TecOS/'
);
insert into public.alertas_config (id) values (1) on conflict (id) do nothing;

alter table public.alertas_config enable row level security;
drop policy if exists "ler alertas" on public.alertas_config;
drop policy if exists "editar alertas" on public.alertas_config;
create policy "ler alertas"    on public.alertas_config for select to authenticated using (true);
create policy "editar alertas" on public.alertas_config for update to authenticated using (true) with check (true);

-- Duração legível: "3d 4h"
create or replace function public.tecos_fmt(d interval) returns text
language sql immutable as $$
  select case when extract(epoch from d) >= 86400
              then floor(extract(epoch from d) / 86400)::int || 'd ' else '' end
      || floor(mod(extract(epoch from d)::numeric, 86400) / 3600)::int || 'h'
$$;

-- Envia uma notificação para o tópico do ntfy.
create or replace function public.tecos_enviar(c public.alertas_config, titulo text, msg text, prio int, tags text[])
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform net.http_post(
    url     := 'https://ntfy.sh',
    body    := jsonb_build_object('topic', c.topico, 'title', titulo, 'message', msg,
                                  'priority', prio, 'tags', to_jsonb(tags), 'click', c.site_url),
    headers := '{"Content-Type": "application/json"}'::jsonb
  );
end $$;

-- Confere as OS em aberto e avisa as que passaram do prazo da prioridade.
create or replace function public.tecos_alertas() returns int
language plpgsql security definer set search_path = public, extensions as $$
declare
  c public.alertas_config;
  o record;
  n int := 0;
  h int;
begin
  select * into c from public.alertas_config where id = 1;
  if not found or not c.ativo then return 0; end if;

  h := extract(hour from (now() at time zone 'America/Sao_Paulo'))::int;
  if h < c.hora_inicio or h >= c.hora_fim then return 0; end if;

  for o in
    select x.*,
           now() - coalesce(x.recebimento, x.abertura) - make_interval(secs => coalesce(x.espera_pecas_seg, 0)) as idade,  -- tempo de compra não conta
           case x.prioridade when 'urgente' then c.horas_urgente
                             when 'alta'    then c.horas_alta
                             when 'baixa'   then c.horas_baixa
                             else c.horas_media end as limite
      from public.ordens x
     where x.status not in ('concluida', 'pecas')  -- aguardando peça não conta como atraso do técnico
     order by coalesce(x.recebimento, x.abertura)
  loop
    if o.idade > make_interval(hours => o.limite)
       and (o.ultimo_alerta is null or now() - o.ultimo_alerta > make_interval(hours => c.repetir_horas)) then
      perform public.tecos_enviar(
        c,
        'OS ' || o.numero || ' atrasada',
        o.equipamento || ' · ' || o.setor
          || coalesce(' · ' || nullif(o.localizacao, ''), '')
          || coalesce(' · Ramal ' || nullif(o.ramal, ''), '') || E'\n'
          || 'Em atendimento há ' || public.tecos_fmt(o.idade)
          || ' (prazo ' || case o.prioridade when 'urgente' then 'urgente' when 'alta' then 'alta'
                                             when 'baixa' then 'baixa' else 'média' end
          || ': ' || public.tecos_fmt(make_interval(hours => o.limite)) || ')' || E'\n'
          || 'Status: ' || case o.status when 'aberta' then 'Aberta' when 'manutencao' then 'Em manutenção'
                                         when 'pecas' then 'Aguardando peças' else o.status end,
        case o.prioridade when 'urgente' then 5 when 'alta' then 4 else 3 end,
        array['warning']
      );
      update public.ordens set ultimo_alerta = now() where id = o.id;
      n := n + 1;
      exit when n >= 20;
    end if;
  end loop;
  return n;
end $$;

-- Botão "Enviar teste" do app.
create or replace function public.tecos_alerta_teste() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare c public.alertas_config;
begin
  if auth.uid() is null then raise exception 'login necessário'; end if;
  select * into c from public.alertas_config where id = 1;
  perform public.tecos_enviar(c, 'TecOS: teste de alerta',
    'Se você recebeu esta mensagem, os alertas de OS atrasadas estão funcionando.', 3, array['white_check_mark']);
end $$;

revoke all on function public.tecos_enviar(public.alertas_config, text, text, int, text[]) from public, anon, authenticated;
revoke all on function public.tecos_alertas() from public, anon, authenticated;
revoke all on function public.tecos_alerta_teste() from public, anon;
grant execute on function public.tecos_alerta_teste() to authenticated;

-- Confere uma vez por hora (só envia aviso quando a OS passa do prazo).
select cron.unschedule(jobid) from cron.job where jobname = 'tecos-alertas';
select cron.schedule('tecos-alertas', '0 * * * *', 'select public.tecos_alertas()');
