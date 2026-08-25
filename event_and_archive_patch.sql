-- HOFOPOLY PATCH
-- Ereigniskarten + sichere Archiv-/Rundensteuerung
-- Einmalig im Supabase SQL Editor ausführen.

begin;

create table if not exists public.event_card_uses (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.games(id) on delete cascade,
  group_id uuid not null references public.game_groups(id) on delete cascade,
  card_number integer not null check (card_number between 1 and 10),
  title text not null,
  card_text text not null,
  money_delta integer not null default 0,
  silver_delta integer not null default 0,
  gold_delta integer not null default 0,
  created_at timestamptz not null default now(),
  unique(game_id, card_number)
);

alter table public.event_card_uses enable row level security;

drop policy if exists "public read event card uses" on public.event_card_uses;
create policy "public read event card uses"
on public.event_card_uses
for select to anon, authenticated
using (true);

create or replace function public.apply_event_card(
  p_game_id uuid,
  p_group_number integer,
  p_card_number integer,
  p_money_delta integer,
  p_silver_delta integer,
  p_gold_delta integer,
  p_title text,
  p_text text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group_id uuid;
  v_status public.game_status;
  v_used boolean;
begin
  select status into v_status
  from public.games
  where id = p_game_id;

  if v_status is null then
    raise exception 'Spiel nicht gefunden';
  end if;

  if v_status not in ('round1','round2','paused') then
    raise exception 'Ereigniskarten sind nur während eines laufenden Spiels verfügbar';
  end if;

  if p_card_number not between 1 and 10 then
    raise exception 'Ungültige Ereigniskarte';
  end if;

  select id into v_group_id
  from public.game_groups
  where game_id = p_game_id
    and group_number = p_group_number
  for update;

  if v_group_id is null then
    raise exception 'Gruppe nicht gefunden';
  end if;

  select exists(
    select 1 from public.event_card_uses
    where game_id = p_game_id
      and card_number = p_card_number
  ) into v_used;

  if v_used then
    raise exception 'Diese Ereigniskarte wurde in diesem Spiel bereits verwendet';
  end if;

  update public.game_groups
  set money = greatest(0, money + p_money_delta),
      silver = greatest(0, silver + p_silver_delta),
      gold = greatest(0, gold + p_gold_delta)
  where id = v_group_id;

  insert into public.event_card_uses(
    game_id, group_id, card_number, title, card_text,
    money_delta, silver_delta, gold_delta
  ) values (
    p_game_id, v_group_id, p_card_number, p_title, p_text,
    p_money_delta, p_silver_delta, p_gold_delta
  );

  insert into public.transactions(
    game_id, group_id, type, amount,
    silver_delta, gold_delta, details
  ) values (
    p_game_id, v_group_id, 'event_card', p_money_delta,
    p_silver_delta, p_gold_delta,
    format('Ereigniskarte %s: %s', p_card_number, p_title)
  );

  return jsonb_build_object(
    'success', true,
    'card_number', p_card_number,
    'group_number', p_group_number,
    'money_delta', p_money_delta,
    'silver_delta', p_silver_delta,
    'gold_delta', p_gold_delta
  );
end;
$$;

-- Die Funktion darf die Datenbank schreiben; der Browser braucht keinen
-- direkten INSERT/UPDATE-Zugriff auf die Tabellen.

-- Realtime für Ereigniskarten

do $$
begin
  alter publication supabase_realtime add table public.event_card_uses;
exception
  when duplicate_object then null;
end $$;

commit;
