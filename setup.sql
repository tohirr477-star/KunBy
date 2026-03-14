-- ══════════════════════════════════════════════
--  KUNBY v5 — Supabase Schema
-- ══════════════════════════════════════════════

-- 1. USERS
create table if not exists users (
  id           uuid primary key default gen_random_uuid(),
  phone        text unique,
  telegram_id  bigint unique,
  name         text not null default '',
  pass_hash    text,
  created_at   timestamptz default now()
);

-- 2. PROFILES
create table if not exists profiles (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid unique references users(id) on delete cascade,
  job           text,
  price         numeric default 0,
  exp           int default 0,
  city          text,
  district      text,
  bio           text,
  is_ready      boolean default false,
  rating        numeric(3,1) default 0,
  done_count    int default 0,
  review_count  int default 0,
  updated_at    timestamptz default now()
);

-- 3. JOBS
create table if not exists jobs (
  id          uuid primary key default gen_random_uuid(),
  from_id     uuid references users(id),
  to_id       uuid references users(id),
  title       text,
  description text,
  price       numeric default 0,
  job_date    date,
  job_time    time,
  city        text,
  district    text,
  address     text,
  status      text default 'pending'
              check (status in ('pending','active','done_worker','done','cancelled')),
  created_at  timestamptz default now()
);

-- 4. MESSAGES
create table if not exists messages (
  id          uuid primary key default gen_random_uuid(),
  from_id     uuid references users(id),
  to_id       uuid references users(id),
  text        text,
  is_read     boolean default false,
  created_at  timestamptz default now()
);

-- 5. REVIEWS
create table if not exists reviews (
  id          uuid primary key default gen_random_uuid(),
  from_id     uuid references users(id),
  to_id       uuid references users(id),
  job_id      uuid references jobs(id),
  stars       int check (stars between 1 and 5),
  text        text,
  created_at  timestamptz default now()
);

-- ── INDEXES ──────────────────────────────────
create index if not exists idx_jobs_from    on jobs(from_id);
create index if not exists idx_jobs_to      on jobs(to_id);
create index if not exists idx_msgs_from    on messages(from_id);
create index if not exists idx_msgs_to      on messages(to_id);
create index if not exists idx_reviews_to   on reviews(to_id);
create index if not exists idx_profiles_job on profiles(job);
create index if not exists idx_profiles_rdy on profiles(is_ready);

-- ── TRIGGERS ─────────────────────────────────

-- Rating yangilash (review qo'shilganda)
create or replace function update_rating()
returns trigger language plpgsql as $$
declare
  avg_r  numeric(3,1);
  cnt    int;
begin
  select round(avg(stars)::numeric,1), count(*)
    into avg_r, cnt
    from reviews where to_id = NEW.to_id;

  update profiles
    set rating=avg_r, review_count=cnt
    where user_id = NEW.to_id;
  return NEW;
end;$$;

drop trigger if exists trg_rating on reviews;
create trigger trg_rating
  after insert on reviews
  for each row execute function update_rating();

-- Done count (job done bo'lganda)
create or replace function update_done_count()
returns trigger language plpgsql as $$
begin
  if NEW.status='done' and OLD.status!='done' then
    update profiles set done_count=done_count+1 where user_id=NEW.to_id;
  end if;
  return NEW;
end;$$;

drop trigger if exists trg_done on jobs;
create trigger trg_done
  after update on jobs
  for each row execute function update_done_count();

-- ── WEBHOOK TRIGGERS → Edge Function ─────────

-- App config (webhook URL)
create table if not exists app_config (
  key   text primary key,
  value text
);

-- Webhook URL ni saqlash (deploy qilgandan keyin o'zgartiring)
insert into app_config(key,value)
  values('notify_url','https://YOUR_PROJECT.supabase.co/functions/v1/notify')
  on conflict(key) do nothing;

-- HTTP extension
create extension if not exists http with schema extensions;

-- Message webhook trigger
create or replace function notify_on_message()
returns trigger language plpgsql security definer as $$
declare
  url text;
  key text;
begin
  select value into url from app_config where key='notify_url';
  select value into key  from app_config where key='service_key';
  if url is null then return NEW; end if;

  perform extensions.http_post(
    url,
    json_build_object(
      'type','INSERT','table','messages','record',
      json_build_object(
        'id',NEW.id,'from_id',NEW.from_id,'to_id',NEW.to_id,
        'text',NEW.text,'created_at',NEW.created_at
      )
    )::text,
    'application/json'
  );
  return NEW;
exception when others then return NEW;
end;$$;

drop trigger if exists trg_notify_msg on messages;
create trigger trg_notify_msg
  after insert on messages
  for each row execute function notify_on_message();

-- Job status webhook trigger
create or replace function notify_on_job()
returns trigger language plpgsql security definer as $$
declare
  url text;
begin
  select value into url from app_config where key='notify_url';
  if url is null or NEW.status=OLD.status then return NEW; end if;

  perform extensions.http_post(
    url,
    json_build_object(
      'type','UPDATE','table','jobs',
      'record',     json_build_object('id',NEW.id,'from_id',NEW.from_id,'to_id',NEW.to_id,'title',NEW.title,'status',NEW.status),
      'old_record', json_build_object('id',OLD.id,'from_id',OLD.from_id,'to_id',OLD.to_id,'title',OLD.title,'status',OLD.status)
    )::text,
    'application/json'
  );
  return NEW;
exception when others then return NEW;
end;$$;

drop trigger if exists trg_notify_job on jobs;
create trigger trg_notify_job
  after update on jobs
  for each row execute function notify_on_job();

-- ── REALTIME ─────────────────────────────────
alter publication supabase_realtime add table messages;
alter publication supabase_realtime add table jobs;

-- ── RLS (Row Level Security) ─────────────────
-- Soddalashtirilgan: autentifikatsiya qilingan foydalanuvchilar o'qiy/yoza oladi
alter table users    enable row level security;
alter table profiles enable row level security;
alter table jobs     enable row level security;
alter table messages enable row level security;
alter table reviews  enable row level security;

-- users: hamma o'qiydi, o'zi o'zgartiradi
create policy if not exists "users_read"   on users for select using (true);
create policy if not exists "users_insert" on users for insert with check (true);
create policy if not exists "users_update" on users for update using (true);

-- profiles
create policy if not exists "profiles_read"   on profiles for select using (true);
create policy if not exists "profiles_insert" on profiles for insert with check (true);
create policy if not exists "profiles_update" on profiles for update using (true);

-- jobs
create policy if not exists "jobs_read"   on jobs for select using (true);
create policy if not exists "jobs_insert" on jobs for insert with check (true);
create policy if not exists "jobs_update" on jobs for update using (true);

-- messages
create policy if not exists "msgs_read"   on messages for select using (true);
create policy if not exists "msgs_insert" on messages for insert with check (true);

-- reviews
create policy if not exists "revs_read"   on reviews for select using (true);
create policy if not exists "revs_insert" on reviews for insert with check (true);

