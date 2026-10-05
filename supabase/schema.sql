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

commit;
