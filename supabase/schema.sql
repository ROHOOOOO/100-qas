create extension if not exists pgcrypto;

create table if not exists public.qa_rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  title text not null default '100 Q&As',
  created_at timestamptz not null default now()
);

create table if not exists public.qa_players (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.qa_rooms(id) on delete cascade,
  nickname text not null,
  player_key text not null,
  created_at timestamptz not null default now(),
  submitted_at timestamptz,
  unique (room_id, player_key)
);

create table if not exists public.qa_answers (
  room_id uuid not null references public.qa_rooms(id) on delete cascade,
  player_id uuid not null references public.qa_players(id) on delete cascade,
  question_index integer not null check (question_index between 1 and 100),
  content text not null default '',
  updated_at timestamptz not null default now(),
  primary key (player_id, question_index)
);

alter table public.qa_rooms enable row level security;
alter table public.qa_players enable row level security;
alter table public.qa_answers enable row level security;

revoke all on public.qa_rooms from anon, authenticated;
revoke all on public.qa_players from anon, authenticated;
revoke all on public.qa_answers from anon, authenticated;
grant usage on schema public to anon;

create or replace function public.qa_room_bundle(
  p_room_code text,
  p_player_id uuid default null,
  p_player_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.qa_rooms%rowtype;
  v_current public.qa_players%rowtype;
  v_has_current boolean := false;
  v_can_view_results boolean := false;
begin
  select *
    into v_room
    from public.qa_rooms
   where code = upper(trim(p_room_code));

  if not found then
    return null;
  end if;

  if p_player_id is not null and p_player_key is not null then
    select *
      into v_current
      from public.qa_players
     where id = p_player_id
       and room_id = v_room.id
       and player_key = p_player_key;

    v_has_current := found;
    v_can_view_results := v_has_current and v_current.submitted_at is not null;
  end if;

  return jsonb_build_object(
    'room', jsonb_build_object(
      'id', v_room.id,
      'code', v_room.code,
      'title', v_room.title,
      'createdAt', v_room.created_at
    ),
    'currentPlayerId', case when v_has_current then v_current.id else null end,
    'players', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', player_rows.id,
          'nickname', player_rows.nickname,
          'createdAt', player_rows.created_at,
          'submittedAt', player_rows.submitted_at,
          'answerCount', player_rows.answer_count,
          'answers', player_rows.answers
        )
        order by player_rows.created_at
      )
      from (
        select
          p.id,
          p.nickname,
          p.created_at,
          p.submitted_at,
          (
            select count(*)
              from public.qa_answers a
             where a.player_id = p.id
               and btrim(a.content) <> ''
          ) as answer_count,
          case
            when v_has_current and (
              p.id = v_current.id
              or (v_can_view_results and p.submitted_at is not null)
            )
            then coalesce((
              select jsonb_object_agg(answer_rows.question_index::text, answer_rows.content)
              from (
                select question_index, content
                  from public.qa_answers
                 where player_id = p.id
                 order by question_index
              ) answer_rows
            ), '{}'::jsonb)
            else '{}'::jsonb
          end as answers
        from public.qa_players p
        where p.room_id = v_room.id
      ) player_rows
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.qa_create_room()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.qa_rooms%rowtype;
  v_attempts integer := 0;
begin
  loop
    v_attempts := v_attempts + 1;

    begin
      insert into public.qa_rooms (code)
      values (substring(upper(replace(gen_random_uuid()::text, '-', '')) from 1 for 6))
      returning *
      into v_room;

      exit;
    exception
      when unique_violation then
        if v_attempts >= 8 then
          raise exception 'Unable to create a unique room code.';
        end if;
    end;
  end loop;

  return public.qa_room_bundle(v_room.code, null, null);
end;
$$;

create or replace function public.qa_get_room(
  p_room_code text,
  p_player_id uuid default null,
  p_player_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.qa_room_bundle(p_room_code, p_player_id, p_player_key);
end;
$$;

create or replace function public.qa_join_room(
  p_room_code text,
  p_nickname text,
  p_player_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.qa_rooms%rowtype;
  v_player public.qa_players%rowtype;
  v_nickname text;
begin
  v_nickname := left(btrim(p_nickname), 20);

  if v_nickname = '' then
    raise exception 'Nickname is required.';
  end if;

  select *
    into v_room
    from public.qa_rooms
   where code = upper(trim(p_room_code));

  if not found then
    raise exception 'Room not found.';
  end if;

  insert into public.qa_players (room_id, nickname, player_key)
  values (v_room.id, v_nickname, p_player_key)
  on conflict (room_id, player_key)
  do update set nickname = excluded.nickname
  returning *
  into v_player;

  return public.qa_room_bundle(v_room.code, v_player.id, p_player_key);
end;
$$;

create or replace function public.qa_save_answer(
  p_room_code text,
  p_player_id uuid,
  p_player_key text,
  p_question_index integer,
  p_content text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.qa_rooms%rowtype;
  v_player public.qa_players%rowtype;
begin
  select *
    into v_room
    from public.qa_rooms
   where code = upper(trim(p_room_code));

  if not found then
    raise exception 'Room not found.';
  end if;

  select *
    into v_player
    from public.qa_players
   where id = p_player_id
     and room_id = v_room.id
     and player_key = p_player_key;

  if not found then
    raise exception 'Player not found.';
  end if;

  if v_player.submitted_at is not null then
    raise exception 'Submitted answers cannot be changed.';
  end if;

  insert into public.qa_answers (room_id, player_id, question_index, content, updated_at)
  values (v_room.id, v_player.id, p_question_index, coalesce(p_content, ''), now())
  on conflict (player_id, question_index)
  do update set content = excluded.content, updated_at = now();

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.qa_submit_player(
  p_room_code text,
  p_player_id uuid,
  p_player_key text,
  p_answers jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.qa_rooms%rowtype;
  v_player public.qa_players%rowtype;
  v_answer_count integer;
  v_item record;
begin
  select *
    into v_room
    from public.qa_rooms
   where code = upper(trim(p_room_code));

  if not found then
    raise exception 'Room not found.';
  end if;

  select *
    into v_player
    from public.qa_players
   where id = p_player_id
     and room_id = v_room.id
     and player_key = p_player_key;

  if not found then
    raise exception 'Player not found.';
  end if;

  if v_player.submitted_at is not null then
    return public.qa_room_bundle(v_room.code, v_player.id, p_player_key);
  end if;

  if p_answers is not null then
    for v_item in select key, value from jsonb_each_text(p_answers)
    loop
      if v_item.key ~ '^\d+$' and (v_item.key)::integer between 1 and 100 then
        insert into public.qa_answers (room_id, player_id, question_index, content, updated_at)
        values (v_room.id, v_player.id, (v_item.key)::integer, coalesce(v_item.value, ''), now())
        on conflict (player_id, question_index)
        do update set content = excluded.content, updated_at = now();
      end if;
    end loop;
  end if;

  select count(*)
    into v_answer_count
    from public.qa_answers
   where player_id = v_player.id
     and btrim(content) <> '';

  if v_answer_count < 100 then
    raise exception 'All 100 answers are required before submit.';
  end if;

  update public.qa_players
     set submitted_at = now()
   where id = v_player.id
   returning *
   into v_player;

  return public.qa_room_bundle(v_room.code, v_player.id, p_player_key);
end;
$$;

grant execute on function public.qa_create_room() to anon;
grant execute on function public.qa_get_room(text, uuid, text) to anon;
grant execute on function public.qa_join_room(text, text, text) to anon;
grant execute on function public.qa_save_answer(text, uuid, text, integer, text) to anon;
grant execute on function public.qa_submit_player(text, uuid, text, jsonb) to anon;
