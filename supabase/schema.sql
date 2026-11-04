-- Safe to rerun for existing projects: schema changes apply together and preserve records.
begin;

create extension if not exists pgcrypto;

create table if not exists public.game_accounts (
  id uuid primary key default gen_random_uuid(),
  username text not null,
  username_key text not null unique,
  password_hash text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.game_accounts
  add column if not exists display_name text check (char_length(display_name) between 1 and 20),
  add column if not exists security_question integer check (security_question between 1 and 5),
  add column if not exists security_answer_hash text,
  add column if not exists recovery_failures integer not null default 0,
  add column if not exists recovery_window_started_at timestamptz,
  add column if not exists recovery_blocked_until timestamptz;

create table if not exists public.game_account_sessions (
  token_hash text primary key,
  account_id uuid not null references public.game_accounts(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);

create index if not exists game_account_sessions_account_id_idx on public.game_account_sessions (account_id);
create index if not exists game_account_sessions_expires_at_idx on public.game_account_sessions (expires_at);

alter table public.game_accounts enable row level security;
alter table public.game_account_sessions enable row level security;

revoke all on public.game_accounts from anon, authenticated;
revoke all on public.game_account_sessions from anon, authenticated;

create table if not exists public.qa_rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  title text not null default '100 Q&As',
  questions jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.qa_rooms
add column if not exists questions jsonb not null default '[]'::jsonb;

alter table public.qa_rooms
add column if not exists owner_account_id uuid;

do $$
begin
  if not exists (
    select 1
      from pg_constraint
     where conname = 'qa_rooms_questions_array'
       and conrelid = 'public.qa_rooms'::regclass
  ) then
    alter table public.qa_rooms
    add constraint qa_rooms_questions_array check (jsonb_typeof(questions) = 'array');
  end if;
end $$;

create table if not exists public.qa_players (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.qa_rooms(id) on delete cascade,
  nickname text not null,
  player_key text not null,
  created_at timestamptz not null default now(),
  submitted_at timestamptz,
  unique (room_id, player_key)
);

alter table public.qa_players
add column if not exists account_id uuid;

do $$
begin
  alter table public.qa_rooms drop constraint if exists qa_rooms_owner_account_id_fkey;
  alter table public.qa_players drop constraint if exists qa_players_account_id_fkey;

  update public.qa_rooms r
     set owner_account_id = null
   where owner_account_id is not null
     and not exists (
       select 1 from public.game_accounts a where a.id = r.owner_account_id
     );

  update public.qa_players p
     set account_id = null
   where account_id is not null
     and not exists (
       select 1 from public.game_accounts a where a.id = p.account_id
     );

  if not exists (
    select 1 from pg_constraint
     where conname = 'qa_rooms_owner_account_id_game_accounts_fkey'
       and conrelid = 'public.qa_rooms'::regclass
  ) then
    alter table public.qa_rooms
    add constraint qa_rooms_owner_account_id_game_accounts_fkey
    foreign key (owner_account_id) references public.game_accounts(id) on delete set null;
  end if;

  if not exists (
    select 1 from pg_constraint
     where conname = 'qa_players_account_id_game_accounts_fkey'
       and conrelid = 'public.qa_players'::regclass
  ) then
    alter table public.qa_players
    add constraint qa_players_account_id_game_accounts_fkey
    foreign key (account_id) references public.game_accounts(id) on delete set null;
  end if;
end $$;


create table if not exists public.qa_answers (
  room_id uuid not null references public.qa_rooms(id) on delete cascade,
  player_id uuid not null references public.qa_players(id) on delete cascade,
  question_index integer not null check (question_index between 1 and 100),
  content text not null default '',
  updated_at timestamptz not null default now(),
  primary key (player_id, question_index)
);

create index if not exists qa_rooms_owner_account_id_idx on public.qa_rooms (owner_account_id);
create index if not exists qa_players_account_id_idx on public.qa_players (account_id);

alter table public.qa_rooms enable row level security;
alter table public.qa_players enable row level security;
alter table public.qa_answers enable row level security;

revoke all on public.qa_rooms from anon, authenticated;
revoke all on public.qa_players from anon, authenticated;
revoke all on public.qa_answers from anon, authenticated;
grant usage on schema public to anon, authenticated;

alter table public.qa_players add column if not exists submitted_name text;

create or replace function public.game_account_id_from_token(p_account_token text)
returns uuid language plpgsql security definer set search_path = public
as $$
declare v_account_id uuid; v_hash text;
begin
  if coalesce(btrim(p_account_token), '') = '' then raise exception 'Login required.'; end if;
  v_hash := encode(extensions.digest(p_account_token, 'sha256'), 'hex');
  select account_id into v_account_id from public.game_account_sessions where token_hash=v_hash and expires_at>now();
  if v_account_id is null then raise exception 'Login required.'; end if;
  perform 1 from public.game_accounts where id=v_account_id for update;
  update public.game_account_sessions set expires_at=clock_timestamp()+interval '90 days'
    where token_hash=v_hash and expires_at>clock_timestamp() returning account_id into v_account_id;
  if not found then raise exception 'Login required.'; end if;
  return v_account_id;
end;
$$;

create or replace function public.account_refresh(p_account_token text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare v_id uuid := public.game_account_id_from_token(p_account_token); v_result jsonb;
begin
  select jsonb_build_object('token', p_account_token, 'expiresAt', s.expires_at,
    'account', jsonb_build_object('id', a.id, 'username', a.username, 'displayName', a.display_name)) into v_result
  from public.game_account_sessions s join public.game_accounts a on a.id = s.account_id
  where s.token_hash = encode(extensions.digest(p_account_token, 'sha256'), 'hex') and s.account_id = v_id;
  if v_result is null then raise exception 'Login required.'; end if;
  return v_result;
end;
$$;
revoke execute on function public.account_refresh(text) from public;
grant execute on function public.account_refresh(text) to anon, authenticated;

create or replace function public.account_session_payload(
  p_account public.game_accounts
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token text := encode(extensions.gen_random_bytes(32), 'hex');
  v_expires_at timestamptz := now() + interval '90 days';
begin
  insert into public.game_account_sessions (token_hash, account_id, expires_at)
  values (encode(extensions.digest(v_token, 'sha256'), 'hex'), p_account.id, v_expires_at);

  return jsonb_build_object(
    'account', jsonb_build_object(
      'id', p_account.id,
      'username', p_account.username,
      'displayName', p_account.display_name
    ),
    'token', v_token,
    'expiresAt', v_expires_at
  );
end;
$$;

drop function if exists public.account_register(text, text);

create or replace function public.account_register(
  p_username text,
  p_password text,
  p_display_name text,
  p_security_question integer,
  p_security_answer text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_username text := btrim(coalesce(p_username, ''));
  v_username_key text := lower(btrim(coalesce(p_username, '')));
  v_account public.game_accounts%rowtype;
begin
  if char_length(v_username) < 2
     or char_length(v_username) > 20
     or v_username !~ '^[0-9A-Za-z_一-龥]+$' then
    raise exception 'Invalid username.';
  end if;

  if char_length(coalesce(p_password, '')) < 4 then
    raise exception 'Password is too short.';
  end if;

  if octet_length(p_password) > 72 then raise exception 'Password is too long.'; end if;
  if char_length(btrim(coalesce(p_display_name,''))) not between 1 and 20 then raise exception 'Invalid display name.'; end if;
  if p_security_question is null or p_security_question not between 1 and 5 then raise exception 'Invalid security question.'; end if;
  if char_length(btrim(coalesce(p_security_answer,''))) not between 1 and 100 then raise exception 'Invalid security answer.'; end if;

  insert into public.game_accounts (username, username_key, password_hash, display_name, security_question, security_answer_hash)
  values (v_username, v_username_key, extensions.crypt(p_password, extensions.gen_salt('bf',10)),
    btrim(p_display_name),p_security_question,
    extensions.crypt(encode(extensions.digest(lower(btrim(p_security_answer)),'sha256'),'hex'),extensions.gen_salt('bf',10)))
  returning *
  into v_account;

  return public.account_session_payload(v_account);
exception
  when unique_violation then
    raise exception 'Username already exists.';
end;
$$;

create or replace function public.account_login(
  p_username text,
  p_password text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_username_key text := lower(btrim(coalesce(p_username, '')));
  v_account public.game_accounts%rowtype;
begin
  select *
    into v_account
    from public.game_accounts
   where username_key = v_username_key for update;

  if not found or v_account.password_hash <> extensions.crypt(coalesce(p_password, ''), v_account.password_hash) then
    raise exception 'Invalid username or password.';
  end if;

  update public.game_accounts
     set updated_at = now()
   where id = v_account.id;

  return public.account_session_payload(v_account);
end;
$$;

create or replace function public.account_logout(
  p_account_token text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(btrim(p_account_token), '') <> '' then
    delete from public.game_account_sessions
     where token_hash = encode(extensions.digest(p_account_token, 'sha256'), 'hex');
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

drop function if exists public.qa_room_bundle(text, uuid, text);

create or replace function public.qa_room_bundle(
  p_room_code text,
  p_player_id uuid default null,
  p_player_key text default null,
  p_account_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.qa_rooms%rowtype;
  v_current public.qa_players%rowtype;
  v_account_id uuid := public.game_account_id_from_token(p_account_token);
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

  if p_player_id is not null and (p_player_key is not null or v_account_id is not null) then
    select *
      into v_current
      from public.qa_players
     where id = p_player_id
       and room_id = v_room.id
       and (
         account_id = v_account_id
       );

    v_has_current := found;
    v_can_view_results := v_has_current and v_current.submitted_at is not null;
  end if;

  if not v_has_current and v_account_id is not null then
    select *
      into v_current
      from public.qa_players
     where room_id = v_room.id
       and account_id = v_account_id
     order by created_at
     limit 1;

    v_has_current := found;
    v_can_view_results := v_has_current and v_current.submitted_at is not null;
  end if;

  return jsonb_build_object(
    'room', jsonb_build_object(
      'id', v_room.id,
      'code', v_room.code,
      'title', v_room.title,
      'questions', case
        when jsonb_typeof(v_room.questions) = 'array'
         and jsonb_array_length(v_room.questions) between 1 and 100
        then v_room.questions
        else null
      end,
      'questionCount', case
        when jsonb_typeof(v_room.questions) = 'array'
         and jsonb_array_length(v_room.questions) between 1 and 100
        then jsonb_array_length(v_room.questions)
        else 100
      end,
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
          'submittedName', player_rows.submitted_name,
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
          p.submitted_name,
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

drop function if exists public.qa_create_room();
drop function if exists public.qa_create_room(jsonb);

create or replace function public.qa_create_room(
  p_questions jsonb default null,
  p_account_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.qa_rooms%rowtype;
  v_questions jsonb := '[]'::jsonb;
  v_account_id uuid := public.game_account_id_from_token(p_account_token);
  v_attempts integer := 0;
begin
  if p_questions is not null then
    if jsonb_typeof(p_questions) <> 'array' then
      raise exception 'Question bank must be an array.';
    end if;

    select coalesce(
      jsonb_agg(to_jsonb(left(btrim(question_item.value #>> '{}'), 240)) order by question_item.ordinality),
      '[]'::jsonb
    )
      into v_questions
      from jsonb_array_elements(p_questions) with ordinality as question_item(value, ordinality)
     where jsonb_typeof(question_item.value) = 'string'
       and btrim(question_item.value #>> '{}') <> '';

    if jsonb_array_length(v_questions) = 0 then
      raise exception 'Question bank must contain at least 1 question.';
    end if;

    if jsonb_array_length(v_questions) > 100 then
      raise exception 'Question bank can contain at most 100 questions.';
    end if;
  end if;

  loop
    v_attempts := v_attempts + 1;

    begin
      insert into public.qa_rooms (code, questions, owner_account_id)
      values (substring(upper(replace(gen_random_uuid()::text, '-', '')) from 1 for 6), v_questions, v_account_id)
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

  return public.qa_room_bundle(v_room.code, null, null, p_account_token);
end;
$$;

drop function if exists public.qa_get_room(text, uuid, text);

create or replace function public.qa_get_room(
  p_room_code text,
  p_player_id uuid default null,
  p_player_key text default null,
  p_account_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.qa_room_bundle(p_room_code, p_player_id, p_player_key, p_account_token);
end;
$$;

drop function if exists public.qa_join_room(text, text, text);

create or replace function public.qa_join_room(
  p_room_code text,
  p_nickname text,
  p_player_key text,
  p_account_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.qa_rooms%rowtype;
  v_player public.qa_players%rowtype;
  v_account_id uuid := public.game_account_id_from_token(p_account_token);
  v_nickname text;
begin
  select display_name into v_nickname from public.game_accounts where id=v_account_id;

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

  if v_account_id is not null then
    select *
      into v_player
      from public.qa_players
     where room_id = v_room.id
       and account_id = v_account_id
     order by created_at
     limit 1;

    if found then
      update public.qa_players
         set nickname = v_nickname
       where id = v_player.id
       returning *
       into v_player;

      return public.qa_room_bundle(v_room.code, v_player.id, null, p_account_token);
    end if;
  end if;

  insert into public.qa_players (room_id, nickname, player_key, account_id)
  values (v_room.id, v_nickname, p_player_key, v_account_id)
  on conflict (room_id, player_key)
  do update set
    nickname = excluded.nickname
  where public.qa_players.account_id = v_account_id
  returning *
  into v_player;

  return public.qa_room_bundle(v_room.code, v_player.id, p_player_key, p_account_token);
end;
$$;

drop function if exists public.qa_save_answer(text, uuid, text, integer, text);

create or replace function public.qa_save_answer(
  p_room_code text,
  p_player_id uuid,
  p_player_key text,
  p_question_index integer,
  p_content text,
  p_account_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.qa_rooms%rowtype;
  v_player public.qa_players%rowtype;
  v_account_id uuid := public.game_account_id_from_token(p_account_token);
  v_required_count integer;
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
     and (
       account_id = v_account_id
     );

  if not found then
    raise exception 'Player not found.';
  end if;

  if v_player.submitted_at is not null then
    raise exception 'Submitted answers cannot be changed.';
  end if;

  v_required_count := case
    when jsonb_typeof(v_room.questions) = 'array'
     and jsonb_array_length(v_room.questions) between 1 and 100
    then jsonb_array_length(v_room.questions)
    else 100
  end;

  if p_question_index < 1 or p_question_index > v_required_count then
    raise exception 'Question index is outside this room question bank.';
  end if;

  insert into public.qa_answers (room_id, player_id, question_index, content, updated_at)
  values (v_room.id, v_player.id, p_question_index, coalesce(p_content, ''), now())
  on conflict (player_id, question_index)
  do update set content = excluded.content, updated_at = now();

  return jsonb_build_object('ok', true);
end;
$$;

drop function if exists public.qa_submit_player(text, uuid, text, jsonb);

create or replace function public.qa_submit_player(
  p_room_code text,
  p_player_id uuid,
  p_player_key text,
  p_answers jsonb default null,
  p_account_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.qa_rooms%rowtype;
  v_player public.qa_players%rowtype;
  v_account_id uuid := public.game_account_id_from_token(p_account_token);
  v_required_count integer;
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
     and (
       account_id = v_account_id
     );

  if not found then
    raise exception 'Player not found.';
  end if;

  if v_player.submitted_at is not null then
    return public.qa_room_bundle(v_room.code, v_player.id, p_player_key, p_account_token);
  end if;

  v_required_count := case
    when jsonb_typeof(v_room.questions) = 'array'
     and jsonb_array_length(v_room.questions) between 1 and 100
    then jsonb_array_length(v_room.questions)
    else 100
  end;

  if p_answers is not null then
    for v_item in select key, value from jsonb_each_text(p_answers)
    loop
      if v_item.key ~ '^\d+$' and (v_item.key)::integer between 1 and v_required_count then
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

  if v_answer_count < v_required_count then
    raise exception 'All answers are required before submit.';
  end if;

  update public.qa_players
     set submitted_at = now(), submitted_name = nickname
   where id = v_player.id
   returning *
   into v_player;

  return public.qa_room_bundle(v_room.code, v_player.id, p_player_key, p_account_token);
end;
$$;

revoke execute on function public.account_register(text, text, text, integer, text) from public;
grant execute on function public.account_register(text, text, text, integer, text) to anon, authenticated;
grant execute on function public.account_login(text, text) to anon, authenticated;
grant execute on function public.account_logout(text) to anon, authenticated;
grant execute on function public.qa_create_room(jsonb, text) to anon, authenticated;
grant execute on function public.qa_get_room(text, uuid, text, text) to anon, authenticated;
grant execute on function public.qa_join_room(text, text, text, text) to anon, authenticated;
grant execute on function public.qa_save_answer(text, uuid, text, integer, text, text) to anon, authenticated;
grant execute on function public.qa_submit_player(text, uuid, text, jsonb, text) to anon, authenticated;
revoke execute on function public.qa_room_bundle(text, uuid, text, text) from public, anon, authenticated;

create or replace function public.tycoon_default_map()
returns jsonb
language sql
stable
set search_path = public
as $$
  select '[
    {"name":"起点","type":"start"},
    {"name":"北京胡同","type":"property","price":42000,"rent":3600,"upgradeCost":22000},
    {"name":"机会","type":"chance"},
    {"name":"东京涩谷","type":"property","price":56000,"rent":4600,"upgradeCost":28000},
    {"name":"城市税","type":"tax","fee":9000},
    {"name":"首尔弘大","type":"property","price":50000,"rent":4200,"upgradeCost":26000},
    {"name":"机场","type":"airport"},
    {"name":"新加坡滨海湾","type":"property","price":68000,"rent":5600,"upgradeCost":34000},
    {"name":"旅行奖金","type":"bonus","bonus":12000},
    {"name":"曼谷夜市","type":"property","price":47000,"rent":3900,"upgradeCost":24000},
    {"name":"悉尼港湾","type":"property","price":62000,"rent":5100,"upgradeCost":31000},
    {"name":"机会","type":"chance"},
    {"name":"迪拜塔","type":"property","price":72000,"rent":6200,"upgradeCost":36000},
    {"name":"伊斯坦布尔老城","type":"property","price":54000,"rent":4500,"upgradeCost":27000},
    {"name":"奢侈税","type":"tax","fee":14000},
    {"name":"雅典卫城","type":"property","price":52000,"rent":4300,"upgradeCost":26000},
    {"name":"免费停车","type":"rest"},
    {"name":"罗马斗兽场","type":"property","price":64000,"rent":5300,"upgradeCost":32000},
    {"name":"巴黎左岸","type":"property","price":70000,"rent":6000,"upgradeCost":35000},
    {"name":"机会","type":"chance"},
    {"name":"伦敦西区","type":"property","price":69000,"rent":5900,"upgradeCost":34000},
    {"name":"阿姆斯特丹运河","type":"property","price":58000,"rent":4800,"upgradeCost":29000},
    {"name":"机场","type":"airport"},
    {"name":"柏林博物馆岛","type":"property","price":57000,"rent":4700,"upgradeCost":28000},
    {"name":"灵感奖金","type":"bonus","bonus":15000},
    {"name":"哥本哈根港口","type":"property","price":60000,"rent":5000,"upgradeCost":30000},
    {"name":"雷克雅未克极光","type":"property","price":66000,"rent":5500,"upgradeCost":33000},
    {"name":"维护费","type":"tax","fee":11000},
    {"name":"纽约时代广场","type":"property","price":76000,"rent":6500,"upgradeCost":38000},
    {"name":"洛杉矶日落大道","type":"property","price":67000,"rent":5600,"upgradeCost":33000},
    {"name":"机会","type":"chance"},
    {"name":"旧金山海湾","type":"property","price":71000,"rent":6100,"upgradeCost":36000}
  ]'::jsonb;
$$;

create table if not exists public.tycoon_rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  host_player_id uuid,
  status text not null default 'lobby' check (status in ('lobby', 'active', 'finished', 'closed')),
  victory_mode text not null default 'survivor' check (victory_mode in ('survivor', 'turnLimit')),
  turn_limit integer not null default 30 check (turn_limit between 10 and 60),
  current_turn integer not null default 1 check (current_turn >= 1),
  current_player_id uuid,
  turn_phase text not null default 'roll' check (turn_phase in ('roll', 'action', 'finished', 'closed')),
  last_dice integer check (last_dice is null or last_dice between 1 and 6),
  pending_action text check (pending_action is null or pending_action in ('buy', 'upgrade')),
  action_cell_index integer check (action_cell_index is null or action_cell_index between 0 and 31),
  action_deadline timestamptz,
  map jsonb not null default public.tycoon_default_map(),
  final_results jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (jsonb_typeof(map) = 'array')
);

create table if not exists public.tycoon_players (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.tycoon_rooms(id) on delete cascade,
  nickname text not null,
  player_key text not null,
  cash integer not null default 200000,
  position integer not null default 0 check (position between 0 and 31),
  status text not null default 'waiting' check (status in ('waiting', 'active', 'bankrupt')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (room_id, player_key)
);

alter table public.tycoon_rooms
add column if not exists owner_account_id uuid;

alter table public.tycoon_rooms
add column if not exists pending_action text,
add column if not exists action_cell_index integer,
add column if not exists action_deadline timestamptz;

do $$
begin
  alter table public.tycoon_rooms drop constraint if exists tycoon_rooms_pending_action_check;
  alter table public.tycoon_rooms drop constraint if exists tycoon_rooms_action_cell_index_check;
  alter table public.tycoon_rooms
    add constraint tycoon_rooms_pending_action_check
    check (pending_action is null or pending_action in ('buy', 'upgrade'));
  alter table public.tycoon_rooms
    add constraint tycoon_rooms_action_cell_index_check
    check (action_cell_index is null or action_cell_index between 0 and 31);
end $$;

alter table public.tycoon_players
add column if not exists account_id uuid,
add column if not exists color_id integer;

do $$
begin
  alter table public.tycoon_players drop constraint if exists tycoon_players_color_id_check;
  alter table public.tycoon_players
    add constraint tycoon_players_color_id_check
    check (color_id is null or color_id between 0 and 5);
end $$;

do $$
begin
  alter table public.tycoon_rooms drop constraint if exists tycoon_rooms_owner_account_id_fkey;
  alter table public.tycoon_players drop constraint if exists tycoon_players_account_id_fkey;

  update public.tycoon_rooms r
     set owner_account_id = null
   where owner_account_id is not null
     and not exists (
       select 1 from public.game_accounts a where a.id = r.owner_account_id
     );

  update public.tycoon_players p
     set account_id = null
   where account_id is not null
     and not exists (
       select 1 from public.game_accounts a where a.id = p.account_id
     );

  if not exists (
    select 1 from pg_constraint
     where conname = 'tycoon_rooms_owner_account_id_game_accounts_fkey'
       and conrelid = 'public.tycoon_rooms'::regclass
  ) then
    alter table public.tycoon_rooms
    add constraint tycoon_rooms_owner_account_id_game_accounts_fkey
    foreign key (owner_account_id) references public.game_accounts(id) on delete set null;
  end if;

  if not exists (
    select 1 from pg_constraint
     where conname = 'tycoon_players_account_id_game_accounts_fkey'
       and conrelid = 'public.tycoon_players'::regclass
  ) then
    alter table public.tycoon_players
    add constraint tycoon_players_account_id_game_accounts_fkey
    foreign key (account_id) references public.game_accounts(id) on delete set null;
  end if;
end $$;

create table if not exists public.tycoon_properties (
  room_id uuid not null references public.tycoon_rooms(id) on delete cascade,
  cell_index integer not null check (cell_index between 0 and 31),
  owner_player_id uuid references public.tycoon_players(id) on delete set null,
  level integer not null default 0 check (level between 0 and 4),
  primary key (room_id, cell_index)
);

create table if not exists public.tycoon_logs (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.tycoon_rooms(id) on delete cascade,
  kind text not null default 'info',
  message text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.tycoon_messages (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.tycoon_rooms(id) on delete cascade,
  player_id uuid references public.tycoon_players(id) on delete set null,
  nickname text not null,
  content text not null,
  created_at timestamptz not null default now()
);

create index if not exists tycoon_players_room_id_idx on public.tycoon_players (room_id);
create index if not exists tycoon_rooms_owner_account_id_idx on public.tycoon_rooms (owner_account_id);
create index if not exists tycoon_players_account_id_idx on public.tycoon_players (account_id);
create index if not exists tycoon_properties_room_id_idx on public.tycoon_properties (room_id);
create index if not exists tycoon_properties_owner_player_id_idx on public.tycoon_properties (owner_player_id);
create index if not exists tycoon_logs_room_id_created_at_idx on public.tycoon_logs (room_id, created_at desc);
create index if not exists tycoon_messages_room_id_created_at_idx on public.tycoon_messages (room_id, created_at desc);

alter table public.tycoon_rooms enable row level security;
alter table public.tycoon_players enable row level security;
alter table public.tycoon_properties enable row level security;
alter table public.tycoon_logs enable row level security;
alter table public.tycoon_messages enable row level security;

revoke all on public.tycoon_rooms from anon, authenticated;
revoke all on public.tycoon_players from anon, authenticated;
revoke all on public.tycoon_properties from anon, authenticated;
revoke all on public.tycoon_logs from anon, authenticated;
revoke all on public.tycoon_messages from anon, authenticated;

create or replace function public.tycoon_add_log(
  p_room_id uuid,
  p_message text,
  p_kind text default 'info'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.tycoon_logs (room_id, message, kind)
  values (p_room_id, left(p_message, 280), coalesce(p_kind, 'info'));
end;
$$;

drop function if exists public.tycoon_room_bundle(text, uuid, text);

create or replace function public.tycoon_room_bundle(
  p_room_code text,
  p_player_id uuid default null,
  p_player_key text default null,
  p_account_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.tycoon_rooms%rowtype;
  v_current public.tycoon_players%rowtype;
  v_account_id uuid := public.game_account_id_from_token(p_account_token);
  v_has_current boolean := false;
begin
  select *
    into v_room
    from public.tycoon_rooms
   where code = upper(trim(p_room_code));

  if not found then
    return null;
  end if;

  if p_player_id is not null and (p_player_key is not null or v_account_id is not null) then
    select *
      into v_current
      from public.tycoon_players
     where id = p_player_id
       and room_id = v_room.id
       and (
         account_id = v_account_id
       );

    v_has_current := found;
  end if;

  if not v_has_current and v_account_id is not null then
    select *
      into v_current
      from public.tycoon_players
     where room_id = v_room.id
       and account_id = v_account_id
     order by created_at
     limit 1;

    v_has_current := found;
  end if;

  if not v_has_current then
    return jsonb_build_object('room', jsonb_build_object('id', v_room.id, 'code', v_room.code,
      'status', v_room.status, 'createdAt', v_room.created_at, 'map', v_room.map),
      'currentPlayerId', null, 'players', '[]'::jsonb, 'properties', '[]'::jsonb,
      'logs', '[]'::jsonb, 'messages', '[]'::jsonb);
  end if;

  return jsonb_build_object(
    'room', jsonb_build_object(
      'id', v_room.id,
      'code', v_room.code,
      'hostPlayerId', v_room.host_player_id,
      'status', v_room.status,
      'victoryMode', v_room.victory_mode,
      'turnLimit', v_room.turn_limit,
      'currentTurn', v_room.current_turn,
      'currentPlayerId', v_room.current_player_id,
      'turnPhase', v_room.turn_phase,
      'lastDice', v_room.last_dice,
      'pendingAction', v_room.pending_action,
      'actionCellIndex', v_room.action_cell_index,
      'actionDeadline', v_room.action_deadline,
      'map', v_room.map,
      'finalResults', v_room.final_results,
      'createdAt', v_room.created_at
    ),
    'currentPlayerId', case when v_has_current then v_current.id else null end,
    'players', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', p.id,
          'nickname', p.nickname,
          'colorId', p.color_id,
          'cash', p.cash,
          'position', p.position,
          'status', p.status,
          'createdAt', p.created_at
        )
        order by p.created_at
      )
      from public.tycoon_players p
      where p.room_id = v_room.id
    ), '[]'::jsonb),
    'properties', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'cellIndex', pr.cell_index,
          'ownerId', pr.owner_player_id,
          'level', pr.level
        )
        order by pr.cell_index
      )
      from public.tycoon_properties pr
      where pr.room_id = v_room.id
    ), '[]'::jsonb),
    'logs', coalesce((
      select jsonb_agg(log_rows.item order by log_rows.created_at desc)
      from (
        select
          l.created_at,
          jsonb_build_object(
            'id', l.id,
            'kind', l.kind,
            'message', l.message,
            'createdAt', l.created_at
          ) as item
        from public.tycoon_logs l
        where l.room_id = v_room.id
        order by l.created_at desc
        limit 80
      ) log_rows
    ), '[]'::jsonb),
    'messages', case
      when v_room.status in ('finished', 'closed') then '[]'::jsonb
      else coalesce((
        select jsonb_agg(message_rows.item order by message_rows.created_at)
        from (
          select
            m.created_at,
            jsonb_build_object(
              'id', m.id,
              'playerId', m.player_id,
              'nickname', m.nickname,
              'content', m.content,
              'createdAt', m.created_at
            ) as item
          from public.tycoon_messages m
          where m.room_id = v_room.id
          order by m.created_at desc
          limit 40
        ) message_rows
      ), '[]'::jsonb)
    end
  );
end;
$$;

create or replace function public.tycoon_build_final_results(
  p_room_id uuid
)
returns jsonb
language sql
security definer
set search_path = public
as $$
  with room_row as (
    select *
      from public.tycoon_rooms
     where id = p_room_id
  ),
  player_values as (
    select
      p.id,
      p.nickname,
      p.cash,
      p.status,
      coalesce(prop_values.property_count, 0) as property_count,
      p.cash + coalesce(prop_values.property_value, 0) as net_worth
    from public.tycoon_players p
    cross join room_row r
    left join lateral (
      select
        count(*)::integer as property_count,
        sum(
          ((r.map -> pr.cell_index ->> 'price')::integer)
          + greatest(pr.level - 1, 0) * ((r.map -> pr.cell_index ->> 'upgradeCost')::integer)
        )::integer as property_value
      from public.tycoon_properties pr
      where pr.owner_player_id = p.id
    ) prop_values on true
    where p.room_id = p_room_id
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', id,
      'nickname', nickname,
      'cash', cash,
      'status', status,
      'propertyCount', property_count,
      'netWorth', net_worth
    )
    order by (status = 'active') desc, net_worth desc, cash desc, nickname
  ), '[]'::jsonb)
  from player_values;
$$;

create or replace function public.tycoon_finish_if_needed(
  p_room_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.tycoon_rooms%rowtype;
  v_active_count integer;
  v_results jsonb;
  v_winner_id text;
  v_winner_name text;
  v_reason text;
begin
  select *
    into v_room
    from public.tycoon_rooms
   where id = p_room_id
   for update;

  if not found or v_room.status <> 'active' then
    return;
  end if;

  select count(*)
    into v_active_count
    from public.tycoon_players
   where room_id = p_room_id
     and status = 'active';

  if v_active_count <= 1 then
    v_reason := 'survivor';
  elsif v_room.victory_mode = 'turnLimit' and v_room.current_turn > v_room.turn_limit then
    v_reason := 'turnLimit';
  else
    return;
  end if;

  v_results := public.tycoon_build_final_results(p_room_id);
  if v_reason = 'survivor' then
    select id::text, nickname
      into v_winner_id, v_winner_name
      from public.tycoon_players
     where room_id = p_room_id
       and status = 'active'
     order by created_at
     limit 1;
  else
    v_winner_id := v_results -> 0 ->> 'id';
    v_winner_name := coalesce(v_results -> 0 ->> 'nickname', '');
  end if;

  update public.tycoon_rooms
     set status = 'finished',
         turn_phase = 'finished',
         current_player_id = null,
         pending_action = null,
         action_cell_index = null,
         action_deadline = null,
         final_results = jsonb_build_object(
           'reason', v_reason,
           'winnerId', v_winner_id,
           'winnerName', v_winner_name,
           'results', v_results,
           'finishedAt', now()
         ),
         updated_at = now()
   where id = p_room_id;

  delete from public.tycoon_messages
   where room_id = p_room_id;

  perform public.tycoon_add_log(p_room_id, case when v_winner_name <> '' then '游戏结束，' || v_winner_name || ' 获胜。' else '游戏结束。' end, 'finish');
end;
$$;

create or replace function public.tycoon_bankrupt_player(
  p_room_id uuid,
  p_player_id uuid,
  p_reason text default ''
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.tycoon_rooms%rowtype;
  v_player public.tycoon_players%rowtype;
  v_replacement uuid;
  v_replacement_name text;
begin
  select *
    into v_room
    from public.tycoon_rooms
   where id = p_room_id
   for update;

  select *
    into v_player
    from public.tycoon_players
   where id = p_player_id
     and room_id = p_room_id
   for update;

  if not found or v_player.status = 'bankrupt' then
    return;
  end if;

  update public.tycoon_players
     set status = 'bankrupt',
         updated_at = now()
   where id = p_player_id;

  update public.tycoon_properties
     set owner_player_id = null,
         level = 0
   where room_id = p_room_id
     and owner_player_id = p_player_id;

  perform public.tycoon_add_log(p_room_id, v_player.nickname || ' 破产出局。' || case when coalesce(p_reason, '') <> '' then ' ' || p_reason else '' end, 'bankrupt');

  if v_room.host_player_id = p_player_id then
    select id, nickname
      into v_replacement, v_replacement_name
      from public.tycoon_players
     where room_id = p_room_id
       and id <> p_player_id
       and status <> 'bankrupt'
     order by created_at
     limit 1;

    update public.tycoon_rooms
       set host_player_id = v_replacement,
           updated_at = now()
     where id = p_room_id;

    if v_replacement is not null then
      perform public.tycoon_add_log(p_room_id, v_replacement_name || ' 成为新的房主。', 'host');
    end if;
  end if;
end;
$$;

create or replace function public.tycoon_advance_turn(
  p_room_id uuid,
  p_current_player_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
  v_current_rank integer;
  v_next_rank integer;
  v_next_player_id uuid;
begin
  select count(*)
    into v_count
    from public.tycoon_players
   where room_id = p_room_id
     and status = 'active';

  if v_count = 0 then
    perform public.tycoon_finish_if_needed(p_room_id);
    return;
  end if;

  if v_count = 1 then
    select id
      into v_next_player_id
      from public.tycoon_players
     where room_id = p_room_id
       and status = 'active'
     order by created_at
     limit 1;

    update public.tycoon_rooms
       set current_player_id = v_next_player_id,
           turn_phase = 'roll',
           last_dice = null,
           pending_action = null,
           action_cell_index = null,
           action_deadline = null,
           updated_at = now()
     where id = p_room_id;

    perform public.tycoon_finish_if_needed(p_room_id);
    return;
  end if;

  select ranked.rn
    into v_current_rank
    from (
      select id, row_number() over (order by created_at) as rn
        from public.tycoon_players
       where room_id = p_room_id
         and status = 'active'
    ) ranked
   where ranked.id = p_current_player_id;

  v_next_rank := coalesce(v_current_rank, 0) + 1;
  if v_next_rank > v_count then
    v_next_rank := 1;
    update public.tycoon_rooms
       set current_turn = current_turn + 1
     where id = p_room_id;
  end if;

  select ranked.id
    into v_next_player_id
    from (
      select id, row_number() over (order by created_at) as rn
        from public.tycoon_players
       where room_id = p_room_id
         and status = 'active'
    ) ranked
   where ranked.rn = v_next_rank;

  update public.tycoon_rooms
     set current_player_id = v_next_player_id,
         turn_phase = 'roll',
         last_dice = null,
         pending_action = null,
         action_cell_index = null,
         action_deadline = null,
         updated_at = now()
   where id = p_room_id;

  perform public.tycoon_finish_if_needed(p_room_id);
end;
$$;

create or replace function public.tycoon_pick_color_id(
  p_room_id uuid,
  p_preferred_color_id integer default null,
  p_exclude_player_id uuid default null
)
returns integer
language sql
security definer
set search_path = public
as $$
  with candidates as (
    select candidate, min(priority) as priority
      from unnest(array[
        case when p_preferred_color_id between 0 and 5 then p_preferred_color_id else null end,
        0, 1, 2, 3, 4, 5
      ]) with ordinality as color_options(candidate, priority)
     where candidate is not null
     group by candidate
  )
  select coalesce((
    select c.candidate
      from candidates c
     where not exists (
       select 1
         from public.tycoon_players p
        where p.room_id = p_room_id
          and p.status <> 'bankrupt'
          and p.color_id = c.candidate
          and (p_exclude_player_id is null or p.id <> p_exclude_player_id)
     )
     order by c.priority
     limit 1
  ), 0);
$$;

drop function if exists public.tycoon_create_room(text, text, text, integer);
drop function if exists public.tycoon_create_room(text, text, text, integer, text);
drop function if exists public.tycoon_create_room(text, text, text, integer, integer, text);

create or replace function public.tycoon_create_room(
  p_nickname text,
  p_player_key text,
  p_victory_mode text default 'survivor',
  p_turn_limit integer default 30,
  p_color_id integer default null,
  p_account_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.tycoon_rooms%rowtype;
  v_player public.tycoon_players%rowtype;
  v_account_id uuid := public.game_account_id_from_token(p_account_token);
  v_code text;
  v_attempts integer := 0;
  v_nickname text;
begin
  select display_name into v_nickname from public.game_accounts where id=v_account_id;
  if v_nickname = '' then
    raise exception 'Nickname is required.';
  end if;

  loop
    v_attempts := v_attempts + 1;
    v_code := substring(upper(replace(gen_random_uuid()::text, '-', '')) from 1 for 6);

    begin
      insert into public.tycoon_rooms (code, victory_mode, turn_limit, map, owner_account_id)
      values (v_code, case when p_victory_mode = 'turnLimit' then 'turnLimit' else 'survivor' end, least(greatest(coalesce(p_turn_limit, 30), 10), 60), public.tycoon_default_map(), v_account_id)
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

  insert into public.tycoon_players (room_id, nickname, player_key, account_id, color_id)
  values (v_room.id, v_nickname, p_player_key, v_account_id, public.tycoon_pick_color_id(v_room.id, p_color_id))
  returning *
  into v_player;

  update public.tycoon_rooms
     set host_player_id = v_player.id,
         updated_at = now()
   where id = v_room.id
   returning *
   into v_room;

  insert into public.tycoon_properties (room_id, cell_index)
  select v_room.id, (cell_item.ordinality - 1)::integer
    from jsonb_array_elements(v_room.map) with ordinality as cell_item(value, ordinality)
   where cell_item.value ->> 'type' = 'property'
  on conflict do nothing;

  perform public.tycoon_add_log(v_room.id, v_player.nickname || ' 创建了房间。', 'host');

  return public.tycoon_room_bundle(v_room.code, v_player.id, p_player_key, p_account_token);
end;
$$;

drop function if exists public.tycoon_get_room(text, uuid, text);

create or replace function public.tycoon_get_room(
  p_room_code text,
  p_player_id uuid default null,
  p_player_key text default null,
  p_account_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.tycoon_room_bundle(p_room_code, p_player_id, p_player_key, p_account_token);
end;
$$;

drop function if exists public.tycoon_join_room(text, text, text);
drop function if exists public.tycoon_join_room(text, text, text, text);
drop function if exists public.tycoon_join_room(text, text, text, integer, text);

create or replace function public.tycoon_join_room(
  p_room_code text,
  p_nickname text,
  p_player_key text,
  p_color_id integer default null,
  p_account_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.tycoon_rooms%rowtype;
  v_player public.tycoon_players%rowtype;
  v_account_id uuid := public.game_account_id_from_token(p_account_token);
  v_nickname text;
  v_player_count integer;
begin
  select display_name into v_nickname from public.game_accounts where id=v_account_id;
  if v_nickname = '' then
    raise exception 'Nickname is required.';
  end if;

  select *
    into v_room
    from public.tycoon_rooms
   where code = upper(trim(p_room_code))
   for update;

  if not found then
    raise exception 'Room not found.';
  end if;

  if v_room.status <> 'lobby' then
    raise exception 'Game already started.';
  end if;

  select count(*)
    into v_player_count
    from public.tycoon_players
   where room_id = v_room.id
     and status <> 'bankrupt';

  if v_player_count >= 6 then
    raise exception 'Room is full.';
  end if;

  if v_account_id is not null then
    select *
      into v_player
      from public.tycoon_players
     where room_id = v_room.id
       and account_id = v_account_id
     order by created_at
     limit 1;

    if found then
      update public.tycoon_players
         set nickname = v_nickname,
             color_id = public.tycoon_pick_color_id(v_room.id, p_color_id, v_player.id),
             updated_at = now()
       where id = v_player.id
       returning *
       into v_player;

      return public.tycoon_room_bundle(v_room.code, v_player.id, null, p_account_token);
    end if;
  end if;

  insert into public.tycoon_players (room_id, nickname, player_key, account_id, color_id)
  values (v_room.id, v_nickname, p_player_key, v_account_id, public.tycoon_pick_color_id(v_room.id, p_color_id))
  on conflict (room_id, player_key)
  do update set
    nickname = excluded.nickname,
    color_id = public.tycoon_pick_color_id(v_room.id, excluded.color_id, public.tycoon_players.id),
    updated_at = now()
  where public.tycoon_players.account_id = v_account_id
  returning *
  into v_player;

  perform public.tycoon_add_log(v_room.id, v_player.nickname || ' 加入了游戏。', 'join');

  return public.tycoon_room_bundle(v_room.code, v_player.id, p_player_key, p_account_token);
end;
$$;

drop function if exists public.tycoon_update_player_color(text, uuid, text, integer, text);

create or replace function public.tycoon_update_player_color(
  p_room_code text,
  p_player_id uuid,
  p_player_key text,
  p_color_id integer,
  p_account_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.tycoon_rooms%rowtype;
  v_player public.tycoon_players%rowtype;
  v_account_id uuid := public.game_account_id_from_token(p_account_token);
begin
  select *
    into v_room
    from public.tycoon_rooms
   where code = upper(trim(p_room_code))
   for update;

  if not found then
    raise exception 'Room not found.';
  end if;

  if v_room.status <> 'lobby' then
    raise exception 'Color can only be changed before the game starts.';
  end if;

  select *
    into v_player
    from public.tycoon_players
   where id = p_player_id
     and room_id = v_room.id
     and (
       account_id = v_account_id
     )
   for update;

  if not found or v_player.status = 'bankrupt' then
    raise exception 'Player not found.';
  end if;

  update public.tycoon_players
     set color_id = public.tycoon_pick_color_id(v_room.id, p_color_id, v_player.id),
         updated_at = now()
   where id = v_player.id
   returning *
   into v_player;

  return public.tycoon_room_bundle(v_room.code, v_player.id, p_player_key, p_account_token);
end;
$$;

drop function if exists public.tycoon_start_game(text, uuid, text);

create or replace function public.tycoon_start_game(
  p_room_code text,
  p_player_id uuid,
  p_player_key text,
  p_account_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.tycoon_rooms%rowtype;
  v_player public.tycoon_players%rowtype;
  v_account_id uuid := public.game_account_id_from_token(p_account_token);
  v_first_player_id uuid;
  v_player_count integer;
begin
  select *
    into v_room
    from public.tycoon_rooms
   where code = upper(trim(p_room_code))
   for update;

  select *
    into v_player
    from public.tycoon_players
   where id = p_player_id
     and room_id = v_room.id
     and (
       account_id = v_account_id
     );

  if not found or v_room.host_player_id <> v_player.id then
    raise exception 'Only host can start.';
  end if;

  select count(*)
    into v_player_count
    from public.tycoon_players
   where room_id = v_room.id
     and status <> 'bankrupt';

  if v_player_count < 2 then
    raise exception 'At least two players are required.';
  end if;

  update public.tycoon_players
     set status = 'active',
         cash = 200000,
         position = 0,
         updated_at = now()
   where room_id = v_room.id
     and status <> 'bankrupt';

  update public.tycoon_properties
     set owner_player_id = null,
         level = 0
   where room_id = v_room.id;

  select id
    into v_first_player_id
    from public.tycoon_players
   where room_id = v_room.id
     and status = 'active'
   order by created_at
   limit 1;

  update public.tycoon_rooms
     set status = 'active',
         current_turn = 1,
         current_player_id = v_first_player_id,
         turn_phase = 'roll',
         last_dice = null,
         pending_action = null,
         action_cell_index = null,
         action_deadline = null,
         final_results = null,
         updated_at = now()
   where id = v_room.id;

  delete from public.tycoon_messages
   where room_id = v_room.id;

  perform public.tycoon_add_log(v_room.id, '游戏开始。', 'start');

  return public.tycoon_room_bundle(v_room.code, v_player.id, p_player_key, p_account_token);
end;
$$;

drop function if exists public.tycoon_roll_dice(text, uuid, text);

create or replace function public.tycoon_roll_dice(
  p_room_code text,
  p_player_id uuid,
  p_player_key text,
  p_account_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.tycoon_rooms%rowtype;
  v_player public.tycoon_players%rowtype;
  v_account_id uuid := public.game_account_id_from_token(p_account_token);
  v_cell jsonb;
  v_property public.tycoon_properties%rowtype;
  v_owner public.tycoon_players%rowtype;
  v_dice integer;
  v_old_position integer;
  v_new_position integer;
  v_delta integer;
  v_rent integer;
  v_price integer;
  v_upgrade_cost integer;
  v_pending_action text;
begin
  select *
    into v_room
    from public.tycoon_rooms
   where code = upper(trim(p_room_code))
   for update;

  select *
    into v_player
    from public.tycoon_players
   where id = p_player_id
     and room_id = v_room.id
     and (
       account_id = v_account_id
     )
   for update;

  if not found or v_room.status <> 'active' or v_room.current_player_id <> v_player.id or v_room.turn_phase <> 'roll' or v_player.status <> 'active' then
    raise exception 'It is not this player turn.';
  end if;

  v_dice := floor(random() * 6 + 1)::integer;
  v_old_position := v_player.position;
  v_new_position := (v_old_position + v_dice) % 32;

  update public.tycoon_rooms
     set last_dice = v_dice,
         updated_at = now()
   where id = v_room.id;

  perform public.tycoon_add_log(v_room.id, v_player.nickname || ' 掷出 ' || v_dice || '。', 'dice');

  if v_old_position + v_dice >= 32 then
    update public.tycoon_players
       set cash = cash + 20000
     where id = v_player.id;
    perform public.tycoon_add_log(v_room.id, v_player.nickname || ' 经过起点，获得 20,000。', 'money');
  end if;

  update public.tycoon_players
     set position = v_new_position,
         updated_at = now()
   where id = v_player.id
   returning *
   into v_player;

  v_cell := v_room.map -> v_new_position;
  perform public.tycoon_add_log(v_room.id, v_player.nickname || ' 到达 ' || (v_cell ->> 'name') || '。', 'move');

  if v_cell ->> 'type' = 'bonus' then
    v_delta := (v_cell ->> 'bonus')::integer;
    update public.tycoon_players set cash = cash + v_delta where id = v_player.id returning * into v_player;
    perform public.tycoon_add_log(v_room.id, v_player.nickname || ' 获得旅行奖金 ' || v_delta || '。', 'money');
  elsif v_cell ->> 'type' = 'tax' then
    v_delta := (v_cell ->> 'fee')::integer;
    update public.tycoon_players set cash = cash - v_delta where id = v_player.id returning * into v_player;
    perform public.tycoon_add_log(v_room.id, v_player.nickname || ' 支付费用 ' || v_delta || '。', 'money');
  elsif v_cell ->> 'type' = 'chance' then
    v_delta := (array[18000, -12000, 10000, -9000])[floor(random() * 4 + 1)::integer];
    update public.tycoon_players set cash = cash + v_delta where id = v_player.id returning * into v_player;
    perform public.tycoon_add_log(v_room.id, v_player.nickname || ' 抽到机会，现金变化 ' || v_delta || '。', 'chance');
  elsif v_cell ->> 'type' = 'property' then
    select *
      into v_property
      from public.tycoon_properties
     where room_id = v_room.id
       and cell_index = v_new_position
     for update;

    if v_property.owner_player_id is null then
      v_price := (v_cell ->> 'price')::integer;
      perform public.tycoon_add_log(v_room.id, (v_cell ->> 'name') || ' 暂无主人，可以购买。', 'property');
      if v_player.cash >= v_price then
        v_pending_action := 'buy';
      else
        perform public.tycoon_add_log(v_room.id, v_player.nickname || ' 现金不够，默认跳过购买。', 'property');
      end if;
    elsif v_property.owner_player_id = v_player.id then
      v_upgrade_cost := (v_cell ->> 'upgradeCost')::integer;
      perform public.tycoon_add_log(v_room.id, v_player.nickname || ' 来到自己的 ' || (v_cell ->> 'name') || '。', 'property');
      if v_property.level >= 4 then
        perform public.tycoon_add_log(v_room.id, (v_cell ->> 'name') || ' 已经满级，本回合自动结束。', 'property');
      elsif v_player.cash >= v_upgrade_cost then
        v_pending_action := 'upgrade';
      else
        perform public.tycoon_add_log(v_room.id, v_player.nickname || ' 现金不够，默认跳过升级。', 'property');
      end if;
    else
      select *
        into v_owner
        from public.tycoon_players
       where id = v_property.owner_player_id
       for update;

      v_rent := ((v_cell ->> 'rent')::integer) * greatest(v_property.level, 1);
      update public.tycoon_players set cash = cash - v_rent where id = v_player.id returning * into v_player;
      update public.tycoon_players set cash = cash + v_rent where id = v_owner.id;
      perform public.tycoon_add_log(v_room.id, v_player.nickname || ' 向 ' || v_owner.nickname || ' 支付租金 ' || v_rent || '。', 'money');
    end if;
  end if;

  if v_player.cash < 0 then
    perform public.tycoon_bankrupt_player(v_room.id, v_player.id, '现金低于 0。');
    perform public.tycoon_advance_turn(v_room.id, v_player.id);
  elsif v_pending_action in ('buy', 'upgrade') then
    update public.tycoon_rooms
       set turn_phase = 'action',
           pending_action = v_pending_action,
           action_cell_index = v_new_position,
           action_deadline = now() + make_interval(secs => 8),
           updated_at = now()
     where id = v_room.id;
  else
    perform public.tycoon_advance_turn(v_room.id, v_player.id);
  end if;

  return public.tycoon_room_bundle(v_room.code, v_player.id, p_player_key, p_account_token);
end;
$$;

drop function if exists public.tycoon_buy_property(text, uuid, text);

create or replace function public.tycoon_buy_property(
  p_room_code text,
  p_player_id uuid,
  p_player_key text,
  p_account_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.tycoon_rooms%rowtype;
  v_player public.tycoon_players%rowtype;
  v_account_id uuid := public.game_account_id_from_token(p_account_token);
  v_property public.tycoon_properties%rowtype;
  v_cell jsonb;
  v_price integer;
begin
  select * into v_room from public.tycoon_rooms where code = upper(trim(p_room_code)) for update;
  select * into v_player
    from public.tycoon_players
   where id = p_player_id
     and room_id = v_room.id
     and (
       account_id = v_account_id
     )
   for update;

  if not found or v_room.status <> 'active' or v_room.current_player_id <> v_player.id or v_room.turn_phase <> 'action' or v_room.pending_action <> 'buy' or v_room.action_cell_index <> v_player.position then
    raise exception 'Cannot buy now.';
  end if;

  if v_room.action_deadline is not null and now() > v_room.action_deadline then
    perform public.tycoon_add_log(v_room.id, '倒计时结束，默认跳过购买。', 'skip');
    perform public.tycoon_advance_turn(v_room.id, v_player.id);
    return public.tycoon_room_bundle(v_room.code, v_player.id, p_player_key, p_account_token);
  end if;

  v_cell := v_room.map -> v_player.position;
  if v_cell ->> 'type' <> 'property' then
    raise exception 'This cell is not a property.';
  end if;

  select * into v_property from public.tycoon_properties where room_id = v_room.id and cell_index = v_player.position for update;
  if v_property.owner_player_id is not null then
    raise exception 'Property already owned.';
  end if;

  v_price := (v_cell ->> 'price')::integer;
  if v_player.cash < v_price then
    raise exception 'Not enough cash.';
  end if;

  update public.tycoon_players set cash = cash - v_price, updated_at = now() where id = v_player.id;
  update public.tycoon_properties set owner_player_id = v_player.id, level = 1 where room_id = v_room.id and cell_index = v_player.position;
  perform public.tycoon_add_log(v_room.id, v_player.nickname || ' 买下 ' || (v_cell ->> 'name') || '，等级 1。', 'property');
  perform public.tycoon_advance_turn(v_room.id, v_player.id);

  return public.tycoon_room_bundle(v_room.code, v_player.id, p_player_key, p_account_token);
end;
$$;

drop function if exists public.tycoon_upgrade_property(text, uuid, text);

create or replace function public.tycoon_upgrade_property(
  p_room_code text,
  p_player_id uuid,
  p_player_key text,
  p_account_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.tycoon_rooms%rowtype;
  v_player public.tycoon_players%rowtype;
  v_account_id uuid := public.game_account_id_from_token(p_account_token);
  v_property public.tycoon_properties%rowtype;
  v_cell jsonb;
  v_cost integer;
begin
  select * into v_room from public.tycoon_rooms where code = upper(trim(p_room_code)) for update;
  select * into v_player
    from public.tycoon_players
   where id = p_player_id
     and room_id = v_room.id
     and (
       account_id = v_account_id
     )
   for update;

  if not found or v_room.status <> 'active' or v_room.current_player_id <> v_player.id or v_room.turn_phase <> 'action' or v_room.pending_action <> 'upgrade' or v_room.action_cell_index <> v_player.position then
    raise exception 'Cannot upgrade now.';
  end if;

  if v_room.action_deadline is not null and now() > v_room.action_deadline then
    perform public.tycoon_add_log(v_room.id, '倒计时结束，默认跳过升级。', 'skip');
    perform public.tycoon_advance_turn(v_room.id, v_player.id);
    return public.tycoon_room_bundle(v_room.code, v_player.id, p_player_key, p_account_token);
  end if;

  v_cell := v_room.map -> v_player.position;
  select * into v_property from public.tycoon_properties where room_id = v_room.id and cell_index = v_player.position for update;
  if v_cell ->> 'type' <> 'property' or v_property.owner_player_id <> v_player.id or v_property.level >= 4 then
    raise exception 'Cannot upgrade this property.';
  end if;

  v_cost := (v_cell ->> 'upgradeCost')::integer;
  if v_player.cash < v_cost then
    raise exception 'Not enough cash.';
  end if;

  update public.tycoon_players set cash = cash - v_cost, updated_at = now() where id = v_player.id;
  update public.tycoon_properties set level = level + 1 where room_id = v_room.id and cell_index = v_player.position;
  perform public.tycoon_add_log(v_room.id, v_player.nickname || ' 将 ' || (v_cell ->> 'name') || ' 升级。', 'property');
  perform public.tycoon_advance_turn(v_room.id, v_player.id);

  return public.tycoon_room_bundle(v_room.code, v_player.id, p_player_key, p_account_token);
end;
$$;

drop function if exists public.tycoon_end_turn(text, uuid, text);

create or replace function public.tycoon_end_turn(
  p_room_code text,
  p_player_id uuid,
  p_player_key text,
  p_account_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.tycoon_rooms%rowtype;
  v_player public.tycoon_players%rowtype;
  v_account_id uuid := public.game_account_id_from_token(p_account_token);
begin
  select * into v_room from public.tycoon_rooms where code = upper(trim(p_room_code)) for update;
  select * into v_player
    from public.tycoon_players
   where id = p_player_id
     and room_id = v_room.id
     and (
       account_id = v_account_id
     );

  if not found or v_room.status <> 'active' or v_room.current_player_id <> v_player.id or v_room.turn_phase <> 'action' or v_room.pending_action is null then
    raise exception 'Cannot end turn now.';
  end if;

  perform public.tycoon_add_log(v_room.id, v_player.nickname || ' 跳过' || case when v_room.pending_action = 'buy' then '购买' else '升级' end || '。', 'skip');
  perform public.tycoon_advance_turn(v_room.id, v_player.id);
  return public.tycoon_room_bundle(v_room.code, v_player.id, p_player_key, p_account_token);
end;
$$;

drop function if exists public.tycoon_skip_action(text, uuid, text, text);

create or replace function public.tycoon_skip_action(
  p_room_code text,
  p_player_id uuid,
  p_player_key text,
  p_reason text default 'manual',
  p_account_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.tycoon_rooms%rowtype;
  v_player public.tycoon_players%rowtype;
  v_account_id uuid := public.game_account_id_from_token(p_account_token);
  v_action_text text;
begin
  select * into v_room from public.tycoon_rooms where code = upper(trim(p_room_code)) for update;
  select * into v_player
    from public.tycoon_players
   where id = p_player_id
     and room_id = v_room.id
     and (
       account_id = v_account_id
     );

  if not found or v_room.status <> 'active' or v_room.current_player_id <> v_player.id or v_room.turn_phase <> 'action' or v_room.pending_action is null then
    raise exception 'Cannot skip now.';
  end if;

  v_action_text := case when v_room.pending_action = 'buy' then '购买' else '升级' end;
  perform public.tycoon_add_log(
    v_room.id,
    case when coalesce(p_reason, '') = 'timeout' then '倒计时结束，默认跳过' else v_player.nickname || ' 跳过' end || v_action_text || '。',
    'skip'
  );
  perform public.tycoon_advance_turn(v_room.id, v_player.id);

  return public.tycoon_room_bundle(v_room.code, v_player.id, p_player_key, p_account_token);
end;
$$;

drop function if exists public.tycoon_auto_skip_action(text);

create or replace function public.tycoon_auto_skip_action(
  p_room_code text,
  p_account_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.tycoon_rooms%rowtype;
  v_player public.tycoon_players%rowtype;
  v_action_text text;
  v_account_id uuid := public.game_account_id_from_token(p_account_token);
begin
  select *
    into v_room
    from public.tycoon_rooms
   where code = upper(trim(p_room_code))
   for update;

  if not found then
    raise exception 'Room not found.';
  end if;

  if not exists (select 1 from public.tycoon_players where room_id = v_room.id and account_id = v_account_id) then
    raise exception 'Room membership required.';
  end if;

  if v_room.status = 'active'
     and v_room.turn_phase = 'action'
     and v_room.pending_action is not null
     and v_room.action_deadline is not null
     and now() >= v_room.action_deadline then
    select *
      into v_player
      from public.tycoon_players
     where id = v_room.current_player_id
       and room_id = v_room.id;

    v_action_text := case when v_room.pending_action = 'buy' then '购买' else '升级' end;
    perform public.tycoon_add_log(v_room.id, '倒计时结束，默认跳过' || v_action_text || '。', 'skip');
    perform public.tycoon_advance_turn(v_room.id, v_room.current_player_id);
  end if;

  return public.tycoon_room_bundle(v_room.code, null, null, p_account_token);
end;
$$;

drop function if exists public.tycoon_exit_game(text, uuid, text);

create or replace function public.tycoon_exit_game(
  p_room_code text,
  p_player_id uuid,
  p_player_key text,
  p_account_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.tycoon_rooms%rowtype;
  v_player public.tycoon_players%rowtype;
  v_account_id uuid := public.game_account_id_from_token(p_account_token);
  v_was_current boolean;
  v_present_count integer;
begin
  select * into v_room from public.tycoon_rooms where code = upper(trim(p_room_code)) for update;
  select * into v_player
    from public.tycoon_players
   where id = p_player_id
     and room_id = v_room.id
     and (
       account_id = v_account_id
     )
   for update;

  if not found then
    raise exception 'Player not found.';
  end if;

  if v_room.status not in ('lobby', 'active') then
    raise exception 'Cannot exit this room now.';
  end if;

  v_was_current := v_room.current_player_id = v_player.id;
  perform public.tycoon_bankrupt_player(v_room.id, v_player.id, '玩家主动退出。');

  if v_room.status = 'lobby' then
    select count(*)
      into v_present_count
      from public.tycoon_players
     where room_id = v_room.id
       and status <> 'bankrupt';

    if v_present_count = 0 then
      update public.tycoon_rooms
         set status = 'closed',
             turn_phase = 'closed',
             current_player_id = null,
             pending_action = null,
             action_cell_index = null,
             action_deadline = null,
             updated_at = now()
       where id = v_room.id;
      perform public.tycoon_add_log(v_room.id, '房间已无人，自动关闭。', 'host');
    end if;
  elsif v_room.status = 'active' and v_was_current then
    perform public.tycoon_advance_turn(v_room.id, v_player.id);
  else
    perform public.tycoon_finish_if_needed(v_room.id);
  end if;

  return public.tycoon_room_bundle(v_room.code, v_player.id, p_player_key, p_account_token);
end;
$$;

drop function if exists public.tycoon_remove_player(text, uuid, text, uuid);

create or replace function public.tycoon_remove_player(
  p_room_code text,
  p_player_id uuid,
  p_player_key text,
  p_target_player_id uuid,
  p_account_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.tycoon_rooms%rowtype;
  v_player public.tycoon_players%rowtype;
  v_target public.tycoon_players%rowtype;
  v_account_id uuid := public.game_account_id_from_token(p_account_token);
  v_was_current boolean;
begin
  select * into v_room from public.tycoon_rooms where code = upper(trim(p_room_code)) for update;
  select * into v_player
    from public.tycoon_players
   where id = p_player_id
     and room_id = v_room.id
     and (
       account_id = v_account_id
     );

  if not found or v_room.host_player_id <> v_player.id then
    raise exception 'Only host can remove players.';
  end if;

  if v_room.status not in ('lobby', 'active') then
    raise exception 'Cannot remove players now.';
  end if;

  select *
    into v_target
    from public.tycoon_players
   where id = p_target_player_id
     and room_id = v_room.id
   for update;

  if not found or v_target.id = v_player.id or v_target.status = 'bankrupt' then
    raise exception 'Cannot remove this player.';
  end if;

  v_was_current := v_room.current_player_id = v_target.id;
  perform public.tycoon_bankrupt_player(v_room.id, v_target.id, '被房主移除。');

  if v_room.status = 'active' and v_was_current then
    perform public.tycoon_advance_turn(v_room.id, v_target.id);
  else
    perform public.tycoon_finish_if_needed(v_room.id);
  end if;

  return public.tycoon_room_bundle(v_room.code, v_player.id, p_player_key, p_account_token);
end;
$$;

drop function if exists public.tycoon_restart_room(text, uuid, text);

create or replace function public.tycoon_restart_room(
  p_room_code text,
  p_player_id uuid,
  p_player_key text,
  p_account_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.tycoon_rooms%rowtype;
  v_player public.tycoon_players%rowtype;
  v_account_id uuid := public.game_account_id_from_token(p_account_token);
begin
  select * into v_room from public.tycoon_rooms where code = upper(trim(p_room_code)) for update;
  select * into v_player
    from public.tycoon_players
   where id = p_player_id
     and room_id = v_room.id
     and (
       account_id = v_account_id
     );

  if not found or v_room.host_player_id <> v_player.id then
    raise exception 'Only host can restart.';
  end if;

  update public.tycoon_players
     set status = case when status = 'bankrupt' then 'bankrupt' else 'waiting' end,
         cash = 200000,
         position = 0,
         updated_at = now()
   where room_id = v_room.id;

  update public.tycoon_properties
     set owner_player_id = null,
         level = 0
   where room_id = v_room.id;

  delete from public.tycoon_logs where room_id = v_room.id;
  delete from public.tycoon_messages where room_id = v_room.id;

  update public.tycoon_rooms
     set status = 'lobby',
         current_turn = 1,
         current_player_id = null,
         turn_phase = 'roll',
         last_dice = null,
         pending_action = null,
         action_cell_index = null,
         action_deadline = null,
         final_results = null,
         updated_at = now()
   where id = v_room.id;

  perform public.tycoon_add_log(v_room.id, '房主重开了游戏。', 'host');
  return public.tycoon_room_bundle(v_room.code, v_player.id, p_player_key, p_account_token);
end;
$$;

drop function if exists public.tycoon_close_room(text, uuid, text);

create or replace function public.tycoon_close_room(
  p_room_code text,
  p_player_id uuid,
  p_player_key text,
  p_account_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.tycoon_rooms%rowtype;
  v_player public.tycoon_players%rowtype;
  v_account_id uuid := public.game_account_id_from_token(p_account_token);
begin
  select * into v_room from public.tycoon_rooms where code = upper(trim(p_room_code)) for update;
  select * into v_player
    from public.tycoon_players
   where id = p_player_id
     and room_id = v_room.id
     and (
       account_id = v_account_id
     );

  if not found or v_room.host_player_id <> v_player.id then
    raise exception 'Only host can close.';
  end if;

  delete from public.tycoon_messages where room_id = v_room.id;

  update public.tycoon_rooms
     set status = 'closed',
         turn_phase = 'closed',
         current_player_id = null,
         pending_action = null,
         action_cell_index = null,
         action_deadline = null,
         updated_at = now()
   where id = v_room.id;

  perform public.tycoon_add_log(v_room.id, '房主解散了房间。', 'host');
  return public.tycoon_room_bundle(v_room.code, v_player.id, p_player_key, p_account_token);
end;
$$;

drop function if exists public.tycoon_send_message(text, uuid, text, text);

create or replace function public.tycoon_send_message(
  p_room_code text,
  p_player_id uuid,
  p_player_key text,
  p_content text,
  p_account_token text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room public.tycoon_rooms%rowtype;
  v_player public.tycoon_players%rowtype;
  v_account_id uuid := public.game_account_id_from_token(p_account_token);
  v_content text;
begin
  v_content := left(btrim(p_content), 180);
  if v_content = '' then
    raise exception 'Message is required.';
  end if;

  select * into v_room from public.tycoon_rooms where code = upper(trim(p_room_code));
  select * into v_player
    from public.tycoon_players
   where id = p_player_id
     and room_id = v_room.id
     and (
       account_id = v_account_id
     );

  if not found or v_room.status in ('finished', 'closed') or v_player.status = 'bankrupt' then
    raise exception 'Cannot chat now.';
  end if;

  insert into public.tycoon_messages (room_id, player_id, nickname, content)
  values (v_room.id, v_player.id, v_player.nickname, v_content);

  delete from public.tycoon_messages old_messages
   where old_messages.room_id = v_room.id
     and old_messages.id not in (
       select id
         from public.tycoon_messages
        where room_id = v_room.id
        order by created_at desc
        limit 40
     );

  return public.tycoon_room_bundle(v_room.code, v_player.id, p_player_key, p_account_token);
end;
$$;

drop function if exists public.account_bind_records(jsonb, jsonb);

create or replace function public.account_bind_records(
  p_account_token text,
  p_qa_players jsonb default '[]'::jsonb,
  p_tycoon_players jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_account_id uuid := public.game_account_id_from_token(p_account_token);
  v_item jsonb;
  v_player_id uuid;
  v_room_code text;
  v_player_key text;
  v_rows integer;
  v_qa_bound integer := 0;
  v_tycoon_bound integer := 0;
begin
  if v_account_id is null then
    raise exception 'Login required.';
  end if;

  if jsonb_typeof(coalesce(p_qa_players, '[]'::jsonb)) <> 'array'
     or jsonb_typeof(coalesce(p_tycoon_players, '[]'::jsonb)) <> 'array' then
    raise exception 'Binding payload must be arrays.';
  end if;

  for v_item in
    select value
      from jsonb_array_elements(coalesce(p_qa_players, '[]'::jsonb))
  loop
    begin
      v_player_id := nullif(coalesce(v_item ->> 'playerId', v_item ->> 'player_id'), '')::uuid;
    exception
      when invalid_text_representation then
        continue;
    end;

    v_room_code := upper(btrim(coalesce(v_item ->> 'roomCode', v_item ->> 'room_code', '')));
    v_player_key := btrim(coalesce(v_item ->> 'playerKey', v_item ->> 'player_key', ''));

    if v_player_id is null or v_room_code = '' or v_player_key = '' then
      continue;
    end if;

    update public.qa_players p
       set account_id = v_account_id
      from public.qa_rooms r
     where p.id = v_player_id
       and p.room_id = r.id
       and r.code = v_room_code
       and p.player_key = v_player_key
       and (p.account_id is null or p.account_id = v_account_id);

    get diagnostics v_rows = row_count;
    v_qa_bound := v_qa_bound + v_rows;
  end loop;

  for v_item in
    select value
      from jsonb_array_elements(coalesce(p_tycoon_players, '[]'::jsonb))
  loop
    begin
      v_player_id := nullif(coalesce(v_item ->> 'playerId', v_item ->> 'player_id'), '')::uuid;
    exception
      when invalid_text_representation then
        continue;
    end;

    v_room_code := upper(btrim(coalesce(v_item ->> 'roomCode', v_item ->> 'room_code', '')));
    v_player_key := btrim(coalesce(v_item ->> 'playerKey', v_item ->> 'player_key', ''));

    if v_player_id is null or v_room_code = '' or v_player_key = '' then
      continue;
    end if;

    update public.tycoon_players p
       set account_id = v_account_id,
           updated_at = now()
      from public.tycoon_rooms r
     where p.id = v_player_id
       and p.room_id = r.id
       and r.code = v_room_code
       and p.player_key = v_player_key
       and (p.account_id is null or p.account_id = v_account_id);

    get diagnostics v_rows = row_count;
    v_tycoon_bound := v_tycoon_bound + v_rows;
  end loop;

  return jsonb_build_object(
    'qaBound', v_qa_bound,
    'tycoonBound', v_tycoon_bound
  );
end;
$$;

drop function if exists public.account_get_records();

create or replace function public.account_get_records(
  p_account_token text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_account_id uuid := public.game_account_id_from_token(p_account_token);
begin
  if v_account_id is null then
    raise exception 'Login required.';
  end if;

  return jsonb_build_object(
    'qa', coalesce((
      select jsonb_agg(qa_rows.item order by qa_rows.sort_at desc)
        from (
          select
            greatest(coalesce(p.submitted_at, p.created_at), r.created_at) as sort_at,
            jsonb_build_object(
              'roomId', r.id,
              'roomCode', r.code,
              'playerId', p.id,
              'nickname', p.nickname,
              'questionCount', case
                when jsonb_typeof(r.questions) = 'array'
                 and jsonb_array_length(r.questions) between 1 and 100
                then jsonb_array_length(r.questions)
                else 100
              end,
              'submittedAt', p.submitted_at,
              'answerCount', (
                select count(*)
                  from public.qa_answers a
                 where a.player_id = p.id
                   and btrim(a.content) <> ''
              ),
              'createdAt', r.created_at,
              'joinedAt', p.created_at
            ) as item
          from public.qa_rooms r
          left join public.qa_players p on p.room_id = r.id and p.account_id = v_account_id
          where r.owner_account_id = v_account_id or p.account_id = v_account_id
          order by greatest(coalesce(p.submitted_at, p.created_at), r.created_at) desc
          limit 80
        ) qa_rows
    ), '[]'::jsonb),
    'tycoon', coalesce((
      select jsonb_agg(tycoon_rows.item order by tycoon_rows.sort_at desc)
        from (
          select
            greatest(r.updated_at, p.updated_at, p.created_at) as sort_at,
            jsonb_build_object(
              'roomId', r.id,
              'roomCode', r.code,
              'playerId', p.id,
              'nickname', p.nickname,
              'status', r.status,
              'playerStatus', p.status,
              'cash', p.cash,
              'isHost', r.host_player_id = p.id,
              'victoryMode', r.victory_mode,
              'currentTurn', r.current_turn,
              'finalWinner', r.final_results ->> 'winnerName',
              'createdAt', r.created_at,
              'joinedAt', p.created_at
            ) as item
          from public.tycoon_players p
          join public.tycoon_rooms r on r.id = p.room_id
          where p.account_id = v_account_id
          order by greatest(r.updated_at, p.updated_at, p.created_at) desc
          limit 80
        ) tycoon_rows
    ), '[]'::jsonb),
    'spin', coalesce((select jsonb_agg(jsonb_build_object(
      'roomCode', r.code, 'title', r.title, 'mode', r.mode,
      'isHost', r.owner_account_id = v_account_id, 'joinedAt', m.joined_at)
      order by r.updated_at desc) from public.spin_members m
      join public.spin_rooms r on r.id = m.room_id where m.account_id = v_account_id), '[]'::jsonb)

  );
end;
$$;

revoke execute on function public.account_session_payload(public.game_accounts) from public, anon, authenticated;
revoke execute on function public.game_account_id_from_token(text) from public, anon, authenticated;
grant execute on function public.account_bind_records(text, jsonb, jsonb) to anon, authenticated;
grant execute on function public.account_get_records(text) to anon, authenticated;

revoke execute on function public.tycoon_default_map() from public, anon, authenticated;
revoke execute on function public.tycoon_add_log(uuid, text, text) from public, anon, authenticated;
revoke execute on function public.tycoon_room_bundle(text, uuid, text, text) from public, anon, authenticated;
revoke execute on function public.tycoon_build_final_results(uuid) from public, anon, authenticated;
revoke execute on function public.tycoon_finish_if_needed(uuid) from public, anon, authenticated;
revoke execute on function public.tycoon_bankrupt_player(uuid, uuid, text) from public, anon, authenticated;
revoke execute on function public.tycoon_advance_turn(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.tycoon_pick_color_id(uuid, integer, uuid) from public, anon, authenticated;

grant execute on function public.tycoon_create_room(text, text, text, integer, integer, text) to anon, authenticated;
grant execute on function public.tycoon_get_room(text, uuid, text, text) to anon, authenticated;
grant execute on function public.tycoon_join_room(text, text, text, integer, text) to anon, authenticated;
grant execute on function public.tycoon_update_player_color(text, uuid, text, integer, text) to anon, authenticated;
grant execute on function public.tycoon_start_game(text, uuid, text, text) to anon, authenticated;
grant execute on function public.tycoon_roll_dice(text, uuid, text, text) to anon, authenticated;
grant execute on function public.tycoon_buy_property(text, uuid, text, text) to anon, authenticated;
grant execute on function public.tycoon_upgrade_property(text, uuid, text, text) to anon, authenticated;
grant execute on function public.tycoon_end_turn(text, uuid, text, text) to anon, authenticated;
grant execute on function public.tycoon_skip_action(text, uuid, text, text, text) to anon, authenticated;
grant execute on function public.tycoon_auto_skip_action(text, text) to anon, authenticated;
grant execute on function public.tycoon_exit_game(text, uuid, text, text) to anon, authenticated;
grant execute on function public.tycoon_remove_player(text, uuid, text, uuid, text) to anon, authenticated;
grant execute on function public.tycoon_restart_room(text, uuid, text, text) to anon, authenticated;
grant execute on function public.tycoon_close_room(text, uuid, text, text) to anon, authenticated;
grant execute on function public.tycoon_send_message(text, uuid, text, text, text) to anon, authenticated;

-- What’s Next? Account-owned rooms and append-only draw history.
create table if not exists public.spin_rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  owner_account_id uuid not null references public.game_accounts(id),
  title text not null check (char_length(title) between 1 and 60),
  options text[] not null check (cardinality(options) between 2 and 50),
  mode text not null check (mode in ('shared','individual')),
  version bigint not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists spin_rooms_owner_idx on public.spin_rooms(owner_account_id);
create table if not exists public.spin_members (
  room_id uuid not null references public.spin_rooms(id) on delete cascade,
  account_id uuid not null references public.game_accounts(id),
  joined_at timestamptz not null default now(),
  primary key(room_id, account_id)
);
create index if not exists spin_members_account_idx on public.spin_members(account_id, joined_at desc);
create table if not exists public.spin_draws (
  id bigint generated always as identity primary key,
  room_id uuid not null references public.spin_rooms(id) on delete cascade,
  account_id uuid not null references public.game_accounts(id),
  request_id uuid not null,
  actor_name text not null,
  mode text not null check (mode in ('shared','individual')),
  options_snapshot text[] not null,
  result_index integer not null,
  result text not null,
  started_at timestamptz not null,
  ends_at timestamptz not null,
  unique(room_id, account_id, request_id),
  check(result_index >= 0 and result_index < cardinality(options_snapshot))
);
create index if not exists spin_draws_room_history_idx on public.spin_draws(room_id, id desc);
create index if not exists spin_draws_room_active_idx on public.spin_draws(room_id, ends_at desc);
create index if not exists spin_draws_member_idx on public.spin_draws(room_id, account_id, id desc);
alter table public.spin_rooms enable row level security;
alter table public.spin_members enable row level security;
alter table public.spin_draws enable row level security;
revoke all on public.spin_rooms, public.spin_members, public.spin_draws from public, anon, authenticated;
revoke all on sequence public.spin_draws_id_seq from public, anon, authenticated;

create or replace function public.spin_validate_options(p_options text[])
returns text[] language plpgsql set search_path = public as $$
declare v_options text[];
begin
  if p_options is null or cardinality(p_options) not between 2 and 50 then
    raise exception 'Use 2 to 50 options.';
  end if;
  select array_agg(btrim(value) order by ordinality) into v_options
    from unnest(p_options) with ordinality as x(value, ordinality);
  if exists(select 1 from unnest(v_options) v where v is null or char_length(v) not between 1 and 60) then
    raise exception 'Each option must contain 1 to 60 characters.';
  end if;
  if (select count(distinct v) from unnest(v_options) v) <> cardinality(v_options) then
    raise exception 'Options must be unique.';
  end if;
  return v_options;
end;
$$;
create or replace function public.spin_draw_json(p_draw public.spin_draws)
returns jsonb language sql stable set search_path = public as $$
  select jsonb_build_object('id', p_draw.id::text, 'accountId', p_draw.account_id,
    'actor', p_draw.actor_name, 'mode', p_draw.mode, 'options', p_draw.options_snapshot,
    'index', p_draw.result_index, 'result', p_draw.result,
    'startedAt', p_draw.started_at, 'endsAt', p_draw.ends_at);
$$;

create or replace function public.spin_get_room(p_room_code text, p_account_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_account uuid := public.game_account_id_from_token(p_account_token); v_room public.spin_rooms%rowtype;
begin
  select * into v_room from public.spin_rooms where code = upper(btrim(p_room_code));
  if not found then raise exception 'Room not found.'; end if;
  if not exists(select 1 from public.spin_members where room_id = v_room.id and account_id = v_account) then
    return jsonb_build_object('room',jsonb_build_object('code',v_room.code,'title',v_room.title),'isMember',false);
  end if;
  return jsonb_build_object('room', jsonb_build_object('code',v_room.code,'title',v_room.title,
    'options',v_room.options,'mode',v_room.mode,'version',v_room.version,
    'isHost',v_room.owner_account_id = v_account), 'isMember',true,'serverNow',clock_timestamp(),
    'members',(select jsonb_agg(a.display_name order by m.joined_at) from public.spin_members m
      join public.game_accounts a on a.id = m.account_id where m.room_id = v_room.id),
    'activeUntil',(select max(ends_at) from public.spin_draws where room_id = v_room.id),
    'lastShared',(select public.spin_draw_json(d) from public.spin_draws d where room_id = v_room.id and mode='shared' order by id desc limit 1),
    'lastPersonal',(select public.spin_draw_json(d) from public.spin_draws d where room_id = v_room.id and account_id=v_account and mode='individual' order by id desc limit 1),
    'history',coalesce((select jsonb_agg(public.spin_draw_json(d) order by d.id desc)
      from (select * from public.spin_draws where room_id=v_room.id order by id desc limit 25) d),'[]'::jsonb));
end;
$$;
create or replace function public.spin_create_room(p_title text,p_options text[],p_mode text,p_account_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_account uuid := public.game_account_id_from_token(p_account_token); v_code text; v_id uuid;
  v_options text[] := public.spin_validate_options(p_options); v_attempts integer := 0;
begin
  if p_title is null or char_length(btrim(p_title)) not between 1 and 60 then raise exception 'Room title is required (1 to 60 characters).'; end if;
  if p_mode is null or p_mode not in ('shared','individual') then raise exception 'Invalid mode.'; end if;
  loop
    v_attempts := v_attempts + 1;
    v_code := upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));
    begin
      insert into public.spin_rooms(code,owner_account_id,title,options,mode)
      values(v_code,v_account,btrim(p_title),v_options,p_mode) returning id into v_id;
      exit;
    exception when unique_violation then if v_attempts >= 8 then raise; end if;
    end;
  end loop;
  insert into public.spin_members(room_id,account_id) values(v_id,v_account);
  return public.spin_get_room(v_code,p_account_token);
end;
$$;
create or replace function public.spin_join_room(p_room_code text,p_account_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_account uuid := public.game_account_id_from_token(p_account_token); v_room uuid;
begin
  select id into v_room from public.spin_rooms where code=upper(btrim(p_room_code));
  if not found then raise exception 'Room not found.'; end if;
  insert into public.spin_members(room_id,account_id) values(v_room,v_account) on conflict do nothing;
  return public.spin_get_room(p_room_code,p_account_token);
end;
$$;
create or replace function public.spin_update_room(p_room_code text,p_title text,p_options text[],p_mode text,p_version bigint,p_account_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_account uuid := public.game_account_id_from_token(p_account_token); v_room public.spin_rooms%rowtype;
  v_options text[] := public.spin_validate_options(p_options);
begin
  select * into v_room from public.spin_rooms where code=upper(btrim(p_room_code)) for update;
  if not found then raise exception 'Room not found.'; end if;
  if v_room.owner_account_id <> v_account then raise exception 'Only host can edit.'; end if;
  if p_version is distinct from v_room.version then raise exception 'Room changed. Reload before saving.'; end if;
  if exists(select 1 from public.spin_draws where room_id=v_room.id and ends_at > clock_timestamp()) then raise exception 'Spin in progress.'; end if;
  if p_title is null or char_length(btrim(p_title)) not between 1 and 60 then raise exception 'Room title is required (1 to 60 characters).'; end if;
  if p_mode is null or p_mode not in ('shared','individual') then raise exception 'Invalid mode.'; end if;
  update public.spin_rooms set title=btrim(p_title), options=v_options, mode=p_mode,
    version=version+1,updated_at=now() where id=v_room.id;
  return public.spin_get_room(p_room_code,p_account_token);
end;
$$;
create or replace function public.spin_draw(p_room_code text,p_request_id uuid,p_account_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_account uuid := public.game_account_id_from_token(p_account_token); v_room public.spin_rooms%rowtype;
  v_draw public.spin_draws%rowtype; v_now timestamptz; v_index integer; v_name text;
begin
  if p_request_id is null then raise exception 'Request id required.'; end if;
  select * into v_room from public.spin_rooms where code=upper(btrim(p_room_code)) for update;
  if not found then raise exception 'Room not found.'; end if;
  if not exists(select 1 from public.spin_members where room_id=v_room.id and account_id=v_account) then raise exception 'Room membership required.'; end if;
  select * into v_draw from public.spin_draws where room_id=v_room.id and account_id=v_account and request_id=p_request_id;
  if found then return jsonb_build_object('draw',public.spin_draw_json(v_draw),'serverNow',clock_timestamp()); end if;
  v_now := clock_timestamp();
  if exists(select 1 from public.spin_draws where room_id=v_room.id and ends_at>v_now
    and (v_room.mode='shared' or account_id=v_account)) then raise exception 'Spin in progress.'; end if;
  v_index := floor(random()*cardinality(v_room.options))::integer;
  select display_name into v_name from public.game_accounts where id=v_account;
  insert into public.spin_draws(room_id,account_id,request_id,actor_name,mode,options_snapshot,result_index,result,started_at,ends_at)
  values(v_room.id,v_account,p_request_id,v_name,v_room.mode,v_room.options,v_index,v_room.options[v_index+1],v_now,v_now+interval '4 seconds') returning * into v_draw;
  update public.spin_rooms set updated_at=v_now where id=v_room.id;
  return jsonb_build_object('draw',public.spin_draw_json(v_draw),'serverNow',clock_timestamp());
end;
$$;
create or replace function public.spin_get_history(p_room_code text,p_account_token text,p_before_id bigint default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_account uuid := public.game_account_id_from_token(p_account_token); v_room uuid;
begin
  select r.id into v_room from public.spin_rooms r join public.spin_members m on m.room_id=r.id
    where r.code=upper(btrim(p_room_code)) and m.account_id=v_account;
  if v_room is null then raise exception 'Room membership required.'; end if;
  return coalesce((select jsonb_agg(public.spin_draw_json(d) order by d.id desc)
    from (select * from public.spin_draws where room_id=v_room and (p_before_id is null or id<p_before_id) order by id desc limit 25) d),'[]'::jsonb);
end;
$$;
revoke execute on function public.spin_validate_options(text[]) from public,anon,authenticated;
revoke execute on function public.spin_draw_json(public.spin_draws) from public,anon,authenticated;
revoke execute on function public.spin_get_room(text,text),public.spin_create_room(text,text[],text,text),
  public.spin_join_room(text,text),public.spin_update_room(text,text,text[],text,bigint,text),
  public.spin_draw(text,uuid,text),public.spin_get_history(text,text,bigint) from public;
grant execute on function public.spin_get_room(text,text),public.spin_create_room(text,text[],text,text),
  public.spin_join_room(text,text),public.spin_update_room(text,text,text[],text,bigint,text),
  public.spin_draw(text,uuid,text),public.spin_get_history(text,text,bigint) to anon,authenticated;

-- Account recovery limits apply only to recovery; regular password login stays available.
create table if not exists public.game_account_recoveries (
  account_id uuid primary key references public.game_accounts(id) on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz not null
);
alter table public.game_account_recoveries enable row level security;
revoke all on public.game_account_recoveries from public, anon, authenticated;

create or replace function public.account_update_profile(p_account_token text, p_display_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid := public.game_account_id_from_token(p_account_token); v_name text := btrim(coalesce(p_display_name,''));
begin
  if char_length(v_name) not between 1 and 20 then raise exception 'Invalid display name.'; end if;
  update public.game_accounts set display_name=v_name, updated_at=now() where id=v_id;
  update public.qa_players set nickname=v_name where account_id=v_id;
  update public.tycoon_players set nickname=v_name, updated_at=now() where account_id=v_id;
  -- Submitted QA names, finished rankings, chat/log text and draw actors are snapshots.
  return public.account_refresh(p_account_token);
end;
$$;

create or replace function public.account_recovery_question(p_username text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_question integer;
begin
  select security_question into v_question from public.game_accounts where username_key=lower(btrim(p_username));
  -- The same response shape is used for missing accounts. Answers are never returned.
  return jsonb_build_object('questionId',coalesce(v_question,1));
end;
$$;

create or replace function public.account_verify_recovery(p_username text, p_answer text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_account public.game_accounts%rowtype; v_answer text := lower(btrim(coalesce(p_answer,'')));
  v_failures integer; v_token text; v_hash text; v_now timestamptz := clock_timestamp();
begin
  if char_length(v_answer) not between 1 and 100 then
    return jsonb_build_object('ok',false,'error','Recovery verification failed.');
  end if;
  select * into v_account from public.game_accounts where username_key=lower(btrim(p_username)) for update;
  if not found or v_account.security_answer_hash is null then
    -- Match the password hash work of a real account without creating recovery state.
    perform extensions.crypt(encode(extensions.digest(v_answer,'sha256'),'hex'),extensions.gen_salt('bf',10));
    return jsonb_build_object('ok',false,'error','Recovery verification failed.');
  end if;
  v_now := clock_timestamp();
  if v_account.recovery_blocked_until > v_now then
    return jsonb_build_object('ok',false,'error','Recovery temporarily blocked.',
      'retryAfter',ceil(extract(epoch from v_account.recovery_blocked_until-v_now)));
  end if;
  v_hash := extensions.crypt(encode(extensions.digest(v_answer,'sha256'),'hex'),v_account.security_answer_hash);
  if v_hash <> v_account.security_answer_hash then
    v_failures := case when v_account.recovery_window_started_at > v_now-interval '15 minutes'
      then v_account.recovery_failures+1 else 1 end;
    update public.game_accounts set recovery_failures=v_failures,
      recovery_window_started_at=case when v_failures=1 then v_now else recovery_window_started_at end,
      recovery_blocked_until=case when v_failures>=5 then v_now+interval '15 minutes' else null end
      where id=v_account.id;
    -- Returning a failure instead of raising preserves the attempt counter on commit.
    return jsonb_build_object('ok',false,'error',case when v_failures>=5 then 'Recovery temporarily blocked.' else 'Recovery verification failed.' end,
      'retryAfter',case when v_failures>=5 then 900 else 0 end);
  end if;
  v_token := encode(extensions.gen_random_bytes(32),'hex');
  insert into public.game_account_recoveries(account_id,token_hash,expires_at)
    values(v_account.id,encode(extensions.digest(v_token,'sha256'),'hex'),v_now+interval '10 minutes')
    on conflict(account_id) do update set token_hash=excluded.token_hash,expires_at=excluded.expires_at;
  update public.game_accounts set recovery_failures=0,recovery_window_started_at=null,recovery_blocked_until=null where id=v_account.id;
  return jsonb_build_object('ok',true,'resetToken',v_token,'expiresAt',v_now+interval '10 minutes');
end;
$$;

create or replace function public.account_reset_password(p_reset_token text, p_password text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_hash text := encode(extensions.digest(coalesce(p_reset_token,''),'sha256'),'hex');
begin
  if char_length(coalesce(p_password,'')) < 4 then raise exception 'Password is too short.'; end if;
  if octet_length(p_password) > 72 then raise exception 'Password is too long.'; end if;
  select account_id into v_id from public.game_account_recoveries where token_hash=v_hash;
  if v_id is null then return jsonb_build_object('ok',false,'error','Reset token expired or used.'); end if;
  -- All recovery writes lock the account first so concurrent verification/reset cannot race.
  perform 1 from public.game_accounts where id=v_id for update;
  delete from public.game_account_recoveries where account_id=v_id and token_hash=v_hash and expires_at>clock_timestamp();
  if not found then return jsonb_build_object('ok',false,'error','Reset token expired or used.'); end if;
  update public.game_accounts set password_hash=extensions.crypt(p_password,extensions.gen_salt('bf',10)),
    updated_at=now(),recovery_failures=0,recovery_window_started_at=null,recovery_blocked_until=null where id=v_id;
  delete from public.game_account_sessions where account_id=v_id;
  return jsonb_build_object('ok',true);
end;
$$;
revoke execute on function public.account_update_profile(text,text),public.account_recovery_question(text),
  public.account_verify_recovery(text,text),public.account_reset_password(text,text) from public;
grant execute on function public.account_update_profile(text,text),public.account_recovery_question(text),
  public.account_verify_recovery(text,text),public.account_reset_password(text,text) to anon,authenticated;

-- Board Games: private rooms, immutable match participants, full event replays.
create table if not exists public.board_rooms (
  code text primary key, kind text not null check(kind in ('gomoku','xiangqi')), title text not null check(char_length(title) between 1 and 60),
  owner_id uuid not null references public.game_accounts(id), guest_id uuid references public.game_accounts(id),
  bot_level text check(bot_level in ('easy','normal','hard')), host_ready boolean not null default false, guest_ready boolean not null default false,
  host_seen timestamptz not null default now(), guest_seen timestamptz, host_side integer not null default 0,
  round integer not null default 0, revision integer not null default 0, match_id uuid,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  check(guest_id is null or (bot_level is null and guest_id<>owner_id))
);
create index if not exists board_rooms_owner_idx on public.board_rooms(owner_id,updated_at desc);
create index if not exists board_rooms_guest_idx on public.board_rooms(guest_id,updated_at desc) where guest_id is not null;
create table if not exists public.board_matches (
  id uuid primary key default gen_random_uuid(), room_code text not null references public.board_rooms(code), kind text not null,
  round integer not null, accounts uuid[] not null, players jsonb not null, state jsonb not null, pending jsonb,
  events jsonb not null default '[]', status text not null default 'active' check(status in ('active','finished','interrupted')),
  created_at timestamptz not null default now(), ended_at timestamptz, unique(room_code,round)
);
create index if not exists board_matches_accounts_idx on public.board_matches using gin(accounts);
create index if not exists board_matches_room_idx on public.board_matches(room_code,created_at desc);
create table if not exists public.board_requests (
  room_code text not null references public.board_rooms(code), account_id uuid not null references public.game_accounts(id),
  request_id uuid not null, primary key(room_code,account_id,request_id)
);
alter table public.board_rooms enable row level security;
alter table public.board_matches enable row level security;
alter table public.board_requests enable row level security;
revoke all on public.board_rooms,public.board_matches,public.board_requests from public,anon,authenticated;

create or replace function public.board_initial(p_kind text) returns jsonb language plpgsql immutable set search_path=public as $$
declare b integer[]; row_p integer[]:=array[5,4,3,2,1,2,3,4,5]; i integer;
begin
 if p_kind not in ('gomoku','xiangqi') or p_kind is null then raise exception 'Invalid game.';end if;
 b:=array_fill(0,array[case when p_kind='gomoku' then 225 else 90 end]);
 if p_kind='xiangqi' then
  for i in 0..8 loop b[i+1]:=-row_p[i+1];b[82+i]:=row_p[i+1];end loop;
  foreach i in array array[1,7] loop b[19+i]:=-6;b[64+i]:=6;end loop;
  foreach i in array array[0,2,4,6,8] loop b[28+i]:=-7;b[55+i]:=7;end loop;
 end if;
 return jsonb_build_object('kind',p_kind,'board',b,'turn',1,'moves','[]'::jsonb,'positions',jsonb_build_array(jsonb_build_object('key',array_to_string(b,',')||':1','actor',0,'check',false)),'result',null);
end;$$;
create or replace function public.board_pseudo(b integer[],f integer,t integer) returns boolean language plpgsql immutable set search_path=public as $$
declare p integer; s integer; x integer; y integer; tx integer; ty integer; dx integer; dy integer; blocks integer:=0; step integer; i integer; palace boolean;
begin
 if f is null or t is null or f<0 or f>=90 or t<0 or t>=90 or f=t then return false;end if;
 p:=b[f+1];s:=sign(p);if s=0 or sign(b[t+1])=s then return false;end if;
 x:=f%9;y:=f/9;tx:=t%9;ty:=t/9;dx:=tx-x;dy:=ty-y;
 palace:=tx between 3 and 5 and (case when s=1 then ty>=7 else ty<=2 end);
 if dx=0 or dy=0 then step:=case when dx=0 then sign(dy)*9 else sign(dx) end;i:=f+step;
  while i<>t loop if b[i+1]<>0 then blocks:=blocks+1;end if;i:=i+step;end loop;
 end if;
 case abs(p)
 when 1 then return (abs(b[t+1])=1 and dx=0 and blocks=0) or (palace and abs(dx)+abs(dy)=1);
 when 2 then return palace and abs(dx)=1 and abs(dy)=1;
 when 3 then return abs(dx)=2 and abs(dy)=2 and (case when s=1 then ty>=5 else ty<=4 end) and b[f+dy/2*9+dx/2+1]=0;
 when 4 then return (abs(dx)=2 and abs(dy)=1 and b[f+sign(dx)::integer+1]=0) or (abs(dx)=1 and abs(dy)=2 and b[f+sign(dy)::integer*9+1]=0);
 when 5 then return (dx=0 or dy=0) and blocks=0;
 when 6 then return (dx=0 or dy=0) and blocks=(case when b[t+1]=0 then 0 else 1 end);
 when 7 then return (dx=0 and dy=-s) or ((case when s=1 then y<=4 else y>=5 end) and dy=0 and abs(dx)=1);
 else return false;end case;
end;$$;
create or replace function public.board_checked(b integer[],s integer) returns boolean language plpgsql immutable set search_path=public as $$
declare k integer:=array_position(b,s)-1;i integer;
begin
 if k is null then return true;end if;
 for i in 0..89 loop if sign(b[i+1])=-s and public.board_pseudo(b,i,k) then return true;end if;end loop;return false;
end;$$;
create or replace function public.board_legal(p_kind text,b integer[],s integer,f integer,t integer) returns boolean language plpgsql immutable set search_path=public as $$
declare n integer[]:=b;
begin
 if t is null or t<0 or t>=cardinality(b) then return false;end if;
 if p_kind='gomoku' then return b[t+1]=0;end if;
 if f is null or f<0 or f>=90 or sign(b[f+1])<>s or abs(b[t+1])=1 or not public.board_pseudo(b,f,t) then return false;end if;
 n[t+1]:=n[f+1];n[f+1]:=0;return not public.board_checked(n,s);
end;$$;
create or replace function public.board_has_move(b integer[],s integer) returns boolean language plpgsql immutable set search_path=public as $$
declare f integer;t integer;
begin
 for f in 0..89 loop if sign(b[f+1])=s then for t in 0..89 loop if public.board_legal('xiangqi',b,s,f,t) then return true;end if;end loop;end if;end loop;return false;
end;$$;
create or replace function public.board_play(p_state jsonb,p_move jsonb) returns jsonb language plpgsql immutable set search_path=public as $$
declare v_kind text:=p_state->>'kind';b integer[];s integer:=(p_state->>'turn')::integer; f integer; t integer;
 entry jsonb;pos jsonb;list jsonb;res jsonb:='null';n integer;dx integer;dy integer;dir integer;x integer;y integer;a integer;c integer;k text;first_ord bigint;red boolean;black boolean;
begin
 if jsonb_typeof(p_move->'to') is distinct from 'number' or (v_kind='xiangqi' and jsonb_typeof(p_move->'from') is distinct from 'number') then raise exception 'Illegal move.';end if;
 f:=case when v_kind='gomoku' then -1 else (p_move->>'from')::integer end;t:=(p_move->>'to')::integer;
 select array_agg(value::integer order by ordinality) into b from jsonb_array_elements_text(p_state->'board') with ordinality;
 if p_state->'result'<>'null'::jsonb or not public.board_legal(v_kind,b,s,f,t) then raise exception 'Illegal move.';end if;
 entry:=jsonb_build_object('from',f,'to',t,'side',s,'piece',case when v_kind='gomoku' then s else b[f+1] end,'captured',b[t+1]);
 b[t+1]:=(entry->>'piece')::integer;if f>=0 then b[f+1]:=0;end if;
 k:=array_to_string(b,',')||':'||(-s)::text;
 pos:=(p_state->'positions')||jsonb_build_array(jsonb_build_object('key',k,'actor',s,'check',v_kind='xiangqi' and public.board_checked(b,-s)));
 list:=(p_state->'moves')||jsonb_build_array(entry);
 if v_kind='gomoku' then
  x:=t%15;y:=t/15;
  for dx,dy in select * from (values(1,0),(0,1),(1,1),(1,-1)) as d(x,y) loop
   n:=1;foreach dir in array array[-1,1] loop a:=x+dx*dir;c:=y+dy*dir;
    while a between 0 and 14 and c between 0 and 14 and b[c*15+a+1]=s loop n:=n+1;a:=a+dx*dir;c:=c+dy*dir;end loop;
   end loop;if n>=5 then res:=jsonb_build_object('winner',s,'reason','five');exit;end if;
  end loop;
  if res='null' and not 0=any(b) then res:=jsonb_build_object('winner',0,'reason','full');end if;
 else
  if not public.board_has_move(b,-s) then res:=jsonb_build_object('winner',s,'reason',case when public.board_checked(b,-s) then 'checkmate' else 'stalemate' end);
  elsif (select count(*) from jsonb_array_elements(pos) q where q->>'key'=k)>=3 then
   select min(ord) into first_ord from(select ordinality ord from jsonb_array_elements(pos) with ordinality where value->>'key'=k order by ordinality desc limit 3) q;
   select bool_and((value->>'check')::boolean) filter(where (value->>'actor')::integer=1),bool_and((value->>'check')::boolean) filter(where (value->>'actor')::integer=-1)
    into red,black from jsonb_array_elements(pos) with ordinality where ordinality>first_ord;
   res:=jsonb_build_object('winner',case when red<>black then case when red then -1 else 1 end else 0 end,'reason',case when red<>black then 'perpetual-check' else 'repetition' end);
  end if;
 end if;
 return jsonb_build_object('kind',v_kind,'board',b,'turn',-s,'moves',list,'positions',pos,'result',res);
end;$$;
create or replace function public.board_undo(p_state jsonb,p_side integer) returns jsonb language plpgsql immutable set search_path=public as $$
declare cut integer;next jsonb:=public.board_initial(p_state->>'kind'); b integer[];m jsonb;list jsonb;pos jsonb;
begin
 if p_state->'result'<>'null'::jsonb then raise exception 'Game ended.';end if;
 select max(ordinality)::integer-1 into cut from jsonb_array_elements(p_state->'moves') with ordinality where (value->>'side')::integer=p_side;
 if cut is null then raise exception 'Nothing to undo.';end if;
 select coalesce(jsonb_agg(value order by ordinality),'[]') into list from jsonb_array_elements(p_state->'moves') with ordinality where ordinality<=cut;
 select coalesce(jsonb_agg(value order by ordinality),'[]') into pos from jsonb_array_elements(p_state->'positions') with ordinality where ordinality<=cut+1;
 select array_agg(value::integer order by ordinality) into b from jsonb_array_elements_text(next->'board') with ordinality;
 for m in select value from jsonb_array_elements(list) loop if (m->>'from')::integer>=0 then b[(m->>'from')::integer+1]:=0;end if;b[(m->>'to')::integer+1]:=(m->>'piece')::integer;end loop;
 return jsonb_build_object('kind',p_state->>'kind','board',b,'turn',p_side,'moves',list,'positions',pos,'result',null);
end;$$;
create or replace function public.board_match_json(m public.board_matches) returns jsonb language sql stable set search_path=public as $$
 select jsonb_build_object('id',m.id,'roomCode',m.room_code,'kind',m.kind,'round',m.round,'players',m.players,'state',m.state,'pending',m.pending,'events',m.events,'status',m.status,'createdAt',m.created_at,'endedAt',m.ended_at);
$$;
create or replace function public.board_members_json(r public.board_rooms) returns jsonb language sql stable set search_path=public as $$
 select jsonb_build_array(jsonb_build_object('accountId',r.owner_id,'name',(select display_name from public.game_accounts where id=r.owner_id),'bot',false,'ready',r.host_ready,'seen',r.host_seen),
 case when r.guest_id is not null then jsonb_build_object('accountId',r.guest_id,'name',(select display_name from public.game_accounts where id=r.guest_id),'bot',false,'ready',r.guest_ready,'seen',r.guest_seen)
 when r.bot_level is not null then jsonb_build_object('accountId',null,'name','电脑','bot',true,'level',r.bot_level,'ready',true) else null end);
$$;
create or replace function public.board_room_json(r public.board_rooms,a uuid) returns jsonb language plpgsql set search_path=public as $$
begin
 if a<>r.owner_id and a is distinct from r.guest_id then return jsonb_build_object('isMember',false,'room',jsonb_build_object('code',r.code,'kind',r.kind,'title',r.title,'revision',r.revision,'joinable',r.guest_id is null and r.bot_level is null));end if;
 return jsonb_build_object('isMember',true,'serverNow',clock_timestamp(),'room',jsonb_build_object('code',r.code,'kind',r.kind,'title',r.title,'revision',r.revision,'round',r.round,'hostSide',r.host_side,'ownerId',r.owner_id,'guestId',r.guest_id,'botLevel',r.bot_level,'hostReady',r.host_ready,'guestReady',r.guest_ready,'hostSeen',r.host_seen,'guestSeen',r.guest_seen,'matchId',r.match_id,'isHost',a=r.owner_id,'members',public.board_members_json(r)),
 'match',(select public.board_match_json(m) from public.board_matches m where id=r.match_id));
end;$$;
create or replace function public.board_create_room(p_kind text,p_title text,p_account_token text,p_bot_level text default null) returns jsonb language plpgsql security definer set search_path=public as $$
declare a uuid:=public.game_account_id_from_token(p_account_token);r public.board_rooms%rowtype;c text;attempt integer:=0;
begin
 if p_kind is null or p_kind not in ('gomoku','xiangqi') or char_length(btrim(coalesce(p_title,''))) not between 1 and 60 then raise exception 'Invalid room.';end if;
 if p_bot_level is not null and p_bot_level not in ('easy','normal','hard') then raise exception 'Invalid difficulty.';end if;
 loop attempt:=attempt+1;c:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));
  begin insert into public.board_rooms(code,kind,title,owner_id,bot_level)values(c,p_kind,btrim(p_title),a,p_bot_level) returning * into r;exit;
  exception when unique_violation then if attempt>=8 then raise;end if;end;
 end loop;return public.board_room_json(r,a);
end;$$;
create or replace function public.board_get_room(p_room_code text,p_account_token text) returns jsonb language plpgsql security definer set search_path=public as $$
declare a uuid:=public.game_account_id_from_token(p_account_token);r public.board_rooms%rowtype;
begin
 update public.board_rooms set host_seen=case when owner_id=a then clock_timestamp() else host_seen end,guest_seen=case when guest_id=a then clock_timestamp() else guest_seen end
 where code=upper(btrim(p_room_code)) and (owner_id=a or guest_id=a);
 select * into r from public.board_rooms where code=upper(btrim(p_room_code));if not found then raise exception 'Room not found.';end if;return public.board_room_json(r,a);
end;$$;
create or replace function public.board_get_match(p_match_id uuid,p_account_token text) returns jsonb language plpgsql security definer set search_path=public as $$
declare a uuid:=public.game_account_id_from_token(p_account_token);m public.board_matches%rowtype;
begin select * into m from public.board_matches where id=p_match_id and accounts @> array[a];if not found then raise exception 'Membership required.';end if;return public.board_match_json(m);end;$$;
create or replace function public.board_records(p_account_token text) returns jsonb language plpgsql security definer set search_path=public as $$
declare a uuid:=public.game_account_id_from_token(p_account_token);
begin return jsonb_build_object('rooms',coalesce((select jsonb_agg(jsonb_build_object('code',code,'title',title,'kind',kind) order by updated_at desc)from public.board_rooms where owner_id=a or guest_id=a),'[]'),
 'matches',coalesce((select jsonb_agg(jsonb_build_object('id',id,'roomCode',room_code,'kind',kind,'round',round,'status',status,'result',state->'result','players',players,'createdAt',created_at)order by created_at desc)from public.board_matches where accounts @> array[a]),'[]'));end;$$;
create or replace function public.board_action(p_room_code text,p_action text,p_data jsonb,p_revision integer,p_request_id uuid,p_account_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare a uuid:=public.game_account_id_from_token(p_account_token);r public.board_rooms%rowtype;m public.board_matches%rowtype;
 active boolean;actor jsonb;bot jsonb;who jsonb;evt jsonb;players jsonb;pending jsonb;last_seen timestamptz;before_count integer;accept boolean;
begin
 select * into r from public.board_rooms where code=upper(btrim(p_room_code)) for update;if not found then raise exception 'Room not found.';end if;
 if p_action is null or (p_action<>'join' and a<>r.owner_id and a is distinct from r.guest_id) then raise exception 'Membership required.';end if;
 if p_request_id is null then raise exception 'Request id required.';end if;
 if exists(select 1 from public.board_requests where room_code=r.code and account_id=a and request_id=p_request_id) then return public.board_room_json(r,a);end if;
 if p_revision is distinct from r.revision then raise exception 'Room changed.';end if;
 select * into m from public.board_matches where id=r.match_id;active:=coalesce(m.status='active',false);
 if p_action='join' then
  if a<>r.owner_id and a is distinct from r.guest_id then
   if r.guest_id is not null or r.bot_level is not null or active then raise exception 'Room full.';end if;
   r.guest_id:=a;r.guest_ready:=false;r.guest_seen:=clock_timestamp();
  end if;
 elsif p_action='ready' then
  if active then raise exception 'Game active.';end if;
  if a=r.owner_id then r.host_ready:=coalesce((p_data->>'ready')::boolean,false);else r.guest_ready:=coalesce((p_data->>'ready')::boolean,false);end if;
 elsif p_action='bot' then
  if a<>r.owner_id then raise exception 'Only host.';end if;if active or r.guest_id is not null then raise exception 'Seat occupied.';end if;
  if p_data->>'level' is not null and p_data->>'level' not in ('easy','normal','hard') then raise exception 'Invalid difficulty.';end if;
  r.bot_level:=p_data->>'level';r.host_ready:=false;
 elsif p_action='start' then
  if a<>r.owner_id then raise exception 'Only host.';end if;
  if active or not r.host_ready or (r.bot_level is null and (r.guest_id is null or not r.guest_ready)) then raise exception 'Players not ready.';end if;
  r.host_side:=case when r.round>0 then -r.host_side when random()<0.5 then 1 else -1 end;r.round:=r.round+1;
  select jsonb_agg(value||jsonb_build_object('side',case when ordinality=1 then r.host_side else -r.host_side end)order by ordinality)into players from jsonb_array_elements(public.board_members_json(r))with ordinality;
  insert into public.board_matches(room_code,kind,round,accounts,players,state)values(r.code,r.kind,r.round,array_remove(array[r.owner_id,r.guest_id],null),players,public.board_initial(r.kind))returning * into m;
  r.match_id:=m.id;r.host_ready:=false;r.guest_ready:=false;
 else
  if not active then raise exception 'Game ended.';end if;
  select value into actor from jsonb_array_elements(m.players)where value->>'accountId'=a::text;
  select value into bot from jsonb_array_elements(m.players)where (value->>'bot')::boolean;
  if actor is null then raise exception 'Membership required.';end if;
  evt:=jsonb_build_object('type',p_action,'actor',(actor->>'side')::integer,'at',clock_timestamp());
  if p_action in ('move','bot_move') then
   if m.pending is not null then raise exception 'Request pending.';end if;
   who:=case when p_action='bot_move' then bot else actor end;
   if who is null or (p_action='bot_move' and a<>r.owner_id) or who->>'side'<>m.state->>'turn' then raise exception 'Not your turn.';end if;
   m.state:=public.board_play(m.state,p_data->'move');evt:=evt||jsonb_build_object('actor',(who->>'side')::integer,'move',m.state->'moves'->-1);
  elsif p_action='resign' then m.state:=jsonb_set(m.state,'{result}',jsonb_build_object('winner',-(actor->>'side')::integer,'reason','resign'));
  elsif p_action in ('undo','draw') then
   if m.pending is not null then raise exception 'Request pending.';end if;
   if p_action='undo' then perform public.board_undo(m.state,(actor->>'side')::integer);end if;
   if bot is not null then
    if p_action='undo' then before_count:=jsonb_array_length(m.state->'moves');m.state:=public.board_undo(m.state,(actor->>'side')::integer);evt:=evt||jsonb_build_object('count',before_count-jsonb_array_length(m.state->'moves'));
    else m.state:=jsonb_set(m.state,'{result}',jsonb_build_object('winner',0,'reason','agreed'));end if;
   else m.pending:=jsonb_build_object('type',p_action,'by',(actor->>'side')::integer);end if;
  elsif p_action='reply' then
   if m.pending is null or m.pending->>'by'=actor->>'side' then raise exception 'No request.';end if;
   accept:=coalesce((p_data->>'accept')::boolean,false);evt:=evt||jsonb_build_object('request',m.pending,'accept',accept);
   if accept then
    if m.pending->>'type'='undo' then before_count:=jsonb_array_length(m.state->'moves');m.state:=public.board_undo(m.state,(m.pending->>'by')::integer);evt:=evt||jsonb_build_object('count',before_count-jsonb_array_length(m.state->'moves'));
    else m.state:=jsonb_set(m.state,'{result}',jsonb_build_object('winner',0,'reason','agreed'));end if;
   end if;m.pending:=null;
  elsif p_action='cancel' then
   if m.pending is null or m.pending->>'by'<>actor->>'side' then raise exception 'No request.';end if;m.pending:=null;
  elsif p_action='interrupt' then
   last_seen:=case when a=r.owner_id then r.guest_seen else r.host_seen end;
   if bot is not null or last_seen is null or clock_timestamp()-last_seen<interval '5 minutes' then raise exception 'Opponent recently online.';end if;
   m.state:=jsonb_set(m.state,'{result}',jsonb_build_object('winner',0,'reason','interrupted'));
  else raise exception 'Invalid action.';end if;
  if m.state->'result'<>'null'::jsonb then m.status:=case when m.state->'result'->>'reason'='interrupted' then 'interrupted' else 'finished' end;m.ended_at:=clock_timestamp();m.pending:=null;end if;
  evt:=evt||jsonb_build_object('board',m.state->'board','turn',m.state->'turn','result',m.state->'result');m.events:=m.events||jsonb_build_array(evt);
  update public.board_matches set state=m.state,pending=m.pending,events=m.events,status=m.status,ended_at=m.ended_at where id=m.id;
 end if;
 update public.board_rooms set guest_id=r.guest_id,bot_level=r.bot_level,host_ready=r.host_ready,guest_ready=r.guest_ready,host_side=r.host_side,round=r.round,match_id=r.match_id,
  revision=revision+1,host_seen=case when a=owner_id then clock_timestamp() else host_seen end,guest_seen=case when a=r.guest_id then clock_timestamp() else r.guest_seen end,updated_at=clock_timestamp()where code=r.code returning * into r;
 insert into public.board_requests(room_code,account_id,request_id)values(r.code,a,p_request_id);
 return public.board_room_json(r,a);
end;$$;
-- Helpers are callable only by the owner; public clients use the authenticated RPC surface below.
do $$ declare f record; begin for f in select oid::regprocedure as signature from pg_proc where pronamespace='public'::regnamespace and proname like 'board\_%' escape '\' loop
 execute format('revoke execute on function %s from public,anon,authenticated',f.signature);end loop;end;$$;
grant execute on function public.board_create_room(text,text,text,text),public.board_get_room(text,text),public.board_get_match(uuid,text),public.board_records(text),public.board_action(text,text,jsonb,integer,uuid,text) to anon,authenticated;


-- International chess, independent authoritative validation.
create or replace function public.board_chess_attack(b integer[],t integer,who integer) returns boolean language plpgsql immutable set search_path=public as $$
declare f integer;p integer;dx integer;dy integer;ax integer;ay integer;step integer;i integer;
begin
 for f in 0..63 loop if sign(b[f+1])<>who then continue;end if;p:=abs(b[f+1]);dx:=t%8-f%8;dy:=t/8-f/8;ax:=abs(dx);ay:=abs(dy);
 if (p=1 and greatest(ax,ay)=1) or (p=5 and ax*ay=2) or (p=6 and ax=1 and dy=-who) then return true;end if;
 if (p=2 and (ax=ay or dx=0 or dy=0)) or (p=3 and (dx=0 or dy=0)) or (p=4 and ax=ay) then
  if dx=0 and dy=0 then continue;end if;step:=sign(dx)+sign(dy)*8;i:=f+step;while i<>t and b[i+1]=0 loop i:=i+step;end loop;if i=t then return true;end if;
 end if;end loop;return false;
end;$$;
create or replace function public.board_chess_checked(s jsonb,who integer) returns boolean language plpgsql immutable set search_path=public as $$
declare b integer[];k integer;
begin select array_agg(value::integer order by ordinality) into b from jsonb_array_elements_text(s->'board') with ordinality;k:=array_position(b,who)-1;return k is null or public.board_chess_attack(b,k,-who);end;$$;
create or replace function public.board_chess_apply(s jsonb,m jsonb) returns jsonb language plpgsql immutable set search_path=public as $$
declare b integer[];f integer:=(m->>'from')::integer;t integer:=(m->>'to')::integer;p integer;who integer;captured integer;castle integer:=(s->>'castling')::integer;rf integer;rt integer;mask integer;ep integer:=-1;half integer;
begin
 select array_agg(value::integer order by ordinality) into b from jsonb_array_elements_text(s->'board') with ordinality;p:=b[f+1];who:=sign(p);captured:=b[t+1];b[f+1]:=0;b[t+1]:=coalesce((m->>'promote')::integer*who,p);
 if abs(p)=6 and t=(s->>'ep')::integer and captured=0 and f%8<>t%8 then b[t+who*8+1]:=0;end if;
 if abs(p)=1 and abs(t-f)=2 then rf:=f+case when t>f then 3 else -4 end;rt:=f+case when t>f then 1 else -1 end;b[rt+1]:=b[rf+1];b[rf+1]:=0;end if;
 if abs(p)=1 then castle:=castle & case when who=1 then 12 else 3 end;end if;
 mask:=case f when 0 then 8 when 7 then 4 when 56 then 2 when 63 then 1 else 0 end;castle:=castle & ~mask;
 mask:=case t when 0 then 8 when 7 then 4 when 56 then 2 when 63 then 1 else 0 end;castle:=castle & ~mask;
 if abs(p)=6 and abs(t-f)=16 then ep:=(f+t)/2;end if;
 half:=case when abs(p)=6 or captured<>0 then 0 else (s->>'halfmove')::integer+1 end;
 return s||jsonb_build_object('board',b,'turn',-who,'castling',castle,'ep',ep,'halfmove',half);
end;$$;
create or replace function public.board_chess_legal(s jsonb,m jsonb) returns boolean language plpgsql immutable set search_path=public as $$
declare b integer[];f integer;t integer;p integer;who integer:=(s->>'turn')::integer;dx integer;dy integer;ax integer;ay integer;ok boolean:=false;promotes boolean;mask integer;rf integer;step integer;i integer;
begin
 if jsonb_typeof(m->'from') is distinct from 'number' or jsonb_typeof(m->'to') is distinct from 'number' then return false;end if;
 f:=(m->>'from')::integer;t:=(m->>'to')::integer;if f<0 or f>63 or t<0 or t>63 or f=t then return false;end if;
 select array_agg(value::integer order by ordinality) into b from jsonb_array_elements_text(s->'board') with ordinality;p:=abs(b[f+1]);
 if sign(b[f+1])<>who or sign(b[t+1])=who or abs(b[t+1])=1 then return false;end if;
 dx:=t%8-f%8;dy:=t/8-f/8;ax:=abs(dx);ay:=abs(dy);promotes:=p=6 and t/8=case when who=1 then 0 else 7 end;
 if promotes then if coalesce(m->>'promote','') not in ('2','3','4','5') then return false;end if;
 elsif m->>'promote' is not null then return false;end if;
 if p=6 then
  ok:=dx=0 and b[t+1]=0 and (dy=-who or (dy=-2*who and f/8=case when who=1 then 6 else 1 end and b[f-who*8+1]=0));
  if ax=1 and dy=-who then ok:=b[t+1]<>0 or (t=(s->>'ep')::integer and b[t+1]=0 and b[t+who*8+1]=-who*6);end if;
 elsif p=5 then ok:=ax*ay=2;
 elsif p=1 then
  ok:=greatest(ax,ay)=1;
  if dy=0 and ax=2 and f=(case when who=1 then 60 else 4 end) then
   mask:=case when who=1 then case when dx>0 then 1 else 2 end else case when dx>0 then 4 else 8 end end;rf:=f+case when dx>0 then 3 else -4 end;step:=sign(dx);
   ok:=((s->>'castling')::integer & mask)<>0 and b[rf+1]=who*3 and not public.board_chess_checked(s,who);
   i:=f+step;while i<>rf loop if b[i+1]<>0 then ok:=false;end if;i:=i+step;end loop;
   if public.board_chess_attack(b,f+step,-who) or public.board_chess_attack(b,t,-who) then ok:=false;end if;
  end if;
 elsif (p=2 and (ax=ay or dx=0 or dy=0)) or (p=3 and (dx=0 or dy=0)) or (p=4 and ax=ay) then
  ok:=true;step:=sign(dx)+sign(dy)*8;i:=f+step;while i<>t loop if b[i+1]<>0 then ok:=false;exit;end if;i:=i+step;end loop;
 end if;
 return coalesce(ok,false) and not public.board_chess_checked(public.board_chess_apply(s,m),who);
end;$$;
create or replace function public.board_chess_key(s jsonb) returns text language plpgsql immutable set search_path=public as $$
declare ep integer:=-1;candidate integer:=(s->>'ep')::integer;who integer:=(s->>'turn')::integer;b text;
begin
 if candidate>=0 and (public.board_chess_legal(s,jsonb_build_object('from',candidate+who*8-1,'to',candidate)) or public.board_chess_legal(s,jsonb_build_object('from',candidate+who*8+1,'to',candidate))) then ep:=candidate;end if;
 select string_agg(value,',' order by ordinality) into b from jsonb_array_elements_text(s->'board') with ordinality;
 return b||':'||who||':'||(s->>'castling')||':'||ep;
end;$$;
create or replace function public.board_chess_initial() returns jsonb language plpgsql immutable set search_path=public as $$
declare row_p integer[]:=array[3,5,4,2,1,4,5,3];b integer[]:=array_fill(0,array[64]);i integer;s jsonb;
begin for i in 0..7 loop b[i+1]:=-row_p[i+1];b[i+9]:=-6;b[i+49]:=6;b[i+57]:=row_p[i+1];end loop;
 s:=jsonb_build_object('kind','chess','board',b,'turn',1,'castling',15,'ep',-1,'halfmove',0,'moves','[]'::jsonb,'positions','[]'::jsonb,'result',null);
 return jsonb_set(s,'{positions}',jsonb_build_array(public.board_chess_key(s)));end;$$;
create or replace function public.board_chess_has_move(s jsonb) returns boolean language plpgsql immutable set search_path=public as $$
declare f integer;t integer;m jsonb;
begin for f in 0..63 loop if sign((s->'board'->>f)::integer)<>(s->>'turn')::integer then continue;end if;for t in 0..63 loop
 m:=jsonb_build_object('from',f,'to',t);if abs((s->'board'->>f)::integer)=6 and t/8 in (0,7) then m:=m||jsonb_build_object('promote',2);end if;
 if public.board_chess_legal(s,m) then return true;end if;end loop;end loop;return false;end;$$;
create or replace function public.board_chess_play(s jsonb,m jsonb) returns jsonb language plpgsql immutable set search_path=public as $$
declare n jsonb;entry jsonb;positions jsonb;f integer:=(m->>'from')::integer;t integer:=(m->>'to')::integer;who integer:=(s->>'turn')::integer;p integer;captured integer;res jsonb:='null';total integer;minor integer;bishops integer;colors integer;
begin
 if s->'result'<>'null'::jsonb or not public.board_chess_legal(s,m) then raise exception 'Illegal move.';end if;n:=public.board_chess_apply(s,m);p:=(s->'board'->>f)::integer;captured:=(s->'board'->>t)::integer;
 if captured=0 and abs(p)=6 and t=(s->>'ep')::integer then captured:=-who*6;end if;
 entry:=m||jsonb_build_object('side',who,'piece',p,'captured',captured,'before',jsonb_build_object('board',s->'board','turn',who,'castling',s->'castling','ep',s->'ep','halfmove',s->'halfmove'));
 positions:=(s->'positions')||jsonb_build_array(public.board_chess_key(n));n:=n||jsonb_build_object('moves',(s->'moves')||jsonb_build_array(entry),'positions',positions);
 select count(*),count(*) filter(where abs(value::integer) in (4,5)),count(*) filter(where abs(value::integer)=4),count(distinct ((ordinality-1)%8+(ordinality-1)/8)%2) into total,minor,bishops,colors
 from jsonb_array_elements_text(n->'board') with ordinality where abs(value::integer)>1;
 if not public.board_chess_has_move(n) then res:=jsonb_build_object('winner',case when public.board_chess_checked(n,-who) then who else 0 end,'reason',case when public.board_chess_checked(n,-who) then 'checkmate' else 'stalemate-draw' end);
 elsif total=0 or (total=1 and minor=1) or (total=bishops and colors=1) then res:=jsonb_build_object('winner',0,'reason','insufficient');
 elsif (select count(*) from jsonb_array_elements_text(positions) where value=public.board_chess_key(n))>=3 then res:=jsonb_build_object('winner',0,'reason','repetition');
 elsif (n->>'halfmove')::integer>=100 then res:=jsonb_build_object('winner',0,'reason','fifty-moves');end if;
 return jsonb_set(n,'{result}',res);
end;$$;
create or replace function public.board_expanded_undo(s jsonb,who integer) returns jsonb language plpgsql immutable set search_path=public as $$
declare cut integer;list jsonb;positions jsonb;n jsonb;
begin
 if s->>'kind'='flight' then raise exception 'Undo not available.';end if;
 if s->>'kind' not in ('chess','halma') then return public.board_undo(s,who);end if;
 if s->'result'<>'null'::jsonb then raise exception 'Game ended.';end if;
 select max(ordinality)::integer-1 into cut from jsonb_array_elements(s->'moves') with ordinality where (value->>'side')::integer=who;
 if cut is null then raise exception 'Nothing to undo.';end if;
 select coalesce(jsonb_agg(value order by ordinality),'[]') into list from jsonb_array_elements(s->'moves') with ordinality where ordinality<=cut;
 n:=s||(s->'moves'->cut->'before')||jsonb_build_object('moves',list,'result',null);
 if s->>'kind'='chess' then select coalesce(jsonb_agg(value order by ordinality),'[]') into positions from jsonb_array_elements(s->'positions') with ordinality where ordinality<=cut+1;n:=jsonb_set(n,'{positions}',positions);end if;return n;
end;$$;

create table if not exists public.board_halma_geometry (id integer primary key,q integer not null,r integer not null,camp integer not null,unique(q,r));
insert into public.board_halma_geometry values (0,0,-4,-1),(1,1,-4,-1),(2,2,-4,-1),(3,3,-4,-1),(4,4,-4,-1),(5,-1,-3,-1),(6,0,-3,-1),(7,1,-3,-1),(8,2,-3,-1),(9,3,-3,-1),(10,4,-3,-1),(11,-2,-2,-1),(12,-1,-2,-1),(13,0,-2,-1),(14,1,-2,-1),(15,2,-2,-1),(16,3,-2,-1),(17,4,-2,-1),(18,-3,-1,-1),(19,-2,-1,-1),(20,-1,-1,-1),(21,0,-1,-1),(22,1,-1,-1),(23,2,-1,-1),(24,3,-1,-1),(25,4,-1,-1),(26,-4,0,-1),(27,-3,0,-1),(28,-2,0,-1),(29,-1,0,-1),(30,0,0,-1),(31,1,0,-1),(32,2,0,-1),(33,3,0,-1),(34,4,0,-1),(35,-4,1,-1),(36,-3,1,-1),(37,-2,1,-1),(38,-1,1,-1),(39,0,1,-1),(40,1,1,-1),(41,2,1,-1),(42,3,1,-1),(43,-4,2,-1),(44,-3,2,-1),(45,-2,2,-1),(46,-1,2,-1),(47,0,2,-1),(48,1,2,-1),(49,2,2,-1),(50,-4,3,-1),(51,-3,3,-1),(52,-2,3,-1),(53,-1,3,-1),(54,0,3,-1),(55,1,3,-1),(56,-4,4,-1),(57,-3,4,-1),(58,-2,4,-1),(59,-1,4,-1),(60,0,4,-1),(61,1,-5,0),(62,2,-5,0),(63,3,-5,0),(64,4,-5,0),(65,2,-6,0),(66,3,-6,0),(67,4,-6,0),(68,3,-7,0),(69,4,-7,0),(70,4,-8,0),(71,5,-4,1),(72,5,-3,1),(73,5,-2,1),(74,5,-1,1),(75,6,-4,1),(76,6,-3,1),(77,6,-2,1),(78,7,-4,1),(79,7,-3,1),(80,8,-4,1),(81,4,1,2),(82,3,2,2),(83,2,3,2),(84,1,4,2),(85,4,2,2),(86,3,3,2),(87,2,4,2),(88,4,3,2),(89,3,4,2),(90,4,4,2),(91,-1,5,3),(92,-2,5,3),(93,-3,5,3),(94,-4,5,3),(95,-2,6,3),(96,-3,6,3),(97,-4,6,3),(98,-3,7,3),(99,-4,7,3),(100,-4,8,3),(101,-5,4,4),(102,-5,3,4),(103,-5,2,4),(104,-5,1,4),(105,-6,4,4),(106,-6,3,4),(107,-6,2,4),(108,-7,4,4),(109,-7,3,4),(110,-8,4,4),(111,-4,-1,5),(112,-3,-2,5),(113,-2,-3,5),(114,-1,-4,5),(115,-4,-2,5),(116,-3,-3,5),(117,-2,-4,5),(118,-4,-3,5),(119,-3,-4,5),(120,-4,-4,5) on conflict(id) do nothing;
alter table public.board_halma_geometry enable row level security;
revoke all on public.board_halma_geometry from public,anon,authenticated;

create or replace function public.board_halma_camps(n integer) returns integer[] language sql immutable set search_path=public as $$
 select case n when 2 then array[0,3] when 3 then array[0,2,4] when 4 then array[0,1,3,4] when 6 then array[0,1,2,3,4,5] end;
$$;
create or replace function public.board_initial_game(kind text,n integer default 2,first_turn integer default 1) returns jsonb language plpgsql set search_path=public as $$
declare b integer[];order_c integer[];c integer;i integer;
begin
 if kind in ('gomoku','xiangqi') then return public.board_initial(kind);end if;if kind='chess' then return public.board_chess_initial();end if;
 if kind='halma' then order_c:=public.board_halma_camps(n);if order_c is null then raise exception 'Invalid seats.';end if;
 select array_agg(coalesce(array_position(order_c,camp),0) order by id) into b from public.board_halma_geometry;
 elsif kind='flight' and n between 2 and 4 then b:=array_fill(-1,array[n*4]);else raise exception 'Invalid game.';end if;
 if first_turn<1 or first_turn>n then raise exception 'Invalid turn.';end if;
 return jsonb_build_object('kind',kind,'count',n,'board',b,'turn',first_turn,'turnSerial',0,'rankings','[]'::jsonb,'dice',null,'moves','[]'::jsonb,'positions','[]'::jsonb,'result',null);
end;$$;
create or replace function public.board_race_next(s jsonb) returns jsonb language plpgsql immutable set search_path=public as $$
declare i integer;who integer;n integer:=(s->>'count')::integer;
begin for i in 1..n loop who:=((s->>'turn')::integer-1+i)%n+1;if not (s->'rankings') @> jsonb_build_array(who) then return s||jsonb_build_object('turn',who,'turnSerial',(s->>'turnSerial')::integer+1);end if;end loop;return s;end;$$;
create or replace function public.board_race_finish(s jsonb) returns jsonb language plpgsql set search_path=public as $$
declare who integer:=(s->>'turn')::integer;n integer:=(s->>'count')::integer;ranks jsonb:=s->'rankings';done boolean;dest integer;i integer;
begin
 if s->>'kind'='flight' then select bool_and((s->'board'->>g)::integer=57) into done from generate_series((who-1)*4,who*4-1) g;
 else dest:=(public.board_halma_camps(n))[who];select bool_and((s->'board'->>id)::integer=who) into done from public.board_halma_geometry where camp=(dest+3)%6;end if;
 if done and not ranks @> jsonb_build_array(who) then ranks:=ranks||jsonb_build_array(who);end if;
 if jsonb_array_length(ranks)=n-1 then for i in 1..n loop if not ranks @> jsonb_build_array(i) then ranks:=ranks||jsonb_build_array(i);exit;end if;end loop;
 s:=jsonb_set(s,'{result}',jsonb_build_object('winner',(ranks->>0)::integer,'reason','ranked'));end if;
 return jsonb_set(s,'{rankings}',ranks);
end;$$;
create or replace function public.board_halma_legal(s jsonb,m jsonb) returns boolean language plpgsql set search_path=public as $$
declare path integer[];b integer[];f integer;t integer;i integer;seen integer[];q1 integer;r1 integer;q2 integer;r2 integer;dx integer;dy integer;distance integer;mid integer;
begin
 if jsonb_typeof(m->'path') is distinct from 'array' then return false;end if;
 select array_agg(value::integer order by ordinality) into path from jsonb_array_elements_text(m->'path') with ordinality;
 if cardinality(path)<2 or cardinality(path)>121 or cardinality(path) is null then return false;end if;
 if exists(select 1 from unnest(path) p where p<0 or p>120 or p is null) then return false;end if;
 select array_agg(value::integer order by ordinality) into b from jsonb_array_elements_text(s->'board') with ordinality;f:=path[1];seen:=array[f];
 if b[f+1]<>(s->>'turn')::integer then return false;end if;b[f+1]:=0;
 for i in 2..cardinality(path) loop t:=path[i];if b[t+1]<>0 or t=any(seen) then return false;end if;
 select q,r into q1,r1 from public.board_halma_geometry where id=f;select q,r into q2,r2 from public.board_halma_geometry where id=t;dx:=q2-q1;dy:=r2-r1;distance:=greatest(abs(dx),abs(dy),abs(dx+dy));
 if distance=1 then if cardinality(path)<>2 then return false;end if;
 elsif distance=2 and (dx=0 or dy=0 or dx=-dy) then select id into mid from public.board_halma_geometry where q=q1+dx/2 and r=r1+dy/2;if mid is null or b[mid+1]=0 then return false;end if;
 else return false;end if;seen:=array_append(seen,t);f:=t;
 end loop;return true;
end;$$;
create or replace function public.board_halma_has_move(s jsonb) returns boolean language plpgsql set search_path=public as $$
declare f record;dx integer;dy integer;t integer;mid integer;
begin
 for f in select * from public.board_halma_geometry where (s->'board'->>id)::integer=(s->>'turn')::integer loop
 for dx,dy in select * from(values(1,0),(-1,0),(0,1),(0,-1),(1,-1),(-1,1))d(x,y) loop
 select id into t from public.board_halma_geometry where q=f.q+dx and r=f.r+dy;
 if t is not null and (s->'board'->>t)::integer=0 then return true;end if;mid:=t;
 select id into t from public.board_halma_geometry where q=f.q+dx*2 and r=f.r+dy*2;
 if t is not null and mid is not null and (s->'board'->>mid)::integer<>0 and (s->'board'->>t)::integer=0 then return true;end if;
 end loop;end loop;return false;
end;$$;
create or replace function public.board_flight_can_move(s jsonb) returns boolean language sql immutable set search_path=public as $$
 select s->>'dice' is not null and exists(select 1 from generate_series(((s->>'turn')::integer-1)*4,(s->>'turn')::integer*4-1) i where (s->'board'->>i)::integer between 0 and 56 or ((s->'board'->>i)::integer=-1 and (s->>'dice')::integer=6));
$$;
create or replace function public.board_flight_roll(s jsonb,die integer) returns jsonb language plpgsql immutable set search_path=public as $$
begin if s->>'kind'<>'flight' or s->'result'<>'null'::jsonb or s->>'dice' is not null or die not between 1 and 6 or die is null then raise exception 'Illegal roll.';end if;
 s:=jsonb_set(s,'{dice}',to_jsonb(die));if not public.board_flight_can_move(s) then s:=public.board_race_next(jsonb_set(s,'{dice}','null'));end if;return s;end;$$;
create or replace function public.board_race_play(s jsonb,m jsonb) returns jsonb language plpgsql set search_path=public as $$
declare who integer:=(s->>'turn')::integer;b integer[];entry jsonb;f integer;t integer;i integer;token integer;die integer;stops integer[];captures integer[]:='{}';stop integer;global integer;side integer;p integer;before jsonb;
begin
 if s->'result'<>'null'::jsonb then raise exception 'Game ended.';end if;select array_agg(value::integer order by ordinality) into b from jsonb_array_elements_text(s->'board') with ordinality;
 if s->>'kind'='halma' then
  before:=jsonb_build_object('board',s->'board','turn',who,'rankings',s->'rankings','turnSerial',s->'turnSerial');
  if m->'pass'='true'::jsonb then if public.board_halma_has_move(s) then raise exception 'Illegal move.';end if;entry:=jsonb_build_object('side',who,'pass',true,'before',before);
  else if not public.board_halma_legal(s,m) then raise exception 'Illegal move.';end if;f:=(m->'path'->>0)::integer;t:=(m->'path'->>-1)::integer;b[f+1]:=0;b[t+1]:=who;entry:=jsonb_build_object('side',who,'from',f,'to',t,'path',m->'path','before',before);end if;
  s:=public.board_race_finish(jsonb_set(s,'{board}',to_jsonb(b)));if s->'result'='null'::jsonb then s:=public.board_race_next(s);end if;
 else
  if jsonb_typeof(m->'token') is distinct from 'number' or s->>'dice' is null then raise exception 'Illegal move.';end if;token:=(m->>'token')::integer;if token<0 or token>3 then raise exception 'Illegal move.';end if;
  die:=(s->>'dice')::integer;i:=(who-1)*4+token;f:=b[i+1];if f=57 or (f=-1 and die<>6) then raise exception 'Illegal move.';end if;
  t:=case when f=-1 then 0 else f+die end;if t>57 then t:=114-t;end if;stops:=array[t];
  if f<>-1 and t<52 then if t=18 then t:=30;stops:=array_append(stops,t);
   elsif t%4=2 and t+4<52 then t:=t+4;stops:=array_append(stops,t);if t=18 then t:=30;stops:=array_append(stops,t);end if;end if;end if;
  foreach stop in array stops loop if stop<52 then global:=((who-1)*13+stop)%52;
   for i in 0..cardinality(b)-1 loop side:=i/4+1;p:=b[i+1];if side<>who and p between 0 and 51 and ((side-1)*13+p)%52=global then b[i+1]:=-1;captures:=array_append(captures,i);end if;end loop;
  end if;end loop;
  b[(who-1)*4+token+1]:=t;entry:=jsonb_build_object('side',who,'token',token,'from',f,'to',t,'dice',die,'stops',stops,'captures',captures);
  s:=public.board_race_finish(s||jsonb_build_object('board',b,'dice',null));if s->'result'='null'::jsonb and (die<>6 or (s->'rankings') @> jsonb_build_array(who)) then s:=public.board_race_next(s);end if;
 end if;
 return jsonb_set(s,'{moves}',(s->'moves')||jsonb_build_array(entry));
end;$$;
create or replace function public.board_play_game(s jsonb,m jsonb) returns jsonb language plpgsql set search_path=public as $$
begin case s->>'kind' when 'chess' then return public.board_chess_play(s,m);when 'flight','halma' then return public.board_race_play(s,m);else return public.board_play(s,m);end case;end;$$;

-- Variable seat counts and room chat, preserving first-release room/match identifiers.
alter table public.board_rooms drop constraint if exists board_rooms_kind_check;
alter table public.board_rooms add constraint board_rooms_kind_check check(kind in ('gomoku','xiangqi','chess','flight','halma'));
alter table public.board_rooms add column if not exists capacity integer not null default 2;
alter table public.board_rooms add column if not exists takeover_level text not null default 'normal';
alter table public.board_matches add column if not exists controls jsonb not null default '{}';
-- First-release two-player requests did not store an explicit voting roster.
update public.board_matches m set pending=m.pending||jsonb_build_object('required',(
 select coalesce(jsonb_agg((p->>'side')::integer),'[]'::jsonb) from jsonb_array_elements(m.players) p
 where p->>'accountId' is not null and p->>'side'<>m.pending->>'by'),'approved','[]'::jsonb)
 where m.pending is not null and not(m.pending ? 'required');
create table if not exists public.board_seats (
 room_code text not null references public.board_rooms(code),seat integer not null check(seat between 0 and 5),account_id uuid references public.game_accounts(id),
 bot_level text check(bot_level in ('easy','normal','hard')),ready boolean not null default false,last_seen timestamptz,
 primary key(room_code,seat),check(account_id is null or bot_level is null)
);
create unique index if not exists board_seats_account_unique on public.board_seats(room_code,account_id) where account_id is not null;
create index if not exists board_seats_account_idx on public.board_seats(account_id,room_code) where account_id is not null;
insert into public.board_seats(room_code,seat,account_id,bot_level,ready,last_seen)
 select code,0,owner_id,null,host_ready,host_seen from public.board_rooms on conflict do nothing;
insert into public.board_seats(room_code,seat,account_id,bot_level,ready,last_seen)
 select code,1,guest_id,bot_level,guest_ready,guest_seen from public.board_rooms on conflict do nothing;
create table if not exists public.board_messages (
 id bigint generated always as identity primary key,room_code text not null references public.board_rooms(code),account_id uuid not null references public.game_accounts(id),
 author_name text not null,body text not null check(char_length(body) between 1 and 1000),created_at timestamptz not null default clock_timestamp(),request_id uuid not null,
 unique(room_code,account_id,request_id)
);
create index if not exists board_messages_room_id_idx on public.board_messages(room_code,id desc);
alter table public.board_seats enable row level security;alter table public.board_messages enable row level security;
revoke all on public.board_seats,public.board_messages from public,anon,authenticated;
revoke all on sequence public.board_messages_id_seq from public,anon,authenticated;
create or replace function public.board_is_member(code text,a uuid) returns boolean language sql stable set search_path=public as $$select exists(select 1 from public.board_seats s where s.room_code=code and s.account_id=a);$$;
create or replace function public.board_driver(code text) returns uuid language sql volatile set search_path=public as $$select account_id from public.board_seats where room_code=code and account_id is not null and last_seen>clock_timestamp()-interval '45 seconds' order by seat limit 1;$$;
create or replace function public.board_members_json(r public.board_rooms) returns jsonb language sql stable set search_path=public as $$
 select jsonb_agg(case when s.account_id is null and s.bot_level is null then null else jsonb_build_object('seat',s.seat,'accountId',s.account_id,'name',case when s.bot_level is not null then '电脑' else a.display_name end,'bot',s.bot_level is not null,'level',s.bot_level,'ready',s.bot_level is not null or s.ready,'seen',s.last_seen)end order by s.seat)
 from public.board_seats s left join public.game_accounts a on a.id=s.account_id where s.room_code=r.code;
$$;
create or replace function public.board_match_json(m public.board_matches) returns jsonb language sql stable set search_path=public as $$
 select jsonb_build_object('id',m.id,'roomCode',m.room_code,'kind',m.kind,'round',m.round,'players',m.players,'state',m.state,'controls',m.controls,'pending',m.pending,'events',m.events,'status',m.status,'createdAt',m.created_at,'endedAt',m.ended_at);
$$;
create or replace function public.board_room_json(r public.board_rooms,a uuid) returns jsonb language plpgsql set search_path=public as $$
begin
 if not public.board_is_member(r.code,a) then return jsonb_build_object('isMember',false,'room',jsonb_build_object('code',r.code,'kind',r.kind,'title',r.title,'revision',r.revision,'capacity',r.capacity,'joinable',exists(select 1 from public.board_seats where room_code=r.code and account_id is null and bot_level is null)));end if;
 return jsonb_build_object('isMember',true,'serverNow',clock_timestamp(),'room',jsonb_build_object('code',r.code,'kind',r.kind,'title',r.title,'revision',r.revision,'round',r.round,'hostSide',r.host_side,'ownerId',r.owner_id,'guestId',r.guest_id,'botLevel',r.bot_level,'capacity',r.capacity,'takeoverLevel',r.takeover_level,'matchId',r.match_id,'isHost',a=r.owner_id,'driverId',public.board_driver(r.code),'members',public.board_members_json(r)),
 'match',(select public.board_match_json(m) from public.board_matches m where id=r.match_id));
end;$$;
drop function if exists public.board_create_room(text,text,text,text);
create or replace function public.board_create_room(p_kind text,p_title text,p_account_token text,p_bot_level text default null,p_capacity integer default 2,p_takeover_level text default 'normal') returns jsonb language plpgsql security definer set search_path=public as $$
declare a uuid:=public.game_account_id_from_token(p_account_token);r public.board_rooms%rowtype;c text;i integer;attempt integer:=0;
begin
 if p_kind is null or p_kind not in ('gomoku','xiangqi','chess','flight','halma') or char_length(btrim(coalesce(p_title,''))) not between 1 and 60 then raise exception 'Invalid room.';end if;
 if p_capacity is null or (case when p_kind='flight' then p_capacity not in (2,3,4) when p_kind='halma' then p_capacity not in (2,3,4,6) else p_capacity<>2 end) then raise exception 'Invalid seats.';end if;
 if (p_bot_level is not null and p_bot_level not in ('easy','normal','hard')) or p_takeover_level is null or p_takeover_level not in ('easy','normal','hard') then raise exception 'Invalid difficulty.';end if;
 loop attempt:=attempt+1;c:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));begin insert into public.board_rooms(code,kind,title,owner_id,bot_level,capacity,takeover_level)values(c,p_kind,btrim(p_title),a,p_bot_level,p_capacity,p_takeover_level)returning * into r;exit;exception when unique_violation then if attempt>=8 then raise;end if;end;end loop;
 for i in 0..p_capacity-1 loop insert into public.board_seats(room_code,seat,account_id,bot_level,last_seen)values(c,i,case when i=0 then a else null end,case when i=0 then null else p_bot_level end,case when i=0 then clock_timestamp() else null end);end loop;
 return public.board_room_json(r,a);
end;$$;
create or replace function public.board_get_room(p_room_code text,p_account_token text) returns jsonb language plpgsql security definer set search_path=public as $$
declare a uuid:=public.game_account_id_from_token(p_account_token);r public.board_rooms%rowtype;
begin
 update public.board_seats set last_seen=clock_timestamp()where room_code=upper(btrim(p_room_code)) and account_id=a;
 select * into r from public.board_rooms where code=upper(btrim(p_room_code));if not found then raise exception 'Room not found.';end if;return public.board_room_json(r,a);
end;$$;
create or replace function public.board_records(p_account_token text) returns jsonb language plpgsql security definer set search_path=public as $$
declare a uuid:=public.game_account_id_from_token(p_account_token);
begin return jsonb_build_object('rooms',coalesce((select jsonb_agg(jsonb_build_object('code',r.code,'title',r.title,'kind',r.kind)order by r.updated_at desc)from public.board_rooms r where public.board_is_member(r.code,a)),'[]'),
 'matches',coalesce((select jsonb_agg(jsonb_build_object('id',id,'roomCode',room_code,'kind',kind,'round',round,'status',status,'result',state->'result','rankings',coalesce(state->'rankings','[]'),'players',players,'createdAt',created_at)order by created_at desc)from public.board_matches where accounts @> array[a]),'[]'));end;$$;
create or replace function public.board_absent(m public.board_matches) returns boolean language sql volatile set search_path=public as $$
 select exists(select 1 from jsonb_array_elements(m.players) p join public.board_seats s on s.account_id=(p->>'accountId')::uuid and s.room_code=m.room_code
 where not coalesce(m.state->'rankings','[]'::jsonb) @> jsonb_build_array((p->>'side')::integer) and s.last_seen<=clock_timestamp()-interval '5 minutes');
$$;
create or replace function public.board_event(m public.board_matches,e jsonb) returns public.board_matches language plpgsql set search_path=public as $$
begin m.events:=m.events||jsonb_build_array(e||jsonb_build_object('at',clock_timestamp(),'board',m.state->'board','turn',m.state->'turn','result',m.state->'result','state',m.state-'moves'-'positions'));return m;end;$$;
create or replace function public.board_action(p_room_code text,p_action text,p_data jsonb,p_revision integer,p_request_id uuid,p_account_token text) returns jsonb language plpgsql security definer set search_path=public as $$
declare a uuid:=public.game_account_id_from_token(p_account_token);r public.board_rooms%rowtype;m public.board_matches%rowtype;seat_no integer;actor jsonb;who integer;turn integer;turn_player jsonb;evt jsonb;before_count integer;before_serial integer;die integer;players jsonb;accounts uuid[];required jsonb;target integer;target_player jsonb;control jsonb;active boolean;is_race boolean;action text:=p_action;d jsonb:=coalesce(p_data,'{}');
begin
 select * into r from public.board_rooms where code=upper(btrim(p_room_code)) for update;if not found then raise exception 'Room not found.';end if;
 if action is null or (action<>'join' and not public.board_is_member(r.code,a)) then raise exception 'Membership required.';end if;
 if p_request_id is null then raise exception 'Request id required.';end if;
 if exists(select 1 from public.board_requests where room_code=r.code and account_id=a and request_id=p_request_id) then return public.board_room_json(r,a);end if;
 if p_revision is distinct from r.revision then raise exception 'Room changed.';end if;
 select * into m from public.board_matches where id=r.match_id;active:=coalesce(m.status='active',false);is_race:=r.kind in ('flight','halma');
 if action='join' then
  if not public.board_is_member(r.code,a) then
   select seat into seat_no from public.board_seats where room_code=r.code and account_id is null and bot_level is null order by seat limit 1;if seat_no is null or active then raise exception 'Room full.';end if;
   update public.board_seats set account_id=a,ready=false,last_seen=clock_timestamp()where room_code=r.code and seat=seat_no;if seat_no=1 then r.guest_id:=a;end if;
  end if;
 elsif action='leave' then update public.board_seats set ready=false where room_code=r.code and account_id=a;
 elsif action='ready' then
  if active then raise exception 'Game active.';end if;update public.board_seats set ready=coalesce((d->>'ready')::boolean,false)where room_code=r.code and account_id=a;
 elsif action in ('bot','takeover_level') then
  if r.owner_id<>a then raise exception 'Only host.';end if;if active then raise exception 'Game active.';end if;
  if action='takeover_level' then if r.kind<>'flight' or coalesce(d->>'level','') not in ('easy','normal','hard') then raise exception 'Invalid difficulty.';end if;r.takeover_level:=d->>'level';
  else seat_no:=coalesce((d->>'seat')::integer,1);if seat_no<1 or seat_no>=r.capacity or exists(select 1 from public.board_seats where room_code=r.code and seat=seat_no and account_id is not null) then raise exception 'Seat occupied.';end if;
   if d->>'level' is not null and d->>'level' not in ('easy','normal','hard') then raise exception 'Invalid difficulty.';end if;
   update public.board_seats set bot_level=d->>'level',ready=false where room_code=r.code and seat=seat_no;if seat_no=1 then r.bot_level:=d->>'level';end if;
  end if;update public.board_seats set ready=false where room_code=r.code and seat=0;
 elsif action='start' then
  if r.owner_id<>a then raise exception 'Only host.';end if;
  if active or exists(select 1 from public.board_seats where room_code=r.code and bot_level is null and (account_id is null or not ready)) then raise exception 'Players not ready.';end if;
  r.host_side:=case when is_race then case when r.round>0 then r.host_side%r.capacity+1 else floor(random()*r.capacity)::integer+1 end when r.round>0 then -r.host_side when random()<0.5 then 1 else -1 end;r.round:=r.round+1;
  select jsonb_agg(value||jsonb_build_object('side',case when is_race then ordinality::integer when ordinality=1 then r.host_side else -r.host_side end)order by ordinality) into players from jsonb_array_elements(public.board_members_json(r))with ordinality;
  select array_agg(account_id order by seat)filter(where account_id is not null) into accounts from public.board_seats where room_code=r.code;
  insert into public.board_matches(room_code,kind,round,accounts,players,state)values(r.code,r.kind,r.round,accounts,players,public.board_initial_game(r.kind,r.capacity,case when is_race then r.host_side else 1 end))returning * into m;
  r.match_id:=m.id;update public.board_seats set ready=false where room_code=r.code and account_id is not null;
 else
  if not active then raise exception 'Game ended.';end if;
  select value into actor from jsonb_array_elements(m.players)where value->>'accountId'=a::text;if actor is null then raise exception 'Membership required.';end if;who:=(actor->>'side')::integer;
  evt:=jsonb_build_object('type',action,'actor',who);
  if m.pending is not null and action not in ('reply','cancel','resign','return') then raise exception 'Request pending.';end if;
  if action in ('move','bot_move','roll','bot_roll') then
   turn:=(m.state->>'turn')::integer;before_serial:=(m.state->>'turnSerial')::integer;select value into turn_player from jsonb_array_elements(m.players)where (value->>'side')::integer=turn;
   if action in ('bot_move','bot_roll') then
    if (not (turn_player->>'bot')::boolean and not m.controls ? turn::text) or public.board_driver(r.code) is distinct from a then raise exception 'Not your turn.';end if;
   elsif turn<>who or (turn_player->>'bot')::boolean or m.controls ? turn::text then raise exception 'Not your turn.';end if;
   evt:=evt||jsonb_build_object('actor',turn);
   if action in ('roll','bot_roll') then die:=floor(random()*6)::integer+1;m.state:=public.board_flight_roll(m.state,die);evt:=evt||jsonb_build_object('dice',die,'skipped',m.state->>'dice' is null);
   else m.state:=public.board_play_game(m.state,d->'move');evt:=evt||jsonb_build_object('move',m.state->'moves'->-1);end if;
   m:=public.board_event(m,evt);
   if coalesce((m.controls->turn::text->>'returnRequested')::boolean,false) and ((m.state->>'turn')::integer<>turn or (m.state->>'turnSerial')::integer is distinct from before_serial or m.state->'result'<>'null'::jsonb) then
    m.controls:=m.controls-turn::text;m:=public.board_event(m,jsonb_build_object('type','returned','actor',turn));end if;
  elsif action in ('takeover','return') then
   if r.kind<>'flight' or coalesce(m.state->'rankings','[]') @> jsonb_build_array(who) then raise exception 'Invalid action.';end if;
   if action='takeover' then
    target:=coalesce((d->>'side')::integer,who);select value into target_player from jsonb_array_elements(m.players)where (value->>'side')::integer=target;
    if target_player is null or (target_player->>'bot')::boolean or (m.state->'rankings') @> jsonb_build_array(target) or m.controls ? target::text then raise exception 'Invalid action.';end if;
    if target<>who and exists(select 1 from public.board_seats where room_code=r.code and account_id=(target_player->>'accountId')::uuid and last_seen>clock_timestamp()-interval '5 minutes') then raise exception 'Opponent recently online.';end if;
    m.controls:=m.controls||jsonb_build_object(target::text,jsonb_build_object('mode',case when target=who then 'manual' else 'offline' end,'level',r.takeover_level,'returnRequested',false));evt:=evt||jsonb_build_object('target',target);
   else
    if not m.controls ? who::text then raise exception 'Invalid action.';end if;
    if (m.state->>'turn')::integer=who then m.controls:=jsonb_set(m.controls,array[who::text,'returnRequested'],'true');else m.controls:=m.controls-who::text;end if;
    evt:=evt||jsonb_build_object('waiting',m.controls ? who::text);
   end if;m:=public.board_event(m,evt);
  elsif action='resign' then if is_race then raise exception 'Invalid action.';end if;m.state:=jsonb_set(m.state,'{result}',jsonb_build_object('winner',-who,'reason','resign'));m:=public.board_event(m,evt);
  elsif action in ('undo','draw','interrupt') then
   if coalesce(m.state->'rankings','[]') @> jsonb_build_array(who) then raise exception 'Invalid action.';end if;
   if action='undo' then perform public.board_expanded_undo(m.state,who);end if;if action='draw' and is_race then raise exception 'Invalid action.';end if;
   if action='interrupt' and not public.board_absent(m) then raise exception 'Opponent recently online.';end if;
   select coalesce(jsonb_agg((p->>'side')::integer),'[]') into required from jsonb_array_elements(m.players)p join public.board_seats ss on ss.room_code=r.code and ss.account_id=(p->>'accountId')::uuid
   where (p->>'side')::integer<>who and (action<>'interrupt' or (not coalesce(m.state->'rankings','[]') @> jsonb_build_array((p->>'side')::integer) and ss.last_seen>clock_timestamp()-interval '45 seconds'));
   if jsonb_array_length(required)>0 then m.pending:=jsonb_build_object('id',p_request_id,'type',action,'by',who,'required',required,'approved','[]'::jsonb);
   elsif action='undo' then before_count:=jsonb_array_length(m.state->'moves');m.state:=public.board_expanded_undo(m.state,who);evt:=evt||jsonb_build_object('count',before_count-jsonb_array_length(m.state->'moves'));
   else m.state:=jsonb_set(m.state,'{result}',jsonb_build_object('winner',0,'reason',case when action='draw' then 'agreed' else 'interrupted' end));end if;m:=public.board_event(m,evt);
  elsif action='reply' then
   if m.pending is null or (m.pending->>'by')::integer=who then raise exception 'No request.';end if;evt:=evt||jsonb_build_object('request',m.pending,'accept',coalesce((d->>'accept')::boolean,false));
   if not coalesce((d->>'accept')::boolean,false) then m.pending:=null;
   else
    if not (m.pending->'required') @> jsonb_build_array(who) or (m.pending->'approved') @> jsonb_build_array(who) then raise exception 'No request.';end if;
    m.pending:=jsonb_set(m.pending,'{approved}',(m.pending->'approved')||jsonb_build_array(who));
    if m.pending->>'type'='interrupt' and not public.board_absent(m) then m.pending:=null;evt:=evt||jsonb_build_object('cancelled',true);
    elsif (m.pending->'approved') @> (m.pending->'required') then
     if m.pending->>'type'='undo' then before_count:=jsonb_array_length(m.state->'moves');m.state:=public.board_expanded_undo(m.state,(m.pending->>'by')::integer);evt:=evt||jsonb_build_object('count',before_count-jsonb_array_length(m.state->'moves'));
     else m.state:=jsonb_set(m.state,'{result}',jsonb_build_object('winner',0,'reason',case when m.pending->>'type'='draw' then 'agreed' else 'interrupted' end));end if;m.pending:=null;
    end if;
   end if;m:=public.board_event(m,evt);
  elsif action='cancel' then if m.pending is null or (m.pending->>'by')::integer<>who then raise exception 'No request.';end if;m.pending:=null;m:=public.board_event(m,evt);
  else raise exception 'Invalid action.';end if;
  if m.state->'result'<>'null'::jsonb then m.status:=case when m.state->'result'->>'reason'='interrupted' then 'interrupted' else 'finished' end;m.ended_at:=clock_timestamp();m.pending:=null;end if;
  update public.board_matches set state=m.state,controls=m.controls,pending=m.pending,events=m.events,status=m.status,ended_at=m.ended_at where id=m.id;
 end if;
 update public.board_seats set last_seen=clock_timestamp()where room_code=r.code and account_id=a;
 update public.board_rooms set guest_id=r.guest_id,bot_level=r.bot_level,host_side=r.host_side,round=r.round,match_id=r.match_id,takeover_level=r.takeover_level,revision=revision+1,updated_at=clock_timestamp()where code=r.code returning * into r;
 insert into public.board_requests(room_code,account_id,request_id)values(r.code,a,p_request_id);return public.board_room_json(r,a);
end;$$;
create or replace function public.board_chat_json(m public.board_messages) returns jsonb language sql stable set search_path=public as $$select jsonb_build_object('id',m.id,'accountId',m.account_id,'name',m.author_name,'text',m.body,'createdAt',m.created_at,'requestId',m.request_id);$$;
create or replace function public.board_chat_list(p_room_code text,p_account_token text,p_before_id bigint default null,p_after_id bigint default null) returns jsonb language plpgsql security definer set search_path=public as $$
declare a uuid:=public.game_account_id_from_token(p_account_token);code text:=upper(btrim(p_room_code));items jsonb;
begin if not public.board_is_member(code,a) then raise exception 'Membership required.';end if;
 if p_after_id is not null then select coalesce(jsonb_agg(public.board_chat_json(m)order by m.id),'[]') into items from(select * from public.board_messages where room_code=code and id>p_after_id order by id limit 50)m;
 else select coalesce(jsonb_agg(public.board_chat_json(m)order by m.id),'[]') into items from(select * from public.board_messages where room_code=code and (p_before_id is null or id<p_before_id)order by id desc limit 50)m;end if;return items;
end;$$;
create or replace function public.board_chat_send(p_room_code text,p_text text,p_request_id uuid,p_account_token text) returns jsonb language plpgsql security definer set search_path=public as $$
declare a uuid:=public.game_account_id_from_token(p_account_token);code text:=upper(btrim(p_room_code));m public.board_messages%rowtype;
begin if not public.board_is_member(code,a) then raise exception 'Membership required.';end if;
 if p_request_id is null then raise exception 'Request id required.';end if;select * into m from public.board_messages where room_code=code and account_id=a and request_id=p_request_id;if found then return public.board_chat_json(m);end if;
 if char_length(btrim(coalesce(p_text,''))) not between 1 and 1000 then raise exception 'Invalid message.';end if;
 insert into public.board_messages(room_code,account_id,author_name,body,request_id)select code,a,display_name,btrim(p_text),p_request_id from public.game_accounts where id=a
 on conflict(room_code,account_id,request_id)do update set request_id=excluded.request_id returning * into m;return public.board_chat_json(m);
end;$$;
do $$ declare f record;begin for f in select oid::regprocedure as signature from pg_proc where pronamespace='public'::regnamespace and proname like 'board\_%' escape '\' loop execute format('revoke execute on function %s from public,anon,authenticated',f.signature);end loop;end;$$;
grant execute on function public.board_create_room(text,text,text,text,integer,text),public.board_get_room(text,text),public.board_get_match(uuid,text),public.board_records(text),public.board_action(text,text,jsonb,integer,uuid,text),public.board_chat_list(text,text,bigint,bigint),public.board_chat_send(text,text,uuid,text) to anon,authenticated;



-- 同词相遇: only RPCs can read submitted words. Never grant table access.
create table if not exists public.words_rooms (
 code text primary key, title text not null check(char_length(title) between 1 and 60),
 host_id uuid not null references public.game_accounts(id), guest_id uuid references public.game_accounts(id),
 host_name text not null, guest_name text, create_id uuid not null,
 phase text not null default 'waiting' check(phase in ('waiting','ready','writing','revealed','matched','interrupted')),
 round_no integer not null default 0, revision integer not null default 0,
 host_ready boolean not null default false,guest_ready boolean not null default false,
 created_at timestamptz not null default clock_timestamp(),started_at timestamptz,ended_at timestamptz,
 unique(host_id,create_id),check(guest_id is null or guest_id<>host_id)
);
create index if not exists words_rooms_host_created on public.words_rooms(host_id,created_at desc);
create index if not exists words_rooms_guest_created on public.words_rooms(guest_id,created_at desc);
create table if not exists public.words_rounds (
 room_code text not null references public.words_rooms(code),round_no integer not null,
 started_at timestamptz not null,revealed_at timestamptz,
 word1 text,word2 text,key1 text,key2 text,name1 text not null,name2 text not null,
 primary key(room_code,round_no),check(revealed_at is null or (word1 is not null and word2 is not null))
);
create table if not exists public.words_requests (
 room_code text not null references public.words_rooms(code), account_id uuid not null references public.game_accounts(id),request_id uuid not null,
 primary key(room_code,account_id,request_id)
);
alter table public.words_rooms enable row level security;
alter table public.words_rounds enable row level security;
alter table public.words_requests enable row level security;
revoke all on public.words_rooms,public.words_rounds,public.words_requests from public,anon,authenticated;

-- Modified OpenCC character mapping; see licenses/word-meet-opencc.txt.
create or replace function public.words_clean(p_word text) returns text language sql immutable set search_path=public as $$select btrim(p_word,U&'\0020\0009\000a\000d\000c\000b\00a0\1680\2000\2001\2002\2003\2004\2005\2006\2007\2008\2009\200a\2028\2029\202f\205f\3000\feff');$$;
create or replace function public.words_key(p_word text) returns text language plpgsql immutable set search_path=public as $$
declare w text:=public.words_clean(p_word);begin
 if w is null then raise exception 'Invalid word.';end if;
 if w ~ '^[A-Za-z]{2,15}$' then return translate(w,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz');end if;
 if w !~ '^[㐀-䶿一-鿿豈-﫿𠀀-𲎯]{2,6}$' then raise exception 'Invalid word.';end if;
 return translate(w,'㑯㑳㑶㓨㗲㘚㜄㜏㜢㠏㠣㥮㩜㩳㩵㺏䁪䁻䃮䊷䋙䋚䋹䋻䍦䎱䓣䙡䜀䝼䡵䥇䥑䥕䥱䦛䦟䧢䮄䯀䰾䱷䱽䲁䲘䴉丟並么乾亂亙亞佇佈佔併來侖侶侷俁係俔俠俥俬倀倆倈倉個們倖倫倲偉偑側偵偽傌傑傖傘備傢傭傯傳傴債傷傾僂僅僉僑僕僞僤僥僨僱價儀儁儂億儈儉儎儐儔儕儘償優儲儷儸儺儻儼兇兌兒兗內兩冊冑冪凈凍凜凱別刪剄則剋剎剗剛剝剮剴創剷劃劄劇劉劊劌劍劏劑劚勁動務勛勝勞勢勣勩勱勳勵勸勻匭匯匱區協卹卻卽厙厠厤厭厲厴參叄叢吒吳吶呂咼員唄唸問啓啞啟啢喎喚喪喫喬單喲嗆嗇嗊嗎嗚嗩嗰嗶嘆嘍嘓嘔嘖嘗嘜嘩嘮嘯嘰嘵嘸嘽噁噓噚噝噠噥噦噯噲噴噸噹嚀嚇嚌嚐嚕嚙嚥嚦嚧嚨嚮嚲嚳嚴嚶囀囁囂囅囈囉囌囑囪圇國圍園圓圖團垻埡埨埰執堅堊堖堝堯報場塊塋塏塒塗塚塢塤塵塸塹塿墊墜墠墮墰墳墶墻墾壇壋壎壓壗壘壙壚壜壞壟壠壢壩壪壯壺壼壽夠夢夥夾奐奧奩奪奬奮奼妝姍姦娙娛婁婦婭媧媯媰媼媽嫋嫗嫵嫺嫻嫿嬀嬃嬈嬋嬌嬙嬡嬤嬪嬰嬸孃孋孌孫學孻孿宮寀寢實寧審寫寬寵寶將專尋對導尷屆屍屓屜屢層屨屬岡峯峴島峽崍崑崗崙崢崬嵐嵗嵽嵾嶁嶄嶇嶔嶗嶠嶢嶧嶨嶮嶸嶺嶼嶽巋巒巔巖巘巰巹帥師帳帶幀幃幓幗幘幟幣幫幬幷幹幾庫廁廂廄廈廎廕廚廝廞廟廠廡廢廣廩廬廳弒弔弳張強彄彆彈彌彎彔彙彠彥彫彲彿後徑從徠復徵徹恆恥悅悞悵悶悽惡惱惲惻愛愜愨愴愷愾慄態慍慘慚慟慣慤慪慫慮慳慶慺慼慾憂憊憐憑憒憖憚憤憫憮憲憶懇應懌懍懞懟懣懤懨懲懶懷懸懺懼懾戀戇戔戧戩戰戱戲戶扞拋拚挩挱挾捨捫捱捲掃掄掆掗掙掛採揀揚換揮揯損搖搗搧搵搶摑摜摟摯摳摶摺摻撈撏撐撓撝撟撣撥撫撲撳撻撾撿擁擄擇擊擋擓擔據擠擡擣擬擯擰擱擲擴擷擺擻擼擽擾攄攆攏攔攖攙攛攜攝攢攣攤攪攬敎敓敗敘敵數斂斃斆斕斬斷於旂旣昇時晉晛晝暈暉暐暘暢暫曄曆曇曉曏曖曠曥曨曬書會朥朧朮東枴柵柺査桱桿梔梘梜條梟梲棄棊棖棗棟棡棧棲棶椏椲楊楓楨業極榘榦榪榮榲榿構槍槓槤槧槨槮槳槶槼樁樂樅樑樓標樞樢樣樧樫樳樸樹樺樿橈橋機橢橫橯檁檉檔檜檟檢檣檮檯檳檸檻櫃櫍櫓櫚櫛櫝櫞櫟櫥櫧櫨櫪櫫櫬櫱櫳櫸櫻欄欅權欏欒欓欖欞欽歎歐歟歡歲歷歸歿殘殞殤殨殫殭殮殯殰殲殺殻殼毀毆毿氂氈氌氣氫氬氳氾汎汙決沒沖況泝洩洶浹浿涇涗涼淒淚淥淨淩淪淵淶淺渙減渢渦測渾湊湋湞湧湯溈準溝溫溮溳溼滄滅滌滎滙滬滯滲滷滸滻滾滿漁漊漍漚漢漣漬漲漵漸漿潀潁潑潔潕潙潚潛潤潯潰潷潿澀澆澇澐澗澠澤澦澩澫澮澱澾濁濃濄濆濕濘濚濛濜濟濤濧濫濰濱濺濼濾瀂瀅瀆瀇瀉瀋瀏瀕瀘瀝瀟瀠瀦瀧瀨瀰瀲瀾灃灄灑灒灕灘灙灝灡灣灤灧灩災為烏烴無煉煒煙煢煥煩煬煱熅熒熗熰熱熲熾燀燁燈燉燒燖燙燜營燦燬燭燴燶燻燼燾爍爐爛爭爲爺爾牀牆牘牴牽犖犛犢犧狀狹狽猙猶猻獁獃獄獅獎獨獪獫獮獰獱獲獵獷獸獺獻獼玀現琱琺琿瑋瑒瑣瑤瑩瑪瑲璉璊璕璗璡璣璦璫璯環璵璸璽璿瓅瓊瓏瓔瓚瓛甌甕產産畝畢畫異畵當疇疊痙痠痺痾瘂瘋瘍瘓瘞瘡瘧瘮瘲瘺瘻療癆癇癉癒癘癟癡癢癤癥癧癩癬癭癮癰癱癲發皁皚皰皸皺盃盜盞盡監盤盧盪眞眥眾睍睏睜睞睪瞘瞜瞞瞶瞼矇矓矚矯硃硜硤硨硯碕碩碭碸確碼碽磑磚磠磣磧磯磽磾礄礎礐礙礦礪礫礬礱祕祿禍禎禕禡禦禪禮禰禱禿秈稅稈稏稜稟種稱穀穇穌積穎穠穡穢穩穫穭窩窪窮窯窵窶窺竄竅竇竈竊竪競筆筍筧筴箇箋箏箚節範築篋篔篠篢篤篩篳篸簀簍簑簞簡簣簫簷簹簽簾籃籅籌籔籙籛籜籟籠籤籩籪籬籮籲粵糉糝糞糧糰糲糴糶糹糾紀紂紃約紅紆紇紈紉紋納紐紓純紕紖紗紘紙級紛紜紝紞紡紬紮細紱紲紳紵紹紺紼紿絀終絃組絅絆絎結絕絛絝絞絡絢給絨絪絰統絲絳絶絹絺綁綃綄綆綈綉綌綎綏綐綑經綖綜綝綞綠綡綢綣綧綪綫綬維綯綰綱網綳綴綵綸綹綺綻綽綾綿緄緇緊緋緑緒緓緔緗緘緙線緝緞締緡緣緦編緩緬緯緱緲練緶緹緻緼縈縉縊縋縐縑縕縗縛縝縞縟縣縧縫縭縮縯縱縲縳縴縵縶縷縹總績繃繅繆繒織繕繚繞繡繢繩繪繫繭繮繯繰繳繶繸繹繻繼繽繾繿纁纆纇纈纊續纍纏纓纔纕纖纘纜缽罃罈罌罎罰罵罷羅羆羈羋羣羥羨義羶習翫翬翹翽耬耮聖聞聯聰聲聳聵聶職聹聽聾肅脅脈脛脣脩脫脹腎腖腡腦腫腳腸膃膕膚膞膠膢膩膽膾膿臉臍臏臘臚臟臠臢臥臨臺與興舉舊舖舘艙艤艦艫艱艷芻苧茲荊莊莖莢莧華菴菸萇萊萬萴萵葉葒著葤葦葯葷蒍蒐蒓蒔蒕蒞蒼蓀蓆蓋蓮蓯蓴蓽蔄蔔蔘蔞蔣蔥蔦蔭蔯蔿蕁蕆蕎蕒蕓蕕蕘蕢蕩蕪蕭蕷薀薈薊薌薑薔薘薟薦薩薳薴薵薹薺藍藎藝藥藪藭藴藶藹藺蘀蘄蘆蘇蘊蘋蘚蘞蘟蘢蘭蘺蘿虆虉處虛虜號虧虯蛺蛻蜆蝀蝕蝟蝦蝨蝸螄螞螢螮螻螿蟄蟈蟎蟣蟬蟯蟲蟳蟶蟻蠁蠅蠆蠍蠐蠑蠔蠟蠣蠨蠱蠶蠻衆衊術衕衚衛衝袞袷裊裏補裝裡製複褌褘褲褳褸褻襀襇襉襏襖襝襠襤襪襬襯襲襴覈見覎規覓視覘覡覥覦親覬覯覲覷覺覽覿觀觴觶觸訁訂訃計訊訌討訏訐訒訓訕訖託記訛訝訟訢訣訥訩訪設許訴訶診註証詀詁詆詎詐詒詔評詖詗詘詛詝詞詠詡詢詣試詩詪詫詬詭詮詰話該詳詵詷詼詿誄誅誆誇誌認誑誒誕誘誚語誠誡誣誤誥誦誨說説誰課誶誹誼誾調諂諄談諉請諍諏諑諒諓論諗諛諜諝諞諟諡諢諤諦諧諫諭諮諱諲諳諴諶諷諸諺諼諾謀謁謂謄謅謊謎謏謐謔謖謗謙謚講謝謠謡謨謫謬謭謳謹謾譁證譎譏譓譖識譙譚譜譞譟譫譭譯議譴護譸譽譾讀讅變讋讌讎讒讓讕讖讚讜讞谿豈豎豐豔豬豶貍貓貙貝貞貟負財貢貧貨販貪貫責貯貰貲貳貴貶買貸貺費貼貽貿賀賁賂賃賄賅資賈賊賑賒賓賕賙賚賜賞賠賡賢賣賤賦賧質賫賬賭賰賴賵賺賻購賽賾贄贅贇贈贊贋贍贏贐贓贔贖贗贛贜赬趕趙趨趲跡踐踰踴蹌蹕蹟蹠蹣蹤蹺躂躉躊躋躍躎躑躒躓躕躚躡躥躦躪軀車軋軌軍軏軑軒軔軛軝軟軤軫軲軸軹軺軻軼軾較輄輅輇輈載輊輋輒輓輔輕輗輛輜輝輞輟輥輦輩輪輬輮輯輳輶輸輻輼輾輿轀轂轄轅轆轉轍轎轔轟轡轢轤辦辭辮辯農迴逕這連週進遊運過達違遙遜遞遠遡適遲遶遷選遺遼邁還邇邊邏邐郟郵鄆鄉鄒鄔鄖鄧鄩鄭鄰鄲鄳鄴鄶鄺酇酈醃醖醜醞醟醣醫醬醱醲釀釁釃釅釋釐釒釓釔釕釗釘釙針釣釤釦釧釩釴釵釷釹釺釾釿鈀鈁鈃鈄鈅鈇鈈鈉鈍鈎鈐鈑鈒鈔鈕鈞鈡鈣鈥鈦鈧鈮鈰鈳鈴鈷鈸鈹鈺鈽鈾鈿鉀鉅鉆鉈鉉鉊鉋鉍鉑鉕鉗鉚鉛鉝鉞鉢鉤鉥鉦鉧鉬鉭鉮鉳鉶鉷鉸鉺鉻鉿銀銃銅銈銍銑銓銖銘銚銛銜銠銣銥銦銨銩銪銫銬銱銳銶銷銹銻銼鋁鋃鋅鋇鋌鋏鋐鋒鋗鋙鋝鋟鋣鋤鋥鋦鋨鋩鋪鋭鋮鋯鋰鋱鋶鋸鋹鋼錀錁錄錆錇錈錏錐錒錕錘錙錚錛錞錟錠錡錢錤錦錨錩錫錮錯録錳錶錸錼鍀鍁鍃鍅鍆鍇鍈鍊鍋鍍鍔鍘鍚鍛鍠鍤鍥鍩鍬鍭鍰鍵鍶鍺鍼鍾鎂鎄鎇鎊鎌鎓鎔鎖鎘鎚鎛鎝鎡鎢鎣鎦鎧鎩鎪鎬鎭鎮鎰鎲鎳鎵鎶鎸鎿鏃鏇鏈鏌鏍鏏鏐鏑鏗鏘鏜鏝鏞鏟鏡鏢鏤鏨鏰鏵鏷鏹鏺鏻鏽鐃鐄鐇鐋鐍鐏鐐鐒鐓鐔鐘鐙鐝鐠鐥鐦鐧鐨鐩鐫鐮鐯鐲鐳鐵鐶鐸鐺鐽鐿鑄鑊鑌鑑鑒鑔鑕鑞鑠鑣鑥鑪鑭鑰鑱鑲鑷鑹鑼鑽鑾鑿钁钂長門閂閃閆閈閉開閌閎閏閑閒間閔閘閡閣閤閥閨閩閫閬閭閱閲閶閹閻閼閽閾閿闃闆闇闈闉闊闋闌闍闐闑闒闓闔闕闖關闞闠闡闢闤闥陘陝陞陣陰陳陸陽隉隊階隑隕際隤隨險隮隯隱隴隸隻雋雖雙雛雜雞離難雲電霑霢霧霽靂靄靆靈靉靚靜靝靦靨鞏鞝鞦鞽韁韃韆韉韋韌韍韓韙韜韝韞韻響頁頂頃項順頇須頊頌頍頎頏預頑頒頓頔頗領頜頠頡頤頦頫頭頮頰頲頴頵頷頸頹頻頽顆題額顎顏顒顓顔顗願顙顛類顢顥顧顫顬顯顰顱顳顴風颭颮颯颱颳颶颸颺颻颼飀飄飆飈飛飠飢飣飥飩飪飫飭飯飱飲飴飼飽飾飿餃餄餅餈餉養餌餎餏餑餒餓餕餖餗餘餚餛餜餞餡館餬餱餳餵餶餷餸餺餼餾餿饁饃饅饈饉饊饋饌饑饒饗饘饜饞饢馬馭馮馱馳馴馹馼駁駃駉駐駑駒駓駔駕駘駙駛駝駟駡駢駪駭駰駱駸駼駿騁騂騄騅騊騌騍騎騏騑騖騙騞騠騤騧騫騭騮騰騱騵騶騷騸騾驀驁驂驃驄驅驊驌驍驎驏驕驗驚驛驟驢驤驥驦驪驫骯髏髒體髕髖髮鬆鬍鬚鬢鬥鬧鬨鬩鬮鬱鬹魎魘魚魛魟魢魨魯魴魷魺鮀鮁鮃鮆鮈鮊鮋鮍鮎鮐鮑鮒鮓鮚鮜鮝鮞鮟鮠鮡鮣鮦鮪鮫鮭鮮鮳鮶鮸鮺鯀鯁鯇鯉鯊鯒鯔鯕鯖鯗鯛鯝鯡鯢鯤鯧鯨鯪鯫鯰鯴鯷鯻鯽鯿鰁鰂鰃鰆鰈鰉鰊鰌鰍鰏鰐鰒鰓鰛鰜鰟鰠鰣鰤鰥鰧鰨鰩鰭鰮鰱鰲鰳鰵鰶鰷鰹鰺鰻鰼鰾鱀鱂鱅鱇鱈鱉鱒鱔鱖鱗鱘鱚鱝鱟鱠鱣鱤鱧鱨鱭鱯鱲鱷鱸鱺鳥鳧鳩鳬鳲鳳鳴鳶鳾鴆鴇鴉鴒鴕鴛鴝鴞鴟鴣鴦鴨鴯鴰鴴鴷鴻鴿鵁鵂鵃鵏鵐鵑鵒鵓鵜鵝鵟鵠鵡鵪鵬鵮鵯鵰鵲鵷鵾鶄鶇鶉鶊鶓鶖鶘鶚鶠鶡鶥鶩鶪鶬鶯鶱鶲鶴鶹鶺鶻鶼鶿鷀鷁鷂鷄鷉鷊鷓鷖鷗鷙鷚鷟鷥鷦鷫鷭鷯鷲鷳鷴鷸鷹鷺鷽鸂鸇鸊鸌鸏鸑鸕鸘鸚鸛鸝鸞鹵鹹鹺鹼鹽麗麥麩麪麫麬麯麳麴麵麼麽黃黌點黨黲黴黶黷黽黿鼂鼉鼕鼴齊齋齎齏齒齔齕齗齘齙齜齟齠齡齣齦齧齪齬齮齯齲齶齷齼龍龎龐龑龔龕龜鿁鿓豈更車賈滑串句龜龜契金喇奈懶癩羅蘿螺裸邏樂洛烙珞落酪駱亂卵欄爛蘭鸞嵐濫藍襤拉臘蠟廊朗浪狼郎來冷勞擄櫓爐盧老蘆虜路露魯鷺碌祿綠菉錄鹿論壟弄籠聾牢磊賂雷壘屢樓淚漏累縷陋勒肋凜凌稜綾菱陵讀拏樂諾丹寧怒率異北磻便復不泌數索參塞省葉說殺辰沈拾若掠略亮兩凉梁糧良諒量勵呂女廬旅濾礪閭驪麗黎力曆歷轢年憐戀撚漣煉璉秊練聯輦蓮連鍊列劣咽烈裂說廉念捻殮簾獵令囹寧嶺怜玲瑩羚聆鈴零靈領例禮醴隸惡了僚寮尿料樂燎療蓼遼龍暈阮劉杻柳流溜琉留硫紐類六戮陸倫崙淪輪律慄栗率隆利吏履易李梨泥理痢罹裏裡里離匿溺吝燐璘藺隣鱗麟林淋臨立笠粒狀炙識什茶刺切度拓糖宅洞暴輻行降見廓兀嗀塚晴凞猪益礼神祥福靖精羽蘒諸逸都飯飼館鶴郞隷侮僧免勉勤卑喝嘆器塀墨層屮悔慨憎懲敏既暑梅海渚漢煮爫琢碑社祉祈祐祖祝禍禎穀突節練縉繁署者臭艹艹著褐視謁謹賓贈辶逸難響頻恵𤋮舘並况全侀充冀勇勺喝啕喙嗢塚墳奄奔婢嬨廒廙彩徭惘慎愈憎慠懲戴揄搜摒敖晴朗望杖歹殺流滛滋漢瀞煮瞧爵犯猪瑱甆画瘝瘟益盛直睊着磌窱節类絛練缾者荒華蝹襁覆視調諸請謁諾諭謹變贈輸遲醙鉶陼難靖韛響頋頻鬒龜𢡊𢡄𣏕㮝䀘䀹𥉉𥳐𧻓齃龎𠁞𠗣𡃕𡅏𡑍𡑭𡓾𡔖𡞵𡠹𡢃𡮉𡮣𡳳𡻕𡾱𢣚𢶫𢹿𣈶𣙎𣞻𣠩𣠲𣯶𣾷𤁣𤅶𤓩𤪺𤫩𤳸𥊝𥌃𥕥𥖅𥗽𥢢𥸠𥼽𦘧𦣎𦪙𧜗𧜵𧝞𧟀𧩙𧵳𧶧𨊰𨊸𨋢𨤻𨦫𨧀𨧜𨨏𨭆𨭎𨯅𩞯𩠴𩣑𩶘丽丸乁𠄢你侮侻倂偺備僧像㒞𠘺免兔兤具𠔜㒹內再𠕋冗冤仌冬况𩇟凵刃㓟刻剆割剷㔕勇勉勤勺包匆北卉卑博即卽卿卿卿𠨬灰及叟𠭣叫叱吆咞吸呈周咢哶唐啓啣善善喙喫喳嗂圖嘆圗噑噴切壮城埴堍型堲報墬𡓤売壷夆多夢奢𡚨𡛪姬娛娧姘婦㛮㛼嬈嬾嬾𡧈寃寘寧寳𡬘寿将当尢㞁屠屮峀岍𡷤嵃𡷦嵮嵫嵼巡巢㠯巽帨帽幩㡢𢆃㡼庰庳庶廊𪎒廾𢌱𢌱舁弢弢㣇𣊸𦇚形彫㣣徚忍志忹悁㤺㤜悔𢛔惇慈慌慎慌慺憎憲憤憯懞懲懶成戛扝抱拔捐𢬌挽拼捨掃揤𢯱搢揅掩㨮摩摾撝摷㩬敏敬𣀊旣書晉㬙暑㬈㫤冒冕最暜肭䏙朗望朡杞杓𣏃㭉柺枅桒梅𣑭梎栟椔㮝楂榣槪檨𣚣櫛㰘次𣢧歔㱎歲殟殺殻𣪍𡴋𣫺汎𣲼沿泍汧洖派海流浩浸涅𣴞洴港湮㴳滋滇𣻑淹潮𣽞𣾎濆瀹瀞瀛㶖灊災灷炭𠔥煅𤉣熜𤎫爨爵牐𤘈犀犕𤜵𤠔獺王㺬玥㺸㺸瑇瑜瑱璅瓊㼛甤𤰶甾𤲒異𢆟瘐𤾡𤾸𥁄㿼䀈直𥃳𥃲𥄙𥄳眞真真睊䀹瞋䁆䂖𥐝硎碌磌䃣𥘦祖𥚚𥛅福秫䄯穀穊穏𥥼𥪧𥪧竮䈂𥮫篆築䈧𥲀糒䊠糨糣紀𥾆絣䌁緇縂繅䌴𦈨𦉇䍙𦋙罺𦌾羕翺者𦓚𦔣聠𦖨聰𣍟䏕育脃䐋脾媵𦞧𦞵𣎓𣎜舁舄辞䑫芑芋芝劳花芳芽苦𦬼若茝荣莭茣莽菧著荓菊菌菜𦰶𦵫𦳕䔫蓱蓳蔖𧏊蕤𦼬䕝䕡𦾱𧃒䕫虐虜虧虩蚩蚈蜎蛢蝹蜨蝫螆䗗蟡蠁䗹衠衣𧙧裗裞䘵裺㒻𧢮𧥦䚾䛇誠諭變豕𧲨貫賁贛起𧼯𠠄跋趼跰𠣞軔輸𨗒𨗭邔郱鄑𨜮鄛鈸鋗鋘鉼鏹鐕𨯺開䦕閷𨵷䧦雃嶲霣𩅅𩈚䩮䩶韠𩐊䪲𩒖頋頋頩𩖶飢䬳餩馧駂駾䯎𩬰鬒鱀鳽䳎䳭鵧𪃎䳸𪄅𪈎𪊑麻䵖黹黾鼅鼏鼖鼻𪘀𰻞','㑔㑇㐹刾𠵾㘎㚯㛣𡞱㟆𫵷㤘㨫㧐擜𤠋𥇢䀥鿎䌶䌺䌻䌿䌾䍠䎬𬜯䙌䜧䞍𫟦䦂鿏𬭯䥾䦶䦷𨸟𫠊䯅鲃䲣䲝鳚鳤鹮丢并幺干乱亘亚伫布占并来仑侣局俣系伣侠伡私伥俩俫仓个们幸伦㑈伟㐽侧侦伪㐷杰伧伞备家佣偬传伛债伤倾偻仅佥侨仆伪𫢸侥偾雇价仪俊侬亿侩俭傤傧俦侪尽偿优储俪㑩傩傥俨凶兑儿兖内两册胄幂净冻凛凯别删刭则克刹刬刚剥剐剀创铲划札剧刘刽刿剑㓥剂㔉劲动务勋胜劳势𪟝勚劢勋励劝匀匦汇匮区协恤却即厍厕历厌厉厣参叁丛咤吴呐吕呙员呗念问启哑启唡㖞唤丧吃乔单哟呛啬唝吗呜唢𠮶哔叹喽啯呕啧尝唛哗唠啸叽哓呒啴恶嘘㖊咝哒哝哕嗳哙喷吨当咛吓哜尝噜啮咽呖𠰷咙向亸喾严嘤啭嗫嚣冁呓啰苏嘱囱囵国围园圆图团坝垭𫭢采执坚垩垴埚尧报场块茔垲埘涂冢坞埙尘𫭟堑𪣻垫坠𫮃堕坛坟垯墙垦坛垱埙压𡋤垒圹垆坛坏垄垅坜坝塆壮壶壸寿够梦伙夹奂奥奁夺奖奋姹妆姗奸𫰛娱娄妇娅娲妫㛀媪妈袅妪妩娴娴婳妫媭娆婵娇嫱嫒嬷嫔婴婶娘㛤娈孙学𡥧孪宫采寝实宁审写宽宠宝将专寻对导尴届尸屃屉屡层屦属冈峰岘岛峡崃昆岗仑峥岽岚岁𫶇㟥嵝崭岖嵚崂峤峣峄峃崄嵘岭屿岳岿峦巅岩𪩘巯卺帅师帐带帧帏㡎帼帻帜币帮帱并干几库厕厢厩厦庼荫厨厮𫷷庙厂庑废广廪庐厅弑吊弪张强𫸩别弹弥弯录汇彟彦雕彨佛后径从徕复征彻恒耻悦悮怅闷凄恶恼恽恻爱惬悫怆恺忾栗态愠惨惭恸惯悫怄怂虑悭庆㥪戚欲忧惫怜凭愦慭惮愤悯怃宪忆恳应怿懔蒙怼懑㤽恹惩懒怀悬忏惧慑恋戆戋戗戬战戯戏户捍抛拼捝挲挟舍扪挨卷扫抡㧏挜挣挂采拣扬换挥搄损摇捣扇揾抢掴掼搂挚抠抟折掺捞挦撑挠㧑挢掸拨抚扑揿挞挝捡拥掳择击挡㧟担据挤抬捣拟摈拧搁掷扩撷摆擞撸㧰扰摅撵拢拦撄搀撺携摄攒挛摊搅揽教敚败叙敌数敛毙敩斓斩断于旗既升时晋𬀪昼晕晖𬀩旸畅暂晔历昙晓向暧旷𣆐昽晒书会𦛨胧术东拐栅拐查𣐕杆栀枧𬂩条枭棁弃棋枨枣栋㭎栈栖梾桠㭏杨枫桢业极矩干杩荣榅桤构枪杠梿椠椁椮桨椢椝桩乐枞梁楼标枢㭤样榝㭴桪朴树桦椫桡桥机椭横𣓿檩柽档桧槚检樯梼台槟柠槛柜𬃊橹榈栉椟橼栎橱槠栌枥橥榇蘖栊榉樱栏榉权椤栾𣗋榄棂钦叹欧欤欢岁历归殁残殒殇㱮殚僵殓殡㱩歼杀壳壳毁殴毵牦毡氇气氢氩氲泛泛污决没冲况溯泄汹浃𬇙泾涚凉凄泪渌净凌沦渊涞浅涣减沨涡测浑凑𣲗浈涌汤沩准沟温浉涢湿沧灭涤荥汇沪滞渗卤浒浐滚满渔溇𬇹沤汉涟渍涨溆渐浆潨颍泼洁𣲘沩㴋潜润浔溃滗涠涩浇涝沄涧渑泽滪泶𬇕浍淀㳠浊浓㳡𣸣湿泞溁蒙浕济涛㳔滥潍滨溅泺滤澛滢渎㲿泻沈浏濒泸沥潇潆潴泷濑弥潋澜沣滠洒𪷽漓滩𣺼灏㳕湾滦滟滟灾为乌烃无炼炜烟茕焕烦炀㶽煴荧炝𬉼热颎炽𬊤烨灯炖烧𬊈烫焖营灿毁烛烩㶶熏烬焘烁炉烂争为爷尔床墙牍抵牵荦牦犊牺状狭狈狰犹狲犸呆狱狮奖独狯猃狝狞㺍获猎犷兽獭献猕猡现雕珐珲玮玚琐瑶莹玛玱琏𫞩𬍤𬍡琎玑瑷珰㻅环玙瑸玺璇𬍛琼珑璎瓒𤩽瓯瓮产产亩毕画异画当畴叠痉酸痹疴痖疯疡痪瘗疮疟瘆疭瘘瘘疗痨痫瘅愈疠瘪痴痒疖症疬癞癣瘿瘾痈瘫癫发皂皑疱皲皱杯盗盏尽监盘卢荡真眦众𪾢困睁睐睾眍䁖瞒瞆睑蒙眬瞩矫朱硁硖砗砚埼硕砀砜确码䂵硙砖硵碜碛矶硗䃅硚础𬒈碍矿砺砾矾砻秘禄祸祯祎祃御禅礼祢祷秃籼税秆䅉棱禀种称谷䅟稣积颖秾穑秽稳获穞窝洼穷窑窎窭窥窜窍窦灶窃竖竞笔笋笕䇲个笺筝札节范筑箧筼筿𬕂笃筛筚𥮾箦篓蓑箪简篑箫檐筜签帘篮𥫣筹䉤箓篯箨籁笼签笾簖篱箩吁粤粽糁粪粮团粝籴粜纟纠纪纣𬘓约红纡纥纨纫纹纳纽纾纯纰纼纱纮纸级纷纭纴𬘘纺䌷扎细绂绁绅纻绍绀绋绐绌终弦组䌹绊绗结绝绦绔绞络绚给绒𬘡绖统丝绛绝绢𫄨绑绡𬘫绠绨绣绤𬘩绥䌼捆经𫄧综𬘭缍绿𫟅绸绻𬘯𬘬线绶维绹绾纲网绷缀彩纶绺绮绽绰绫绵绲缁紧绯绿绪绬绱缃缄缂线缉缎缔缗缘缌编缓缅纬缑缈练缏缇致缊萦缙缢缒绉缣缊缞缚缜缟缛县绦缝缡缩𬙂纵缧䌸纤缦絷缕缥总绩绷缫缪缯织缮缭绕绣缋绳绘系茧缰缳缲缴𫄷䍁绎𦈡继缤缱䍀𫄸𬙊颣缬纩续累缠缨才𬙋纤缵缆钵䓨坛罂坛罚骂罢罗罴羁芈群羟羡义膻习玩翚翘翙耧耢圣闻联聪声耸聩聂职聍听聋肃胁脉胫唇修脱胀肾胨脶脑肿脚肠腽腘肤䏝胶𦝼腻胆脍脓脸脐膑腊胪脏脔臜卧临台与兴举旧铺馆舱舣舰舻艰艳刍苎兹荆庄茎荚苋华庵烟苌莱万荝莴叶荭着荮苇药荤𫇭搜莼莳蒀莅苍荪席盖莲苁莼荜𬜬卜参蒌蒋葱茑荫𫈟𫇭荨蒇荞荬芸莸荛蒉荡芜萧蓣蕰荟蓟芗姜蔷荙莶荐萨䓕苎䓓苔荠蓝荩艺药薮䓖蕴苈蔼蔺萚蕲芦苏蕴苹藓蔹𦻕茏兰蓠萝蔂𬟁处虚虏号亏虬蛱蜕蚬𬟽蚀猬虾虱蜗蛳蚂萤䗖蝼螀蛰蝈螨虮蝉蛲虫𫊻蛏蚁蚃蝇虿蝎蛴蝾蚝蜡蛎蟏蛊蚕蛮众蔑术同胡卫冲衮夹袅里补装里制复裈袆裤裢褛亵𫌀裥裥袯袄裣裆褴袜摆衬袭襕核见觃规觅视觇觋觍觎亲觊觏觐觑觉览觌观觞觯触讠订讣计讯讧讨𬣙讦讱训讪讫托记讹讶讼䜣诀讷讻访设许诉诃诊注证𧮪诂诋讵诈诒诏评诐诇诎诅𬣞词咏诩询诣试诗𬣳诧诟诡诠诘话该详诜𫍣诙诖诔诛诓夸志认诳诶诞诱诮语诚诫诬误诰诵诲说说谁课谇诽谊訚调谄谆谈诿请诤诹诼谅𬣡论谂谀谍谞谝𬤊谥诨谔谛谐谏谕咨讳𬤇谙𫍯谌讽诸谚谖诺谋谒谓誊诌谎谜𫍲谧谑谡谤谦谥讲谢谣谣谟谪谬谫讴谨谩哗证谲讥𬤝谮识谯谭谱𫍽噪谵毁译议谴护诪誉谫读谉变詟䜩雠谗让谰谶赞谠谳溪岂竖丰艳猪豮狸猫䝙贝贞贠负财贡贫货贩贪贯责贮贳赀贰贵贬买贷贶费贴贻贸贺贲赂赁贿赅资贾贼赈赊宾赇赒赉赐赏赔赓贤卖贱赋赕质赍账赌䞐赖赗赚赙购赛赜贽赘赟赠赞赝赡赢赆赃赑赎赝赣赃赪赶赵趋趱迹践逾踊跄跸迹跖蹒踪跷跶趸踌跻跃䟢踯跞踬蹰跹蹑蹿躜躏躯车轧轨军𫐄轪轩轫轭𬨂软轷轸轱轴轵轺轲轶轼较𨐈辂辁辀载轾𪨶辄挽辅轻𫐐辆辎辉辋辍辊辇辈轮辌𫐓辑辏𬨎输辐辒辗舆辒毂辖辕辘转辙轿辚轰辔轹轳办辞辫辩农回径这连周进游运过达违遥逊递远溯适迟绕迁选遗辽迈还迩边逻逦郏邮郓乡邹邬郧邓𬩽郑邻郸𫑡邺郐邝酂郦腌酝丑酝蒏糖医酱酦𬪩酿衅酾酽释厘钅钆钇钌钊钉钋针钓钐扣钏钒𬬩钗钍钕钎䥺𬬱钯钫钘钭钥𫓧钚钠钝钩钤钣钑钞钮钧钟钙钬钛钪铌铈钶铃钴钹铍钰钸铀钿钾巨钻铊铉𬬿铇铋铂钷钳铆铅𫟷钺钵钩𬬸钲𬭁钼钽𬬹锫铏𫟹铰铒铬铪银铳铜𫓯铚铣铨铢铭铫铦衔铑铷铱铟铵铥铕铯铐铞锐𨱇销锈锑锉铝锒锌钡铤铗𬭎锋𫓶铻锊锓铘锄锃锔锇铓铺锐铖锆锂铽锍锯𬬮钢𬬭锞录锖锫锩铔锥锕锟锤锱铮锛𬭚锬锭锜钱𫓹锦锚锠锡锢错录锰表铼镎锝锨锪钫钔锴锳炼锅镀锷铡钖锻锽锸锲锘锹𬭤锾键锶锗针钟镁锿镅镑镰𬭩镕锁镉锤镈𨱏镃钨蓥镏铠铩锼镐镇镇镒镋镍镓鿔镌镎镞旋链镆镙𬭬镠镝铿锵镗镘镛铲镜镖镂錾镚铧镤镪䥽𬭸锈铙𨱑𫔍铴𫔎𨱔镣铹镦镡钟镫镢镨䦅锎锏镄𬭼镌镰䦃镯镭铁镮铎铛𫟼镱铸镬镔鉴鉴镲锧镴铄镳镥𬬻镧钥镵镶镊镩锣钻銮凿镢镋长门闩闪闫闬闭开闶闳闰闲闲间闵闸阂阁合阀闺闽阃阆闾阅阅阊阉阎阏阍阈阌阒板暗闱𬮱阔阕阑阇阗𫔶阘闿阖阙闯关阚阓阐辟阛闼陉陕升阵阴陈陆阳陧队阶𬮿陨际𬯎随险𬯀陦隐陇隶只隽虽双雏杂鸡离难云电沾霡雾霁雳霭叇灵叆靓静靔腼靥巩绱秋鞒缰鞑千鞯韦韧韨韩韪韬鞲韫韵响页顶顷项顺顸须顼颂𫠆颀颃预顽颁顿𬱖颇领颌𬱟颉颐颏𫖯头颒颊颋颕𫖳颔颈颓频颓颗题额腭颜颙颛颜𫖮愿颡颠类颟颢顾颤颥显颦颅颞颧风飐飑飒台刮飓飔飏飖飕飗飘飙飚飞饣饥饤饦饨饪饫饬饭飧饮饴饲饱饰饳饺饸饼糍饷养饵饹饻饽馁饿馂饾𫗧余肴馄馃饯馅馆糊糇饧喂馉馇𩠌馎饩馏馊馌馍馒馐馑馓馈馔饥饶飨𫗴餍馋馕马驭冯驮驰驯驲𫘜驳𫘝𬳶驻驽驹𬳵驵驾骀驸驶驼驷骂骈𬳽骇骃骆骎𬳿骏骋骍𫘧骓𫘦骔骒骑骐𬴂骛骗𬴃𫘨骙䯄骞骘骝腾𫘬𫘪驺骚骟骡蓦骜骖骠骢驱骅骕骁𬴊骣骄验惊驿骤驴骧骥骦骊骉肮髅脏体髌髋发松胡须鬓斗闹哄阋阄郁鬶魉魇鱼鱽𫚉鱾鲀鲁鲂鱿鲄𬶍鲅鲆𫚖𬶋鲌鲉鲏鲇鲐鲍鲋鲊鲒鲘鲞鲕𩽾𬶏𬶐䲟鲖鲔鲛鲑鲜鲓鲪𩾃鲝鲧鲠鲩鲤鲨鲬鲻鲯鲭鲞鲷鲴鲱鲵鲲鲳鲸鲮鲰鲇鲺鳀𬶟鲫鳊鳈鲗鳂䲠鲽鳇𬶠䲡鳅鲾鳄鳆鳃鳁鳒鳑鳋鲥𫚕鳏䲢鳎鳐鳍鳁鲢鳌鳓鳘𬶭鲦鲣鲹鳗鳛鳔𬶨鳉鳙𩾌鳕鳖鳟鳝鳜鳞鲟𬶮鲼鲎鲙鳣鳡鳢鲿鲚鳠𫚭鳄鲈鲡鸟凫鸠凫鸤凤鸣鸢䴓鸩鸨鸦鸰鸵鸳鸲鸮鸱鸪鸯鸭鸸鸹鸻䴕鸿鸽䴔鸺鸼𬷕鹀鹃鹆鹁鹈鹅𫛭鹄鹉鹌鹏鹐鹎雕鹊鹓鹍䴖鸫鹑鹒鹋鹙鹕鹗𬸘鹖鹛鹜䴗鸧莺𬸣鹟鹤鹠鹡鹘鹣鹚鹚鹢鹞鸡䴘鹝鹧鹥鸥鸷鹨𬸦鸶鹪鹔𬸪鹩鹫鹇鹇鹬鹰鹭鸴㶉鹯䴙鹱鹲𬸚鸬鹴鹦鹳鹂鸾卤咸鹾碱盐丽麦麸面面𤿲曲𪎌曲面幺幺黄黉点党黪霉黡黩黾鼋鼌鼍冬鼹齐斋赍齑齿龀龁龂𬹼龅龇龃龆龄出龈啮龊龉𬺈𫠜龋腭龌𬺓龙厐庞䶮龚龛龟䜤鿒岂更车贾滑串句龟龟契金喇奈懒癞罗萝螺裸逻乐洛烙珞落酪骆乱卵栏烂兰鸾岚滥蓝褴拉腊蜡廊朗浪狼郎来冷劳掳橹炉卢老芦虏路露鲁鹭碌禄绿菉录鹿论垄弄笼聋牢磊赂雷垒屡楼泪漏累缕陋勒肋凛凌棱绫菱陵读拏乐诺丹宁怒率异北磻便复不泌数索参塞省叶说杀辰沈拾若掠略亮两凉梁粮良谅量励吕女庐旅滤砺闾骊丽黎力历历轹年怜恋撚涟炼琏秊练联辇莲连炼列劣咽烈裂说廉念捻殓帘猎令囹宁岭怜玲莹羚聆铃零灵领例礼醴隶恶了僚寮尿料乐燎疗蓼辽龙晕阮刘杻柳流溜琉留硫纽类六戮陆伦仑沦轮律栗栗率隆利吏履易李梨泥理痢罹里里里离匿溺吝燐璘蔺隣鳞麟林淋临立笠粒状炙识什茶刺切度拓糖宅洞暴辐行降见廓兀嗀冢晴凞猪益礼神祥福靖精羽蘒诸逸都饭饲馆鹤郞隷侮僧免勉勤卑喝叹器塀墨层屮悔慨憎惩敏既暑梅海渚汉煮爫琢碑社祉祈祐祖祝祸祯谷突节练缙繁署者臭艹艹着褐视谒谨宾赠辶逸难响频恵𤋮馆并况全侀充冀勇勺喝啕喙嗢冢坟奄奔婢嬨廒廙彩徭惘慎愈憎慠惩戴揄搜摒敖晴朗望杖歹杀流滛滋汉瀞煮瞧爵犯猪瑱甆画瘝瘟益盛直睊着磌窱节类绦练缾者荒华蝹襁覆视调诸请谒诺谕谨变赠输迟醙铏陼难靖韛响頋频鬒龟𢡊𢡄𣏕㮝䀘䀹𥉉𥳐𧻓齃厐𠀾㓆𠴛𠲥𫭼𡋗𡋀𡍣㛟㛿㛠𡭜𡭬𡳃岁㟜𢘝𢫞𢬦暅㭣𣘓𣞎𣑶毶㳢𣺽𣷷𤊰㻘㻏𤳄𥅿𥅘𥐰𥐯𬒗䅪𥮋𥹥𡳒𦟗䑽䘞䙊䘛𧝧䜥䞌䞎䢀䢁䢂𨤰䦀𬭊䦁𬭛𬭶𬭳䥿䭪𩠠䯃䲞丽丸乁𠄢你侮侻倂偺备僧像㒞𠘺免兔兤具𠔜㒹内再𠕋冗冤仌冬况𩇟凵刃㓟刻剆割铲㔕勇勉勤勺包匆北卉卑博即即卿卿卿𠨬灰及叟𠭣叫叱吆咞吸呈周咢哶唐启啣善善喙吃喳嗂图叹圗噑喷切壮城埴堍型堲报墬𡓤売壷夆多梦奢𡚨𡛪姬娱娧姘妇㛮㛼娆嬾嬾𡧈寃寘宁寳𡬘寿将当尢㞁屠屮峀岍𡷤嵃𡷦嵮嵫嵼巡巢㠯巽帨帽幩㡢𢆃㡼庰庳庶廊𪎒廾𢌱𢌱舁弢弢㣇𣊸𦇚形雕㣣徚忍志忹悁㤺㤜悔𢛔惇慈慌慎慌㥪憎宪愤憯蒙惩懒成戛扝抱拔捐𢬌挽拼舍扫揤𢯱搢揅掩㨮摩摾㧑摷㩬敏敬𣀊既书晋㬙暑㬈㫤冒冕最暜肭䏙朗望朡杞杓𣏃㭉拐枅桒梅𣑭梎栟椔㮝楂榣槪檨𣚣栉㰘次𣢧歔㱎岁殟杀壳𣪍𡴋𣫺泛𣲼沿泍汧洖派海流浩浸涅𣴞洴港湮㴳滋滇𣻑淹潮𣽞𣾎𣸣瀹瀞瀛㶖灊灾灷炭𠔥煅𤉣熜𤎫爨爵牐𤘈犀犕𤜵𤠔獭王㺬玥㺸㺸瑇瑜瑱璅琼㼛甤𤰶甾𤲒异𢆟瘐𤾡𤾸𥁄㿼䀈直𥃳𥃲𥄙𥄳真真真睊䀹瞋䁆䂖𥐝硎碌磌䃣𥘦祖𥚚𥛅福秫䄯谷穊穏𥥼𥪧𥪧竮䈂𥮫篆筑䈧𥲀糒䊠糨糣纪𥾆絣䌁缁縂缫䌴𦈨𦉇䍙𦋙罺𦌾羕翺者𦓚𦔣聠𦖨聪𣍟䏕育脃䐋脾媵𦞧𦞵𣎓𣎜舁舄辞䑫芑芋芝劳花芳芽苦𦬼若茝荣莭茣莽菧着荓菊菌菜𦰶𦵫𦳕䔫蓱蓳蔖𧏊蕤𦼬䕝䕡𦾱𧃒䕫虐虏亏虩蚩蚈蜎蛢蝹蜨蝫螆䗗蟡蚃䗹衠衣𧙧裗裞䘵裺㒻𧢮𧥦䚾䛇诚谕变豕𧲨贯贲赣起𧼯𠠄跋趼跰𠣞轫输𨗒𨗭邔郱鄑𨜮鄛钹𫓶鋘鉼镪鐕𨯺开䦕閷𨵷䧦雃嶲霣𩅅𩈚䩮䩶韠𩐊䪲𩒖頋頋頩𩖶饥䬳餩馧駂駾䯎𩬰鬒𬶨鳽䳎䳭鵧𪃎䳸𪄅𪈎𪊑麻䵖黹黾鼅鼏鼖鼻𪘀𰻝');
end;$$;

lock table public.words_rooms in share row exclusive mode;
create table if not exists public.words_members (
 room_code text not null references public.words_rooms(code),
 account_id uuid not null references public.game_accounts(id),
 seat integer not null check(seat between 1 and 6),
 name text not null, ready boolean not null default false,
 primary key(room_code,account_id), unique(room_code,seat)
);
create index if not exists words_members_account_room on public.words_members(account_id,room_code);
create table if not exists public.words_entries (
 room_code text not null, round_no integer not null, account_id uuid not null,
 seat integer not null check(seat between 1 and 6), name text not null,
 word text, word_key text,
 primary key(room_code,round_no,account_id), unique(room_code,round_no,seat),
 foreign key(room_code,round_no) references public.words_rounds(room_code,round_no),
 foreign key(room_code,account_id) references public.words_members(room_code,account_id),
 check((word is null)=(word_key is null))
);
create index if not exists words_entries_member on public.words_entries(room_code,account_id);
alter table public.words_members enable row level security;
alter table public.words_entries enable row level security;
revoke all on public.words_members,public.words_entries from public,anon,authenticated;

-- Preserve legacy membership, pending words, readiness, and historical name snapshots.
insert into public.words_members(room_code,account_id,seat,name,ready)
 select code,host_id,1,host_name,host_ready from public.words_rooms on conflict do nothing;
insert into public.words_members(room_code,account_id,seat,name,ready)
 select code,guest_id,2,guest_name,guest_ready from public.words_rooms where guest_id is not null on conflict do nothing;
insert into public.words_entries(room_code,round_no,account_id,seat,name,word,word_key)
 select t.room_code,t.round_no,r.host_id,1,t.name1,t.word1,t.key1 from public.words_rounds t join public.words_rooms r on r.code=t.room_code on conflict do nothing;
insert into public.words_entries(room_code,round_no,account_id,seat,name,word,word_key)
 select t.room_code,t.round_no,r.guest_id,2,t.name2,t.word2,t.key2 from public.words_rounds t join public.words_rooms r on r.code=t.room_code where r.guest_id is not null on conflict do nothing;

create or replace function public.words_round_json(t public.words_rounds)
returns jsonb language sql stable set search_path='' as $$
 select jsonb_build_object('round',t.round_no,'word1',t.word1,'word2',t.word2,'name1',t.name1,'name2',t.name2,
  'words',coalesce((select jsonb_agg(jsonb_build_object('id',e.account_id,'name',e.name,'word',e.word) order by e.seat) from public.words_entries e where e.room_code=t.room_code and e.round_no=t.round_no),'[]'::jsonb),
  'startedAt',t.started_at,'revealedAt',t.revealed_at);
$$;
create or replace function public.words_bundle(p_room_code text,p_account_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.words_rooms%rowtype;t public.words_rounds%rowtype;prev jsonb;players jsonb;own_word text;n integer;
begin
 select * into r from public.words_rooms where code=upper(btrim(p_room_code));
 if not found then raise exception 'Room not found.';end if;
 if not exists(select 1 from public.words_members where room_code=r.code and account_id=p_account_id)then
  return jsonb_build_object('isMember',false,'room',jsonb_build_object('code',r.code,'title',r.title,'joinable',r.started_at is null and r.phase not in('matched','interrupted') and (select count(*)<6 from public.words_members where room_code=r.code)));
 end if;
 select * into t from public.words_rounds where room_code=r.code and round_no=r.round_no;
 select public.words_round_json(x) into prev from public.words_rounds x where room_code=r.code and revealed_at is not null order by round_no desc limit 1;
 select count(*) into n from public.words_rounds where room_code=r.code and revealed_at is not null;
 select jsonb_agg(jsonb_build_object('id',m.account_id,'name',coalesce(a.display_name,m.name),'ready',m.ready,'submitted',r.phase='writing' and e.word is not null) order by m.seat) into players
  from public.words_members m join public.game_accounts a on a.id=m.account_id
  left join public.words_entries e on e.room_code=m.room_code and e.account_id=m.account_id and e.round_no=r.round_no where m.room_code=r.code;
 select word into own_word from public.words_entries where room_code=r.code and round_no=r.round_no and account_id=p_account_id;
 return jsonb_build_object('isMember',true,'serverNow',clock_timestamp(),
  'room',jsonb_build_object('code',r.code,'title',r.title,'hostId',r.host_id,'capacity',6,'phase',r.phase,'round',r.round_no,'revision',r.revision,'createdAt',r.created_at,'startedAt',r.started_at,'endedAt',r.ended_at),
  'players',players,'current',case when r.phase='writing' then jsonb_build_object('round',r.round_no,'startedAt',t.started_at,'ownWord',own_word)else null end,
  'previous',prev,'revealedCount',n);
end;$$;
create or replace function public.words_get_room(p_room_code text,p_account_token text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a uuid:=public.game_account_id_from_token(p_account_token);
begin
 perform 1 from public.words_rooms where code=upper(btrim(p_room_code)) for share;
 return public.words_bundle(p_room_code,a);
end;$$;
create or replace function public.words_create_room(p_title text,p_request_id uuid,p_account_token text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a uuid:=public.game_account_id_from_token(p_account_token);c text;n text;attempt integer:=0;
begin
 if p_request_id is null then raise exception 'Invalid request.';end if;
 -- Concurrent retries of the same create operation return the same room.
 perform pg_advisory_xact_lock(hashtextextended(a::text||p_request_id::text,0));
 select code into c from public.words_rooms where host_id=a and create_id=p_request_id;
 if found then return public.words_bundle(c,a);end if;
 if p_title is null or char_length(btrim(p_title)) not between 1 and 60 then raise exception 'Invalid title.';end if;
 select coalesce(display_name,'玩家') into n from public.game_accounts where id=a;
 loop
  c:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));attempt:=attempt+1;
  begin
   insert into public.words_rooms(code,title,host_id,host_name,create_id)values(c,btrim(p_title),a,n,p_request_id);exit;
  exception when unique_violation then if attempt>=8 then raise;end if;end;
 end loop;
 insert into public.words_members(room_code,account_id,seat,name)values(c,a,1,n);
 return public.words_bundle(c,a);
end;$$;

-- Internal helper: callers must hold the room row lock and check readiness/membership.
create or replace function public.words_begin_round(p_code text)returns void language plpgsql set search_path='' as $$
declare r public.words_rooms%rowtype;v_now timestamptz:=clock_timestamp();
begin
 update public.words_rooms set round_no=round_no+1,phase='writing',started_at=coalesce(started_at,v_now),host_ready=false,guest_ready=false where code=p_code returning * into r;
 insert into public.words_rounds(room_code,round_no,started_at,name1,name2)
 select r.code,r.round_no,v_now,max(coalesce(a.display_name,m.name))filter(where m.seat=1),max(coalesce(a.display_name,m.name))filter(where m.seat=2)
 from public.words_members m join public.game_accounts a on a.id=m.account_id where m.room_code=r.code;
 insert into public.words_entries(room_code,round_no,account_id,seat,name)
 select r.code,r.round_no,m.account_id,m.seat,coalesce(a.display_name,m.name) from public.words_members m join public.game_accounts a on a.id=m.account_id where m.room_code=r.code;
 update public.words_members set ready=false where room_code=r.code;
end;$$;
create or replace function public.words_action(p_room_code text,p_action text,p_round integer,p_request_id uuid,p_data jsonb,p_account_token text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a uuid:=public.game_account_id_from_token(p_account_token);r public.words_rooms%rowtype;
 v_word text;v_key text;v_now timestamptz;n text;v_count integer;v_done boolean;v_match boolean;
begin
 if p_request_id is null or p_action is null then raise exception 'Invalid request.';end if;
 -- Serializes join/start/submit/interrupt, including simultaneous final submissions.
 select * into r from public.words_rooms where code=upper(btrim(p_room_code)) for update;
 if not found then raise exception 'Room not found.';end if;
 v_now:=clock_timestamp();
 if p_action='join' then
  if exists(select 1 from public.words_members where room_code=r.code and account_id=a)then return public.words_bundle(r.code,a);end if;
  if r.phase in('matched','interrupted')then raise exception 'Game ended.';end if;
  if r.started_at is not null then raise exception 'Game started.';end if;
  select count(*) into v_count from public.words_members where room_code=r.code;
  if v_count>=6 then raise exception 'Room full.';end if;
  select coalesce(display_name,'玩家') into n from public.game_accounts where id=a;
  insert into public.words_members(room_code,account_id,seat,name)values(r.code,a,v_count+1,n);
  update public.words_rooms set guest_id=case when v_count=1 then a else guest_id end,guest_name=case when v_count=1 then n else guest_name end,phase='ready',revision=revision+1 where code=r.code;
  return public.words_bundle(r.code,a);
 end if;
 if not exists(select 1 from public.words_members where room_code=r.code and account_id=a)then raise exception 'Membership required.';end if;
 if exists(select 1 from public.words_requests where room_code=r.code and account_id=a and request_id=p_request_id)then return public.words_bundle(r.code,a);end if;
 if r.phase in('matched','interrupted')then raise exception 'Game ended.';end if;
 if p_round is distinct from r.round_no then raise exception 'Round changed.';end if;
 if p_action='ready' then
  if r.phase not in('waiting','ready','revealed')or jsonb_typeof(p_data->'ready')is distinct from 'boolean' then raise exception 'Not ready phase.';end if;
  update public.words_members set ready=(p_data->>'ready')::boolean where room_code=r.code and account_id=a;
  if r.phase='revealed' and not exists(select 1 from public.words_members where room_code=r.code and not ready)then perform public.words_begin_round(r.code);end if;
 elsif p_action='start' then
  if a<>r.host_id then raise exception 'Host required.';end if;
  if r.started_at is not null or r.phase not in('waiting','ready')then raise exception 'Game started.';end if;
  if (select count(*)<2 or not bool_and(ready) from public.words_members where room_code=r.code)then raise exception 'Players not ready.';end if;
  perform public.words_begin_round(r.code);
 elsif p_action='submit' then
  if r.phase<>'writing'then raise exception 'Not writing phase.';end if;
  if exists(select 1 from public.words_entries where room_code=r.code and round_no=r.round_no and account_id=a and word is not null)then raise exception 'Already submitted.';end if;
  if jsonb_typeof(p_data->'word')is distinct from 'string'then raise exception 'Invalid word.';end if;
  v_word:=public.words_clean(p_data->>'word');v_key:=public.words_key(v_word);
  if exists(select 1 from public.words_entries where room_code=r.code and round_no=r.round_no-1 and word_key=v_key)then raise exception 'Previous word.';end if;
  update public.words_entries set word=v_word,word_key=v_key where room_code=r.code and round_no=r.round_no and account_id=a;
  select bool_and(word is not null),count(distinct word_key)=1 into v_done,v_match from public.words_entries where room_code=r.code and round_no=r.round_no;
  -- Keep the original two-player columns valid for old histories and rerunnable upgrades.
  update public.words_rounds set
   word1=(select word from public.words_entries where room_code=r.code and round_no=r.round_no and seat=1),
   key1=(select word_key from public.words_entries where room_code=r.code and round_no=r.round_no and seat=1),
   word2=(select word from public.words_entries where room_code=r.code and round_no=r.round_no and seat=2),
   key2=(select word_key from public.words_entries where room_code=r.code and round_no=r.round_no and seat=2),
   revealed_at=case when v_done then v_now else null end where room_code=r.code and round_no=r.round_no;
  if v_done then update public.words_rooms set phase=case when v_match then 'matched'else'revealed'end,ended_at=case when v_match then v_now else null end where code=r.code;end if;
 elsif p_action='interrupt' then
  update public.words_rooms set phase='interrupted',ended_at=v_now where code=r.code;
  update public.words_entries e set word=null,word_key=null from public.words_rounds t where t.room_code=r.code and t.revealed_at is null and e.room_code=t.room_code and e.round_no=t.round_no;
  update public.words_rounds set word1=null,word2=null,key1=null,key2=null where room_code=r.code and revealed_at is null;
 else raise exception 'Invalid action.';end if;
 insert into public.words_requests values(r.code,a,p_request_id);
 update public.words_rooms set revision=revision+1 where code=r.code;
 return public.words_bundle(r.code,a);
end;$$;
create or replace function public.words_history(p_room_code text,p_account_token text,p_before_round integer default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a uuid:=public.game_account_id_from_token(p_account_token);c text:=upper(btrim(p_room_code));result jsonb;
begin
 if not exists(select 1 from public.words_members where room_code=c and account_id=a)then raise exception 'Membership required.';end if;
 select coalesce(jsonb_agg(public.words_round_json(t)order by t.round_no desc),'[]'::jsonb)into result from(select * from public.words_rounds where room_code=c and revealed_at is not null and(p_before_round is null or round_no<p_before_round)order by round_no desc limit 25)t;
 return result;
end;$$;
create or replace function public.words_records(p_account_token text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a uuid:=public.game_account_id_from_token(p_account_token);result jsonb;
begin
 select coalesce(jsonb_agg(jsonb_build_object('code',r.code,'title',r.title,'phase',r.phase,'rounds',(select count(*)from public.words_rounds t where t.room_code=r.code and t.revealed_at is not null),
  'names',(select jsonb_agg(m.name order by m.seat)from public.words_members m where m.room_code=r.code),'createdAt',r.created_at,'startedAt',r.started_at,'endedAt',r.ended_at)order by r.created_at desc),'[]'::jsonb)into result
 from(select r.* from public.words_rooms r join public.words_members m on m.room_code=r.code where m.account_id=a order by r.created_at desc limit 100)r;
 return result;
end;$$;
revoke execute on function public.words_clean(text),public.words_key(text),public.words_round_json(public.words_rounds),public.words_bundle(text,uuid),public.words_begin_round(text)from public,anon,authenticated;
revoke execute on function public.words_get_room(text,text),public.words_create_room(text,uuid,text),public.words_action(text,text,integer,uuid,jsonb,text),public.words_history(text,text,integer),public.words_records(text)from public,anon,authenticated;
grant execute on function public.words_get_room(text,text),public.words_create_room(text,uuid,text),public.words_action(text,text,integer,uuid,jsonb,text),public.words_history(text,text,integer),public.words_records(text)to anon,authenticated;
notify pgrst,'reload schema';

commit;
