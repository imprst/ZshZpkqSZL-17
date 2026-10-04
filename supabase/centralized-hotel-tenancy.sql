begin;

-- Prerequisites: the existing hospitality and Books migrations must already be applied.
do $$
declare
  sheraton_count integer;
  sheraton_id uuid;
begin
  select count(*), min(id)
    into sheraton_count, sheraton_id
  from public.books_organizations
  where name = 'Sheraton';

  if sheraton_count <> 1 then
    raise exception 'Expected exactly one books_organizations row named Sheraton; found %', sheraton_count;
  end if;
end;
$$;

create table if not exists public.hotel_tenants (
  organization_id uuid primary key references public.books_organizations(id) on delete restrict,
  display_name text not null,
  logo_url text,
  primary_color text not null default '#0f2747' check (primary_color ~ '^#[0-9A-Fa-f]{6}$'),
  accent_color text not null default '#e0b33f' check (accent_color ~ '^#[0-9A-Fa-f]{6}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.hotel_domains (
  hostname text primary key check (hostname = lower(hostname) and hostname !~ '[/:]'),
  organization_id uuid not null references public.hotel_tenants(organization_id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.hotel_domains drop constraint if exists hotel_domains_organization_id_key;
create index if not exists hotel_domains_organization_idx on public.hotel_domains (organization_id);

create or replace function public.set_hotel_tenant_updated_at()
returns trigger language plpgsql set search_path = public
as $$ begin new.updated_at = now(); return new; end; $$;

drop trigger if exists hotel_tenants_updated_at on public.hotel_tenants;
create trigger hotel_tenants_updated_at
before update on public.hotel_tenants
for each row execute function public.set_hotel_tenant_updated_at();

insert into public.hotel_tenants (organization_id, display_name)
select id, name
from public.books_organizations
where name = 'Sheraton'
on conflict (organization_id) do update set display_name = excluded.display_name;

-- Current Builder preview host. Add each real production hostname with the same statement,
-- replacing the hostname value only; never map one hostname to more than one hotel.
insert into public.hotel_domains (hostname, organization_id)
select '58b7ff56334d475b9935-prism-conduit-7jhqffqa.builderio.dev', id
from public.books_organizations
where name = 'Sheraton'
on conflict (hostname) do update set organization_id = excluded.organization_id;

create or replace function public.resolve_hotel_tenant(target_hostname text)
returns table (
  "organizationId" uuid,
  name text,
  "logoUrl" text,
  "primaryColor" text,
  "accentColor" text
)
language sql stable security definer set search_path = pg_catalog, public
as $$
  select tenant.organization_id, tenant.display_name, tenant.logo_url,
         tenant.primary_color, tenant.accent_color
  from public.hotel_domains domain
  join public.hotel_tenants tenant on tenant.organization_id = domain.organization_id
  where domain.hostname = lower(trim(target_hostname));
$$;

revoke all on function public.resolve_hotel_tenant(text) from public;
grant execute on function public.resolve_hotel_tenant(text) to anon, authenticated;

create or replace function public.is_hotel_member(target_organization_id uuid, target_user_id uuid default auth.uid())
returns boolean language sql stable security definer set search_path = pg_catalog, public
as $$
  select exists (
    select 1 from public.books_memberships membership
    where membership.organization_id = target_organization_id
      and membership.user_id = target_user_id
  );
$$;

create or replace function public.is_hotel_manager(target_organization_id uuid, target_user_id uuid default auth.uid())
returns boolean language sql stable security definer set search_path = pg_catalog, public
as $$
  select exists (
    select 1 from public.books_memberships membership
    where membership.organization_id = target_organization_id
      and membership.user_id = target_user_id
      and membership.role in ('owner', 'admin', 'manager')
  );
$$;

revoke all on function public.is_hotel_member(uuid, uuid) from public, anon, authenticated;
revoke all on function public.is_hotel_manager(uuid, uuid) from public, anon, authenticated;

-- Booking presentation configuration is one row per hotel, rather than one global row.
alter table public.hotel_booking_page_settings
  add column if not exists organization_id uuid references public.books_organizations(id) on delete restrict;

update public.hotel_booking_page_settings settings
set organization_id = sheraton.id
from public.books_organizations sheraton
where settings.organization_id is null and sheraton.name = 'Sheraton';

alter table public.hotel_booking_page_settings alter column organization_id set not null;
alter table public.hotel_booking_page_settings drop constraint if exists hotel_booking_page_settings_pkey;
alter table public.hotel_booking_page_settings add primary key (organization_id, id);

insert into public.hotel_booking_page_settings (organization_id, id, title, subtitle)
select id, true, 'Book Your Special Stay', 'Experience luxury, comfort, and personalized service. Every detail crafted to make your stay extraordinary.'
from public.books_organizations
where name = 'Sheraton'
on conflict (organization_id, id) do nothing;

alter table public.hotel_booking_offers
  add column if not exists organization_id uuid references public.books_organizations(id) on delete restrict;

update public.hotel_booking_offers offer
set organization_id = sheraton.id
from public.books_organizations sheraton
where offer.organization_id is null and sheraton.name = 'Sheraton';

alter table public.hotel_booking_offers alter column organization_id set not null;
create index if not exists hotel_booking_offers_organization_idx
  on public.hotel_booking_offers (organization_id, is_active, display_order);

-- Hospitality records must have exactly one owning hotel. Existing unscoped data is treated as Sheraton.
alter table public.complaints
  add column if not exists organization_id uuid references public.books_organizations(id) on delete restrict;
alter table public.special_event_plans
  add column if not exists organization_id uuid references public.books_organizations(id) on delete restrict;
alter table public.special_event_facilities
  add column if not exists organization_id uuid references public.books_organizations(id) on delete restrict;
alter table public.menu_carts
  add column if not exists organization_id uuid references public.books_organizations(id) on delete restrict;

update public.complaints row_data set organization_id = sheraton.id from public.books_organizations sheraton where row_data.organization_id is null and sheraton.name = 'Sheraton';
update public.tasks row_data set organization_id = sheraton.id from public.books_organizations sheraton where row_data.organization_id is null and sheraton.name = 'Sheraton';
update public.menu_items row_data set organization_id = sheraton.id from public.books_organizations sheraton where row_data.organization_id is null and sheraton.name = 'Sheraton';
update public.menu_orders row_data set organization_id = sheraton.id from public.books_organizations sheraton where row_data.organization_id is null and sheraton.name = 'Sheraton';
update public.special_events row_data set organization_id = sheraton.id from public.books_organizations sheraton where row_data.organization_id is null and sheraton.name = 'Sheraton';
update public.special_event_bookings row_data set organization_id = event.organization_id from public.special_events event where row_data.organization_id is null and row_data.event_id = event.id;
update public.special_event_plans row_data set organization_id = sheraton.id from public.books_organizations sheraton where row_data.organization_id is null and sheraton.name = 'Sheraton';
update public.special_event_facilities row_data set organization_id = sheraton.id from public.books_organizations sheraton where row_data.organization_id is null and sheraton.name = 'Sheraton';
update public.menu_carts row_data set organization_id = sheraton.id from public.books_organizations sheraton where row_data.organization_id is null and sheraton.name = 'Sheraton';

alter table public.complaints alter column organization_id set not null;
alter table public.tasks alter column organization_id set not null;
alter table public.menu_items alter column organization_id set not null;
alter table public.menu_orders alter column organization_id set not null;
alter table public.special_events alter column organization_id set not null;
alter table public.special_event_bookings alter column organization_id set not null;
alter table public.special_event_plans alter column organization_id set not null;
alter table public.special_event_facilities alter column organization_id set not null;
alter table public.menu_carts alter column organization_id set not null;

create index if not exists complaints_organization_idx on public.complaints (organization_id, created_at desc);
create index if not exists tasks_organization_idx on public.tasks (organization_id, created_at desc);
create index if not exists special_event_plans_organization_idx on public.special_event_plans (organization_id, created_at desc);
create index if not exists special_event_facilities_organization_idx on public.special_event_facilities (organization_id, is_active, display_order);
create index if not exists menu_carts_organization_idx on public.menu_carts (organization_id, user_id, status);

-- Reject accidental cross-hotel event bookings and prevent ownership changes after creation.
create or replace function public.enforce_hotel_ownership()
returns trigger language plpgsql security definer set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'UPDATE' and new.organization_id is distinct from old.organization_id then
    raise exception 'Hotel ownership cannot be changed';
  end if;
  return new;
end;
$$;

revoke all on function public.enforce_hotel_ownership() from public, anon, authenticated;

drop trigger if exists complaints_hotel_ownership on public.complaints;
create trigger complaints_hotel_ownership before update of organization_id on public.complaints for each row execute function public.enforce_hotel_ownership();
drop trigger if exists tasks_hotel_ownership on public.tasks;
create trigger tasks_hotel_ownership before update of organization_id on public.tasks for each row execute function public.enforce_hotel_ownership();
drop trigger if exists menu_items_hotel_ownership on public.menu_items;
create trigger menu_items_hotel_ownership before update of organization_id on public.menu_items for each row execute function public.enforce_hotel_ownership();
drop trigger if exists special_events_hotel_ownership on public.special_events;
create trigger special_events_hotel_ownership before update of organization_id on public.special_events for each row execute function public.enforce_hotel_ownership();

-- Membership-based policies protect confidential operational records. Public menus, published
-- rooms, and published events remain deliberately public, but the application filters them by tenant.
alter table public.complaints enable row level security;
alter table public.tasks enable row level security;
alter table public.hotel_booking_page_settings enable row level security;
alter table public.hotel_booking_offers enable row level security;
alter table public.special_event_plans enable row level security;
alter table public.special_event_facilities enable row level security;

-- Remove pre-existing broad policies before defining the tenant-aware policy set below.
do $$
declare
  target_table text;
  policy_name text;
begin
  foreach target_table in array array[
    'complaints', 'tasks', 'hotel_booking_page_settings', 'hotel_booking_offers',
    'special_event_plans', 'special_event_facilities'
  ] loop
    for policy_name in
      select policyname from pg_policies where schemaname = 'public' and tablename = target_table
    loop
      execute format('drop policy %I on public.%I', policy_name, target_table);
    end loop;
  end loop;
end;
$$;

drop policy if exists hotel_booking_settings_read on public.hotel_booking_page_settings;
create policy hotel_booking_settings_read on public.hotel_booking_page_settings
  for select to anon, authenticated using (true);
drop policy if exists hotel_booking_settings_manage on public.hotel_booking_page_settings;
create policy hotel_booking_settings_manage on public.hotel_booking_page_settings
  for all to authenticated using (public.is_hotel_manager(organization_id)) with check (public.is_hotel_manager(organization_id));

drop policy if exists hotel_booking_offers_read on public.hotel_booking_offers;
create policy hotel_booking_offers_read on public.hotel_booking_offers
  for select to anon, authenticated using (is_active and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at > now()));
drop policy if exists hotel_booking_offers_manage on public.hotel_booking_offers;
create policy hotel_booking_offers_manage on public.hotel_booking_offers
  for all to authenticated using (public.is_hotel_manager(organization_id)) with check (public.is_hotel_manager(organization_id));

drop policy if exists complaints_guest_insert on public.complaints;
create policy complaints_guest_insert on public.complaints
  for insert to authenticated with check (user_id = auth.uid());
drop policy if exists complaints_guest_read on public.complaints;
create policy complaints_guest_read on public.complaints
  for select to authenticated using (user_id = auth.uid() or public.is_hotel_manager(organization_id));
drop policy if exists complaints_manager_update on public.complaints;
create policy complaints_manager_update on public.complaints
  for update to authenticated using (public.is_hotel_manager(organization_id)) with check (public.is_hotel_manager(organization_id));

drop policy if exists tasks_hotel_read on public.tasks;
create policy tasks_hotel_read on public.tasks
  for select to authenticated using (public.is_hotel_member(organization_id) or assigned_to = auth.uid());
drop policy if exists tasks_hotel_write on public.tasks;
create policy tasks_hotel_write on public.tasks
  for all to authenticated using (public.is_hotel_manager(organization_id)) with check (public.is_hotel_manager(organization_id));

drop policy if exists event_plans_hotel_read on public.special_event_plans;
create policy event_plans_hotel_read on public.special_event_plans
  for select to authenticated using (user_id = auth.uid() or public.is_hotel_manager(organization_id));
drop policy if exists event_plans_hotel_insert on public.special_event_plans;
create policy event_plans_hotel_insert on public.special_event_plans
  for insert to authenticated with check (user_id = auth.uid());
drop policy if exists event_plans_hotel_manage on public.special_event_plans;
create policy event_plans_hotel_manage on public.special_event_plans
  for update to authenticated using (user_id = auth.uid() or public.is_hotel_manager(organization_id)) with check (user_id = auth.uid() or public.is_hotel_manager(organization_id));

drop policy if exists event_facilities_hotel_read on public.special_event_facilities;
create policy event_facilities_hotel_read on public.special_event_facilities
  for select to anon, authenticated using (is_active);
drop policy if exists event_facilities_hotel_manage on public.special_event_facilities;
create policy event_facilities_hotel_manage on public.special_event_facilities
  for all to authenticated using (public.is_hotel_manager(organization_id)) with check (public.is_hotel_manager(organization_id));

commit;
