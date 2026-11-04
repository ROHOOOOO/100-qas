-- Upgrade existing 同词相遇 rooms to 2–6 players. Safe to rerun.
-- Requires the original words tables and normalization helpers.
begin;
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
