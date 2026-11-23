-- Givre v3 : groupes (2 à 10 personnes) et classement des groupes.
-- À coller dans Supabase > SQL Editor > New query, puis Run. Peut être relancé sans risque.
-- Il faut avoir lancé supabase.sql et supabase-v2.sql avant.

-- 1. Tables
create table if not exists public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 24),
  owner uuid not null references public.profiles(id) on delete cascade,
  program jsonb not null,
  start_date date not null,
  created_at timestamptz not null default now()
);
create table if not exists public.group_members (
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'invited' check (status in ('invited','active')),
  invited_by uuid references public.profiles(id) on delete set null,
  joined_on date,
  primary key (group_id, user_id)
);
create index if not exists group_members_user on public.group_members(user_id);
alter table public.groups enable row level security;
alter table public.group_members enable row level security;

-- 2. Fonctions d'accès (security definer pour éviter les boucles de règles)
create or replace function public.is_member(gid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.group_members where group_id = gid and user_id = auth.uid());
$$;
create or replace function public.shares_group(other uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.group_members m1 join public.group_members m2 on m1.group_id = m2.group_id
    where m1.user_id = auth.uid() and m2.user_id = other
  );
$$;
grant execute on function public.is_member(uuid) to authenticated;
grant execute on function public.shares_group(uuid) to authenticated;

drop policy if exists groups_select on public.groups;
create policy groups_select on public.groups for select to authenticated using (public.is_member(id));
drop policy if exists gm_select on public.group_members;
create policy gm_select on public.group_members for select to authenticated using (public.is_member(group_id));

-- Les membres d'un même groupe voient le pseudo et la série des autres, même sans être amis
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_friend(id) or public.shares_group(id));
drop policy if exists stats_select on public.stats;
create policy stats_select on public.stats for select to authenticated
  using (user_id = auth.uid() or public.is_friend(user_id) or public.shares_group(user_id));

grant select on public.groups to authenticated;
grant select on public.group_members to authenticated;

-- 3. Actions
-- Un seul défi 90 jours à la fois : rejoindre ou créer un groupe fait quitter les autres groupes actifs
create or replace function public._leave_active_groups(keep uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from public.group_members where user_id = auth.uid() and status = 'active' and group_id is distinct from keep;
  delete from public.groups g where not exists (select 1 from public.group_members m where m.group_id = g.id and m.status = 'active');
end; $$;
revoke all on function public._leave_active_groups(uuid) from public, anon, authenticated;

create or replace function public.create_group(gname text, members uuid[], prog jsonb, start_on date) returns uuid
language plpgsql security definer set search_path = public as $$
declare gid uuid; m uuid;
begin
  if auth.uid() is null then raise exception 'pas_connecte'; end if;
  if members is null or array_length(members, 1) is null or array_length(members, 1) > 9 then raise exception 'taille_groupe'; end if;
  foreach m in array members loop
    if m = auth.uid() or not public.is_friend(m) then raise exception 'pas_ami'; end if;
  end loop;
  perform public._leave_active_groups(null);
  insert into public.groups (name, owner, program, start_date) values (left(trim(gname), 24), auth.uid(), prog, start_on) returning id into gid;
  insert into public.group_members (group_id, user_id, status, invited_by, joined_on) values (gid, auth.uid(), 'active', auth.uid(), start_on);
  insert into public.group_members (group_id, user_id, status, invited_by)
    select distinct gid, x, 'invited', auth.uid() from unnest(members) as x;
  return gid;
end; $$;

create or replace function public.accept_group(gid uuid, joined date) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.group_members set status = 'active', joined_on = joined
  where group_id = gid and user_id = auth.uid() and status = 'invited';
  if not found then raise exception 'pas_de_demande'; end if;
  perform public._leave_active_groups(gid);
end; $$;

-- Quitter un groupe ou refuser une invitation. Le groupe disparaît quand plus personne n'y est actif.
create or replace function public.leave_group(gid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from public.group_members where group_id = gid and user_id = auth.uid();
  delete from public.groups g where g.id = gid and not exists (select 1 from public.group_members m where m.group_id = gid and m.status = 'active');
end; $$;

revoke all on function public.create_group(text, uuid[], jsonb, date) from public, anon;
revoke all on function public.accept_group(uuid, date) from public, anon;
revoke all on function public.leave_group(uuid) from public, anon;
grant execute on function public.create_group(text, uuid[], jsonb, date) to authenticated;
grant execute on function public.accept_group(uuid, date) to authenticated;
grant execute on function public.leave_group(uuid) to authenticated;

-- 4. Classement des groupes (tous les groupes de l'appli avec au moins 2 membres actifs)
-- Chaque membre publie la série de son groupe dans stats.data->'groups' ; l'appli garde la plus récente.
drop function if exists public.board_groups();
create function public.board_groups() returns table (id uuid, name text, pseudos text[], entries jsonb)
language sql stable security definer set search_path = public as $$
  select g.id, g.name,
    array_agg(p.pseudo order by m.joined_on, p.pseudo),
    coalesce(jsonb_agg(e.val) filter (where e.val is not null), '[]'::jsonb)
  from public.groups g
  join public.group_members m on m.group_id = g.id and m.status = 'active'
  join public.profiles p on p.id = m.user_id
  left join public.stats s on s.user_id = m.user_id
  left join lateral (
    select x as val from jsonb_array_elements(coalesce(s.data->'groups', '[]'::jsonb)) x where x->>'id' = g.id::text limit 1
  ) e on true
  group by g.id, g.name
  having count(*) >= 2
  limit 300;
$$;
revoke all on function public.board_groups() from public, anon;
grant execute on function public.board_groups() to authenticated;
