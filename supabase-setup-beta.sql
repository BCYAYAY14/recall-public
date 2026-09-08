create sequence if not exists sync_seq as bigint start 1;

create table if not exists folder (
  id          uuid primary key,
  user_id     uuid not null default auth.uid(),
  name        text not null,
  emoji       text not null default '📁',
  position    int not null default 0,
  created_at  timestamptz not null,
  updated_at  timestamptz not null,
  deleted_at  timestamptz,
  synced_seq  bigint not null default nextval('sync_seq')
);

create table if not exists notebook (
  id          uuid primary key,
  user_id     uuid not null default auth.uid(),
  folder_id   uuid references folder(id),
  name        text not null,
  emoji       text not null default '📚',
  position    int not null default 0,
  created_at  timestamptz not null,
  updated_at  timestamptz not null,
  deleted_at  timestamptz,
  synced_seq  bigint not null default nextval('sync_seq')
);

create table if not exists note (
  id            uuid primary key,
  user_id       uuid not null default auth.uid(),
  notebook_id   uuid not null references notebook(id),
  parent_id     uuid references note(id),
  position      int not null default 0,
  front         text,
  back          text,
  cloze_text    text,
  tags          text not null default '',
  unreviewed    boolean not null default false,
  occ_mode      text,
  typed_answer  boolean not null default false,
  spans         text,
  created_at    timestamptz not null,
  updated_at    timestamptz not null,
  deleted_at    timestamptz,
  synced_seq    bigint not null default nextval('sync_seq')
);

create table if not exists dictionary (
  id          uuid primary key,
  user_id     uuid not null default auth.uid(),
  word        text not null,
  created_at  timestamptz not null,
  updated_at  timestamptz not null,
  deleted_at  timestamptz,
  synced_seq  bigint not null default nextval('sync_seq')
);

create table if not exists card (
  id              uuid primary key,
  user_id         uuid not null default auth.uid(),
  note_id         uuid not null references note(id),
  cloze_ordinal   int,
  flag            int not null default 0,
  suspended       boolean not null default false,
  stability       double precision not null default 0,
  difficulty      double precision not null default 0,
  due             timestamptz not null,
  state           text not null default 'new',
  last_review_at  timestamptz,
  introduced_on   timestamptz,
  reps            int not null default 0,
  lapses          int not null default 0,
  q_snapshot      text,
  a_snapshot      text,
  detached        boolean not null default false,
  updated_at      timestamptz not null,
  deleted_at      timestamptz,
  synced_seq      bigint not null default nextval('sync_seq')
);

create table if not exists grade_event (
  id           uuid primary key,
  user_id      uuid not null default auth.uid(),
  card_id      uuid not null references card(id),
  rating       int not null,
  reviewed_at  timestamptz not null,
  device_id    text not null,
  synced_seq   bigint not null default nextval('sync_seq')
);

create table if not exists media (
  id          uuid primary key,
  user_id     uuid not null default auth.uid(),
  note_id     uuid not null references note(id),
  rel_path    text not null,
  mime        text not null,
  bytes_sha   text not null,
  created_at  timestamptz not null,
  updated_at  timestamptz not null,
  deleted_at  timestamptz,
  display_width double precision,
  crop        text,
  synced_seq  bigint not null default nextval('sync_seq')
);

create table if not exists occlusion (
  id           uuid primary key,
  user_id      uuid not null default auth.uid(),
  note_id      uuid not null references note(id),
  ordinal      int not null,
  x            double precision not null,
  y            double precision not null,
  w            double precision not null,
  h            double precision not null,
  label        text not null default '',
  media_id     uuid,
  rotation     double precision not null default 0,
  points_json  text,
  z            int not null default 0,
  created_at   timestamptz not null,
  updated_at   timestamptz not null,
  deleted_at   timestamptz,
  synced_seq   bigint not null default nextval('sync_seq')
);

alter table media add column if not exists display_width double precision;
alter table media add column if not exists crop text;

alter table media add column if not exists latex text;

alter table note add column if not exists kind text not null default 'paragraph';
alter table note add column if not exists attrs text;

create table if not exists kv (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid(),
  key         text not null,
  value       text not null,
  updated_at  timestamptz not null default now()
);

create or replace function sync_stamp_lww() returns trigger as $$
begin
  if (tg_op = 'UPDATE') then
    if (new.updated_at < old.updated_at) then
      return null;
    end if;
  end if;
  new.synced_seq := nextval('sync_seq');
  return new;
end;
$$ language plpgsql;

create or replace function sync_stamp() returns trigger as $$
begin
  new.synced_seq := nextval('sync_seq');
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_sync on folder;
drop trigger if exists trg_sync on notebook;
drop trigger if exists trg_sync on note;
drop trigger if exists trg_sync on card;
drop trigger if exists trg_sync on media;
drop trigger if exists trg_sync on occlusion;
drop trigger if exists trg_sync on grade_event;
drop trigger if exists trg_sync on dictionary;

create trigger trg_sync before insert or update on folder
  for each row execute function sync_stamp_lww();
create trigger trg_sync before insert or update on notebook
  for each row execute function sync_stamp_lww();
create trigger trg_sync before insert or update on note
  for each row execute function sync_stamp_lww();
create trigger trg_sync before insert or update on card
  for each row execute function sync_stamp_lww();
create trigger trg_sync before insert or update on media
  for each row execute function sync_stamp_lww();
create trigger trg_sync before insert or update on occlusion
  for each row execute function sync_stamp_lww();
create trigger trg_sync before insert or update on grade_event
  for each row execute function sync_stamp();
create trigger trg_sync before insert or update on dictionary
  for each row execute function sync_stamp_lww();

create or replace function pull_since(marks jsonb, page int default 1000)
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  select jsonb_build_object(
    'folder', (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from (
        select * from folder
        where synced_seq > coalesce((marks->>'folder')::bigint, 0)
        order by synced_seq limit page) t),
    'notebook', (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from (
        select * from notebook
        where synced_seq > coalesce((marks->>'notebook')::bigint, 0)
        order by synced_seq limit page) t),
    'note', (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from (
        select * from note
        where synced_seq > coalesce((marks->>'note')::bigint, 0)
        order by synced_seq limit page) t),
    'card', (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from (
        select * from card
        where synced_seq > coalesce((marks->>'card')::bigint, 0)
        order by synced_seq limit page) t),
    'grade_event', (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from (
        select * from grade_event
        where synced_seq > coalesce((marks->>'grade_event')::bigint, 0)
        order by synced_seq limit page) t),
    'media', (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from (
        select * from media
        where synced_seq > coalesce((marks->>'media')::bigint, 0)
        order by synced_seq limit page) t),
    'occlusion', (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from (
        select * from occlusion
        where synced_seq > coalesce((marks->>'occlusion')::bigint, 0)
        order by synced_seq limit page) t),
    'dictionary', (select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from (
        select * from dictionary
        where synced_seq > coalesce((marks->>'dictionary')::bigint, 0)
        order by synced_seq limit page) t)
  );
$$;

grant execute on function pull_since(jsonb, int) to authenticated;

create index if not exists idx_notebook_folder   on notebook(folder_id);
create index if not exists idx_note_notebook     on note(notebook_id);
create index if not exists idx_note_parent       on note(parent_id);
create index if not exists idx_card_note         on card(note_id);
create index if not exists idx_grade_event_card  on grade_event(card_id);
create index if not exists idx_media_note        on media(note_id);
create index if not exists idx_occlusion_note    on occlusion(note_id);

create index if not exists idx_folder_sync      on folder(user_id, synced_seq);
create index if not exists idx_notebook_sync    on notebook(user_id, synced_seq);
create index if not exists idx_note_sync        on note(user_id, synced_seq);
create index if not exists idx_card_sync        on card(user_id, synced_seq);
create index if not exists idx_media_sync       on media(user_id, synced_seq);
create index if not exists idx_occlusion_sync   on occlusion(user_id, synced_seq);
create index if not exists idx_dictionary_sync  on dictionary(user_id, synced_seq);
create index if not exists idx_grade_event_sync on grade_event(user_id, synced_seq);

grant usage on schema public to anon, authenticated;
grant usage, select on sequence sync_seq to authenticated;

grant select, insert, update on folder      to authenticated;
grant select, insert, update on notebook    to authenticated;
grant select, insert, update on note        to authenticated;
grant select, insert, update on card        to authenticated;
grant select, insert, update on grade_event to authenticated;
grant select, insert, update on media       to authenticated;
grant select, insert, update on occlusion   to authenticated;
grant select, insert, update on dictionary  to authenticated;
grant select, insert, update on kv          to authenticated;

revoke delete on folder, notebook, note, card, grade_event, media, occlusion, dictionary, kv
  from authenticated;

grant select on kv to anon;

alter table folder      enable row level security;
alter table notebook    enable row level security;
alter table note        enable row level security;
alter table card        enable row level security;
alter table grade_event enable row level security;
alter table media       enable row level security;
alter table occlusion   enable row level security;
alter table dictionary  enable row level security;
alter table kv          enable row level security;

drop policy if exists "own rows" on folder;
drop policy if exists "own rows" on notebook;
drop policy if exists "own rows" on note;
drop policy if exists "own rows" on card;
drop policy if exists "own rows" on grade_event;
drop policy if exists "own rows" on media;
drop policy if exists "own rows" on occlusion;
drop policy if exists "own rows" on dictionary;
drop policy if exists "own rows" on kv;

create policy "own rows" on folder      for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "own rows" on notebook    for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "own rows" on note        for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "own rows" on card        for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "own rows" on grade_event for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "own rows" on media       for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "own rows" on dictionary  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "own rows" on occlusion   for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "own rows" on kv          for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

do $$
declare t text;
begin
  foreach t in array array['folder','notebook','note','card','grade_event','media','occlusion']
  loop
    execute format('alter table %I replica identity full', t);
    begin
      execute format('alter publication supabase_realtime add table %I', t);
    exception
      when duplicate_object then null;
    end;
  end loop;
end $$;

create or replace function purge_tombstones(max_age_days int default 30)
returns table (table_name text, removed bigint)
language plpgsql
security invoker
as $$
declare
  t text;
  n bigint;
begin
  foreach t in array array['note','card','notebook','folder',
                           'media','occlusion','dictionary']
  loop
    execute format(
      'delete from %I where user_id = auth.uid()
         and deleted_at is not null
         and deleted_at < now() - ($1 || '' days'')::interval', t)
      using max_age_days;
    get diagnostics n = row_count;
    if n > 0 then
      table_name := t; removed := n; return next;
    end if;
  end loop;
end $$;

grant execute on function purge_tombstones(int) to authenticated;

insert into storage.buckets (id, name, public)
values ('media', 'media', false)
on conflict (id) do nothing;

drop policy if exists "own objects" on storage.objects;
create policy "own objects" on storage.objects for all
  using      (bucket_id = 'media' and auth.uid()::text = (storage.foldername(name))[1])
  with check (bucket_id = 'media' and auth.uid()::text = (storage.foldername(name))[1]);

select c.relname                                             as table_name,
       c.relrowsecurity                                      as rls,
       has_table_privilege('authenticated', c.oid, 'SELECT')  as can_read,
       has_table_privilege('authenticated', c.oid, 'INSERT')  as can_write,
       count(a.attname)                                      as columns,
       bool_or(a.attname = 'synced_seq')                     as has_seq,
       exists (select 1 from pg_trigger g
               where g.tgrelid = c.oid and g.tgname = 'trg_sync') as has_trigger
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
where n.nspname = 'public'
  and c.relname in ('folder','notebook','note','card','grade_event','media','occlusion','dictionary','kv')
group by c.relname, c.relrowsecurity, c.oid
order by c.relname;
