create extension if not exists pgcrypto;

create table if not exists public.game_accounts (
  id uuid primary key default gen_random_uuid(),
  username text not null,
  username_key text not null unique,
  password_hash text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

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

create or replace function public.game_account_id_from_token(
  p_account_token text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_account_id uuid;
begin
  if coalesce(btrim(p_account_token), '') = '' then
    return null;
  end if;

  delete from public.game_account_sessions
   where expires_at <= now();

  select s.account_id
    into v_account_id
    from public.game_account_sessions s
   where s.token_hash = encode(extensions.digest(p_account_token, 'sha256'), 'hex')
     and s.expires_at > now();

  return v_account_id;
end;
$$;

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
      'username', p_account.username
    ),
    'token', v_token,
    'expiresAt', v_expires_at
  );
end;
$$;

create or replace function public.account_register(
  p_username text,
  p_password text
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

  insert into public.game_accounts (username, username_key, password_hash)
  values (v_username, v_username_key, extensions.crypt(p_password, extensions.gen_salt('bf')))
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
   where username_key = v_username_key;

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
         (p_player_key is not null and player_key = p_player_key)
         or (v_account_id is not null and account_id = v_account_id)
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
    nickname = excluded.nickname,
    account_id = coalesce(public.qa_players.account_id, excluded.account_id)
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
       (p_player_key is not null and player_key = p_player_key)
       or (v_account_id is not null and account_id = v_account_id)
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
       (p_player_key is not null and player_key = p_player_key)
       or (v_account_id is not null and account_id = v_account_id)
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
     set submitted_at = now()
   where id = v_player.id
   returning *
   into v_player;

  return public.qa_room_bundle(v_room.code, v_player.id, p_player_key, p_account_token);
end;
$$;

grant execute on function public.account_register(text, text) to anon, authenticated;
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
add column if not exists account_id uuid;

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
         (p_player_key is not null and player_key = p_player_key)
         or (v_account_id is not null and account_id = v_account_id)
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

drop function if exists public.tycoon_create_room(text, text, text, integer);

create or replace function public.tycoon_create_room(
  p_nickname text,
  p_player_key text,
  p_victory_mode text default 'survivor',
  p_turn_limit integer default 30,
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
  v_nickname := left(btrim(p_nickname), 20);
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

  insert into public.tycoon_players (room_id, nickname, player_key, account_id)
  values (v_room.id, v_nickname, p_player_key, v_account_id)
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

create or replace function public.tycoon_join_room(
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
  v_room public.tycoon_rooms%rowtype;
  v_player public.tycoon_players%rowtype;
  v_account_id uuid := public.game_account_id_from_token(p_account_token);
  v_nickname text;
  v_player_count integer;
begin
  v_nickname := left(btrim(p_nickname), 20);
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
             updated_at = now()
       where id = v_player.id
       returning *
       into v_player;

      return public.tycoon_room_bundle(v_room.code, v_player.id, null, p_account_token);
    end if;
  end if;

  insert into public.tycoon_players (room_id, nickname, player_key, account_id)
  values (v_room.id, v_nickname, p_player_key, v_account_id)
  on conflict (room_id, player_key)
  do update set
    nickname = excluded.nickname,
    account_id = coalesce(public.tycoon_players.account_id, excluded.account_id),
    updated_at = now()
  returning *
  into v_player;

  perform public.tycoon_add_log(v_room.id, v_player.nickname || ' 加入了游戏。', 'join');

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
       (p_player_key is not null and player_key = p_player_key)
       or (v_account_id is not null and account_id = v_account_id)
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
       (p_player_key is not null and player_key = p_player_key)
       or (v_account_id is not null and account_id = v_account_id)
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
       (p_player_key is not null and player_key = p_player_key)
       or (v_account_id is not null and account_id = v_account_id)
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
       (p_player_key is not null and player_key = p_player_key)
       or (v_account_id is not null and account_id = v_account_id)
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
       (p_player_key is not null and player_key = p_player_key)
       or (v_account_id is not null and account_id = v_account_id)
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
       (p_player_key is not null and player_key = p_player_key)
       or (v_account_id is not null and account_id = v_account_id)
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
begin
  select *
    into v_room
    from public.tycoon_rooms
   where code = upper(trim(p_room_code))
   for update;

  if not found then
    raise exception 'Room not found.';
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
       (p_player_key is not null and player_key = p_player_key)
       or (v_account_id is not null and account_id = v_account_id)
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
       (p_player_key is not null and player_key = p_player_key)
       or (v_account_id is not null and account_id = v_account_id)
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
       (p_player_key is not null and player_key = p_player_key)
       or (v_account_id is not null and account_id = v_account_id)
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
       (p_player_key is not null and player_key = p_player_key)
       or (v_account_id is not null and account_id = v_account_id)
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
       (p_player_key is not null and player_key = p_player_key)
       or (v_account_id is not null and account_id = v_account_id)
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
          from public.qa_players p
          join public.qa_rooms r on r.id = p.room_id
          where p.account_id = v_account_id
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
    ), '[]'::jsonb)
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

grant execute on function public.tycoon_create_room(text, text, text, integer, text) to anon, authenticated;
grant execute on function public.tycoon_get_room(text, uuid, text, text) to anon, authenticated;
grant execute on function public.tycoon_join_room(text, text, text, text) to anon, authenticated;
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
