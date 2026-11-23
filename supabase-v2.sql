-- Givre v2 : confidentialité, demandes de duo, classements.
-- À coller dans Supabase > SQL Editor > New query, puis Run. Peut être relancé sans risque.

-- 1. Confidentialité du profil
alter table public.profiles add column if not exists visibility text not null default 'public';
alter table public.profiles drop constraint if exists profiles_visibility_check;
alter table public.profiles add constraint profiles_visibility_check check (visibility in ('public','private','custom'));

-- Liste des amis autorisés en mode « personnalisé »
create table if not exists public.viewers (
  owner uuid not null references public.profiles(id) on delete cascade,
  viewer uuid not null references public.profiles(id) on delete cascade,
  primary key (owner, viewer)
);
alter table public.viewers enable row level security;
drop policy if exists viewers_owner on public.viewers;
create policy viewers_owner on public.viewers for all to authenticated
  using (owner = auth.uid()) with check (owner = auth.uid());
grant select, insert, delete on public.viewers to authenticated;

-- Détails (défi en cours, défis courts) : visibles seulement si le profil le permet
create table if not exists public.stats_detail (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.stats_detail enable row level security;

create or replace function public.can_see_detail(owner_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select owner_id = auth.uid() or (
    public.is_friend(owner_id) and exists (
      select 1 from public.profiles p where p.id = owner_id and (
        p.visibility = 'public'
        or (p.visibility = 'custom' and exists (select 1 from public.viewers v where v.owner = owner_id and v.viewer = auth.uid()))
      )
    )
  );
$$;
grant execute on function public.can_see_detail(uuid) to authenticated;

drop policy if exists detail_select on public.stats_detail;
create policy detail_select on public.stats_detail for select to authenticated using (public.can_see_detail(user_id));
drop policy if exists detail_insert on public.stats_detail;
create policy detail_insert on public.stats_detail for insert to authenticated with check (user_id = auth.uid());
drop policy if exists detail_update on public.stats_detail;
create policy detail_update on public.stats_detail for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select, insert, update on public.stats_detail to authenticated;

-- 2. Demandes de duo (le pote doit accepter)
alter table public.duos add column if not exists status text not null default 'active';
alter table public.duos add column if not exists requested_by uuid references public.profiles(id) on delete cascade;
alter table public.duos drop constraint if exists duos_status_check;
alter table public.duos add constraint duos_status_check check (status in ('pending','active'));

create or replace function public.start_duo(fid uuid, start_on date) returns void
language plpgsql security definer set search_path = public as $$
declare d public.duos;
begin
  if not public.is_friend(fid) then raise exception 'pas_ami'; end if;
  select * into d from public.duos where a = least(auth.uid(), fid) and b = greatest(auth.uid(), fid);
  if found then
    -- Si le pote m'avait déjà invité, demander revient à accepter
    if d.status = 'pending' and d.requested_by = fid then
      update public.duos set status = 'active', start_date = start_on where a = d.a and b = d.b;
    end if;
    return;
  end if;
  insert into public.duos (a, b, start_date, status, requested_by)
  values (least(auth.uid(), fid), greatest(auth.uid(), fid), start_on, 'pending', auth.uid());
end; $$;

create or replace function public.accept_duo(fid uuid, start_on date) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.duos set status = 'active', start_date = start_on
  where a = least(auth.uid(), fid) and b = greatest(auth.uid(), fid) and status = 'pending' and requested_by = fid;
  if not found then raise exception 'pas_de_demande'; end if;
end; $$;
revoke all on function public.accept_duo(uuid, date) from public, anon;
grant execute on function public.accept_duo(uuid, date) to authenticated;

-- 3. Classements (pseudo et flammes de tous les joueurs, rien d'autre)
create or replace function public.board_solo() returns table (id uuid, pseudo text, streak int, best int, day text, done boolean)
language sql stable security definer set search_path = public as $$
  select p.id, p.pseudo,
         coalesce((s.data->>'streak')::int, 0), coalesce((s.data->>'best')::int, 0),
         s.data->>'day', coalesce((s.data->'today'->>'full')::boolean, false)
  from public.profiles p join public.stats s on s.user_id = p.id
  order by coalesce((s.data->>'streak')::int, 0) desc
  limit 300;
$$;

create or replace function public.board_groups() returns table (a uuid, b uuid, pseudo_a text, pseudo_b text, ea jsonb, eb jsonb)
language sql stable security definer set search_path = public as $$
  select d.a, d.b, pa.pseudo, pb.pseudo,
    (select e from jsonb_array_elements(coalesce(sa.data->'duos','[]'::jsonb)) e where e->>'with' = d.b::text limit 1),
    (select e from jsonb_array_elements(coalesce(sb.data->'duos','[]'::jsonb)) e where e->>'with' = d.a::text limit 1)
  from public.duos d
  join public.profiles pa on pa.id = d.a
  join public.profiles pb on pb.id = d.b
  left join public.stats sa on sa.user_id = d.a
  left join public.stats sb on sb.user_id = d.b
  where d.status = 'active'
  limit 300;
$$;
revoke all on function public.board_solo() from public, anon;
revoke all on function public.board_groups() from public, anon;
grant execute on function public.board_solo() to authenticated;
grant execute on function public.board_groups() to authenticated;
