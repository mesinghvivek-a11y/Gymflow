begin;
create extension if not exists pgcrypto;

create table public.gyms (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 2 and 120),
  timezone text not null default 'Asia/Kolkata',
  currency char(3) not null default 'INR' check (currency='INR'),
  whatsapp_reminder_local_time time not null default time '10:00',
  created_at timestamptz not null default now(),
  unique(id)
);
create table public.gym_users (
  gym_id uuid not null references public.gyms(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  role text not null check (role in ('owner','manager','staff','viewer')),
  created_at timestamptz not null default now(),
  primary key(gym_id,user_id)
);
create table public.gym_member_counters (
  gym_id uuid primary key references public.gyms(id) on delete restrict,
  next_member_number integer not null default 10000 check(next_member_number between 10000 and 100000),
  updated_at timestamptz not null default now()
);
create table public.gym_invoice_counters (
  gym_id uuid primary key references public.gyms(id) on delete restrict,
  next_invoice_number bigint not null default 1 check(next_invoice_number>0),
  updated_at timestamptz not null default now()
);
create table public.members (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete restrict,
  member_number char(5) not null check(member_number ~ '^[0-9]{5}$'),
  full_name text not null check(length(trim(full_name)) between 1 and 120),
  phone_e164 text not null check(phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  address text,
  photo_path text,
  request_key uuid,
  whatsapp_opt_in boolean not null default false,
  whatsapp_opted_in_at timestamptz,
  whatsapp_opted_out_at timestamptz,
  whatsapp_consent_source text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz,
  check(not whatsapp_opt_in or whatsapp_opted_in_at is not null),
  unique(gym_id,member_number), unique(gym_id,id), unique(gym_id,request_key)
);
create table public.membership_plans (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete restrict,
  name text not null check(length(trim(name)) between 2 and 100),
  duration_months integer check(duration_months between 1 and 120),
  duration_days integer check(duration_days between 1 and 3650),
  price_paise bigint not null check(price_paise>=0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check((duration_months is not null)::int+(duration_days is not null)::int=1),
  unique(gym_id,id)
);
create table public.memberships (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete restrict,
  member_id uuid not null,
  plan_id uuid,
  plan_name_snapshot text not null,
  duration_months_snapshot integer,
  duration_days_snapshot integer,
  price_paise_snapshot bigint not null check(price_paise_snapshot>=0),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  payment_status text not null default 'pending' check(payment_status in ('pending','partial','paid','waived','cancelled')),
  cycle_version integer not null default 1 check(cycle_version>0),
  request_key uuid not null,
  paused_at timestamptz,
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(ends_at>starts_at),
  check((duration_months_snapshot is not null)::int+(duration_days_snapshot is not null)::int=1),
  foreign key(gym_id,member_id) references public.members(gym_id,id) on delete restrict,
  foreign key(gym_id,plan_id) references public.membership_plans(gym_id,id) on delete restrict,
  unique(gym_id,id), unique(gym_id,request_key)
);
create index memberships_due_idx on public.memberships(gym_id,ends_at) where paused_at is null and cancelled_at is null;
create table public.invoices (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete restrict,
  member_id uuid not null,
  membership_id uuid,
  invoice_number text not null,
  subtotal_paise bigint not null check(subtotal_paise>=0),
  discount_paise bigint not null default 0 check(discount_paise>=0),
  total_paise bigint not null check(total_paise>=0),
  status text not null check(status in ('open','partially_paid','paid','void','refunded')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(total_paise=subtotal_paise-discount_paise),
  foreign key(gym_id,member_id) references public.members(gym_id,id) on delete restrict,
  foreign key(gym_id,membership_id) references public.memberships(gym_id,id) on delete restrict,
  unique(gym_id,id), unique(gym_id,invoice_number)
);
create table public.invoice_items (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null,
  invoice_id uuid not null,
  description text not null,
  quantity numeric(12,3) not null default 1 check(quantity>0),
  unit_price_paise bigint not null check(unit_price_paise>=0),
  line_total_paise bigint not null check(line_total_paise>=0),
  foreign key(gym_id,invoice_id) references public.invoices(gym_id,id) on delete restrict,
  unique(gym_id,id)
);
create table public.payments (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete restrict,
  member_id uuid not null,
  provider text not null check(provider in ('manual_cash','manual_upi','manual_bank','razorpay','platform_razorpay')),
  provider_account_id uuid,
  provider_payment_id text,
  idempotency_key uuid,
  amount_paise bigint not null check(amount_paise>0),
  currency char(3) not null default 'INR' check(currency='INR'),
  status text not null check(status in ('pending','succeeded','failed','refunded','partially_refunded','needs_review')),
  received_at timestamptz,
  notes text,
  created_by uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  foreign key(gym_id,member_id) references public.members(gym_id,id) on delete restrict,
  unique(gym_id,id),
  unique(gym_id,idempotency_key)
);
create unique index payments_provider_ref_unique on public.payments(provider,provider_account_id,provider_payment_id) where provider_payment_id is not null;
create table public.payment_allocations (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null,
  payment_id uuid not null,
  invoice_id uuid not null,
  amount_paise bigint not null check(amount_paise>0),
  created_at timestamptz not null default now(),
  foreign key(gym_id,payment_id) references public.payments(gym_id,id) on delete restrict,
  foreign key(gym_id,invoice_id) references public.invoices(gym_id,id) on delete restrict,
  unique(gym_id,id)
);
create table public.refunds (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null,
  payment_id uuid not null,
  amount_paise bigint not null check(amount_paise>0),
  status text not null check(status in ('pending','succeeded','failed')),
  provider_refund_id text,
  reason text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  foreign key(gym_id,payment_id) references public.payments(gym_id,id) on delete restrict,
  unique(gym_id,id)
);
create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete restrict,
  actor_user_id uuid references auth.users(id) on delete restrict,
  action text not null,
  entity_type text not null,
  entity_id uuid,
  before_data jsonb,
  after_data jsonb,
  created_at timestamptz not null default now()
);
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete restrict,
  user_id uuid references auth.users(id) on delete cascade,
  type text not null,
  title text not null,
  body text not null,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create or replace function public.current_user_has_gym_access(target_gym uuid)
returns boolean language sql stable security definer set search_path='' set row_security=off as $$
  select exists(select 1 from public.gym_users gu where gu.gym_id=target_gym and gu.user_id=(select auth.uid()));
$$;
create or replace function public.current_user_has_gym_role(target_gym uuid, allowed_roles text[])
returns boolean language sql stable security definer set search_path='' set row_security=off as $$
  select exists(select 1 from public.gym_users gu where gu.gym_id=target_gym and gu.user_id=(select auth.uid()) and gu.role=any(allowed_roles));
$$;
revoke all on function public.current_user_has_gym_access(uuid) from public,anon;
revoke all on function public.current_user_has_gym_role(uuid,text[]) from public,anon;
grant execute on function public.current_user_has_gym_access(uuid) to authenticated,service_role;
grant execute on function public.current_user_has_gym_role(uuid,text[]) to authenticated,service_role;

-- RLS on every tenant table. No browser write grants for money, refunds, audit, counters or notifications.
do $$ declare t text; begin
  foreach t in array array['gyms','gym_users','gym_member_counters','gym_invoice_counters','members','membership_plans','memberships','invoices','invoice_items','payments','payment_allocations','refunds','audit_logs','notifications'] loop
    execute format('alter table public.%I enable row level security',t);
  end loop;
end $$;
create policy gyms_select_member on public.gyms for select to authenticated using(public.current_user_has_gym_access(id));
create policy gym_users_select_self on public.gym_users for select to authenticated using(user_id=(select auth.uid()));
create policy members_select_gym on public.members for select to authenticated using(public.current_user_has_gym_access(gym_id));
create policy plans_select_gym on public.membership_plans for select to authenticated using(public.current_user_has_gym_access(gym_id));
create policy memberships_select_gym on public.memberships for select to authenticated using(public.current_user_has_gym_access(gym_id));
create policy invoices_select_gym on public.invoices for select to authenticated using(public.current_user_has_gym_access(gym_id));
create policy invoice_items_select_gym on public.invoice_items for select to authenticated using(public.current_user_has_gym_access(gym_id));
create policy payments_select_gym on public.payments for select to authenticated using(public.current_user_has_gym_access(gym_id));
create policy allocations_select_gym on public.payment_allocations for select to authenticated using(public.current_user_has_gym_access(gym_id));
create policy refunds_select_gym on public.refunds for select to authenticated using(public.current_user_has_gym_access(gym_id));
create policy audit_logs_select_manager on public.audit_logs for select to authenticated using(public.current_user_has_gym_role(gym_id,array['owner','manager']));
create policy notifications_select_own on public.notifications for select to authenticated using(user_id=(select auth.uid()) and public.current_user_has_gym_access(gym_id));
revoke all on public.gym_member_counters,public.gym_invoice_counters from anon,authenticated;
revoke insert,update,delete on public.invoices,public.invoice_items,public.payments,public.payment_allocations,public.refunds,public.audit_logs from anon,authenticated;

create or replace function public.create_gym_for_current_user(gym_name text, gym_timezone text default 'Asia/Kolkata')
returns uuid language plpgsql security definer set search_path='' set row_security=off as $$
declare new_id uuid;
begin
  if (select auth.uid()) is null then raise exception 'authentication_required'; end if;
  if length(trim(coalesce(gym_name,'')))<2 or length(trim(gym_name))>120 then raise exception 'invalid_gym_name'; end if;
  if not exists(select 1 from pg_timezone_names where name=gym_timezone) then raise exception 'invalid_timezone'; end if;
  insert into public.gyms(name,timezone) values(trim(gym_name),gym_timezone) returning id into new_id;
  insert into public.gym_users(gym_id,user_id,role) values(new_id,(select auth.uid()),'owner');
  insert into public.gym_member_counters(gym_id) values(new_id);
  insert into public.gym_invoice_counters(gym_id) values(new_id);
  insert into public.audit_logs(gym_id,actor_user_id,action,entity_type,entity_id,after_data)
    values(new_id,(select auth.uid()),'gym.created','gym',new_id,jsonb_build_object('name',trim(gym_name),'timezone',gym_timezone));
  return new_id;
end $$;
revoke all on function public.create_gym_for_current_user(text,text) from public,anon;
grant execute on function public.create_gym_for_current_user(text,text) to authenticated;

commit;
