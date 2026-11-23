-- Givre : partie amis. À coller dans Supabase > SQL Editor > New query, puis Run.
-- On peut le relancer sans risque : il ne supprime aucune donnée.

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  pseudo text not null check (char_length(pseudo) between 2 and 20),
  friend_code text not null unique default upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6)),
  created_at timestamptz not null default now()
);
create unique index if not exists profiles_pseudo_lower on public.profiles (lower(pseudo));

create table if not exists public.friends (
  user_id uuid not null references public.profiles(id) on delete cascade,
  friend_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, friend_id)
);

create table if not exists public.stats (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create table if not exists public.duos (
  a uuid not null references public.profiles(id) on delete cascade,
  b uuid not null references public.profiles(id) on delete cascade,
  start_date date not null,
  created_at timestamptz not null default now(),
  primary key (a, b),
  check (a < b)
);

alter table public.profiles enable row level security;
alter table public.friends  enable row level security;
alter table public.stats    enable row level security;
alter table public.duos     enable row level security;

create or replace function public.is_friend(other uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.friends where user_id = auth.uid() and friend_id = other);
$$;

-- Profils : je vois le mien et ceux de mes amis, je ne modifie que le mien
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_friend(id));
drop policy if exists profiles_insert on public.profiles;
create policy profiles_insert on public.profiles for insert to authenticated
  with check (id = auth.uid());
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- Amis : je vois seulement ma liste (les ajouts passent par add_friend)
drop policy if exists friends_select on public.friends;
create policy friends_select on public.friends for select to authenticated
  using (user_id = auth.uid());

-- Stats : je vois les miennes et celles de mes amis, je ne modifie que les miennes
drop policy if exists stats_select on public.stats;
create policy stats_select on public.stats for select to authenticated
  using (user_id = auth.uid() or public.is_friend(user_id));
drop policy if exists stats_insert on public.stats;
create policy stats_insert on public.stats for insert to authenticated
  with check (user_id = auth.uid());
drop policy if exists stats_update on public.stats;
create policy stats_update on public.stats for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Duos : je vois et j'arrête seulement les miens
drop policy if exists duos_select on public.duos;
create policy duos_select on public.duos for select to authenticated
  using (auth.uid() in (a, b));
drop policy if exists duos_delete on public.duos;
create policy duos_delete on public.duos for delete to authenticated
  using (auth.uid() in (a, b));

-- Ajouter un ami avec son code (amitié dans les deux sens)
create or replace function public.add_friend(code text) returns json
language plpgsql security definer set search_path = public as $$
declare t public.profiles;
begin
  if auth.uid() is null then raise exception 'pas_connecte'; end if;
  select * into t from public.profiles where friend_code = upper(trim(code));
  if not found then raise exception 'code_inconnu'; end if;
  if t.id = auth.uid() then raise exception 'ton_code'; end if;
  insert into public.friends (user_id, friend_id) values (auth.uid(), t.id) on conflict do nothing;
  insert into public.friends (user_id, friend_id) values (t.id, auth.uid()) on conflict do nothing;
  return json_build_object('id', t.id, 'pseudo', t.pseudo);
end; $$;

create or replace function public.remove_friend(fid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from public.friends where (user_id = auth.uid() and friend_id = fid) or (user_id = fid and friend_id = auth.uid());
  delete from public.duos where a = least(auth.uid(), fid) and b = greatest(auth.uid(), fid);
end; $$;

create or replace function public.start_duo(fid uuid, start_on date) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_friend(fid) then raise exception 'pas_ami'; end if;
  insert into public.duos (a, b, start_date) values (least(auth.uid(), fid), greatest(auth.uid(), fid), start_on)
  on conflict (a, b) do nothing;
end; $$;

revoke all on function public.add_friend(text) from public, anon;
revoke all on function public.remove_friend(uuid) from public, anon;
revoke all on function public.start_duo(uuid, date) from public, anon;
grant execute on function public.add_friend(text) to authenticated;
grant execute on function public.remove_friend(uuid) to authenticated;
grant execute on function public.start_duo(uuid, date) to authenticated;
grant execute on function public.is_friend(uuid) to authenticated;
