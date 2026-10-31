begin;

create table public.platform_admins (
  user_id uuid primary key references auth.users(id) on delete restrict,
  created_at timestamptz not null default now()
);
alter table public.platform_admins enable row level security;
revoke all on public.platform_admins from anon,authenticated;

create or replace function public.is_platform_admin()
returns boolean language sql stable security definer set search_path='' set row_security=off as $$
  select exists(select 1 from public.platform_admins a where a.user_id=(select auth.uid()));
$$;
revoke all on function public.is_platform_admin() from public,anon;
grant execute on function public.is_platform_admin() to authenticated,service_role;

create table public.platform_products (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check(code ~ '^[a-z0-9][a-z0-9_-]{1,60}$'),
  name text not null,
  description text,
  billing_type text not null check(billing_type in('subscription','one_time_licence')),
  price_paise bigint not null check(price_paise>=0),
  currency char(3) not null default 'INR' check(currency='INR'),
  interval_months integer check(interval_months between 1 and 36),
  entitlements jsonb not null default '{}'::jsonb check(jsonb_typeof(entitlements)='object'),
  active boolean not null default true,
  display_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check((billing_type='subscription' and interval_months is not null) or (billing_type='one_time_licence' and interval_months is null))
);
alter table public.platform_products enable row level security;
grant select on public.platform_products to authenticated;
create policy platform_products_public_active on public.platform_products for select to authenticated using(active);

create table public.platform_subscriptions (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete restrict,
  product_id uuid not null references public.platform_products(id) on delete restrict,
  status text not null check(status in('trialing','active','past_due','grace_period','cancel_at_period_end','cancelled','suspended','expired')),
  current_period_start timestamptz,
  current_period_end timestamptz,
  grace_until timestamptz,
  cancel_at_period_end boolean not null default false,
  external_customer_id text,
  external_subscription_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key(product_id) references public.platform_products(id) on delete restrict
);
create index platform_subscriptions_gym_status_idx on public.platform_subscriptions(gym_id,status,current_period_end desc);
alter table public.platform_subscriptions enable row level security;
grant select on public.platform_subscriptions to authenticated;
create policy platform_subscriptions_select_gym on public.platform_subscriptions for select to authenticated using(public.current_user_has_gym_access(gym_id));

create table public.platform_licences (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete restrict,
  product_id uuid not null references public.platform_products(id) on delete restrict,
  licence_code text not null unique,
  status text not null check(status in('active','revoked','expired')),
  granted_at timestamptz not null default now(),
  revoked_at timestamptz,
  scope_snapshot jsonb not null default '{}'::jsonb check(jsonb_typeof(scope_snapshot)='object'),
  terms_version text not null default 'v1',
  created_at timestamptz not null default now(),
  unique(gym_id,id)
);
alter table public.platform_licences enable row level security;
grant select on public.platform_licences to authenticated;
create policy platform_licences_select_gym on public.platform_licences for select to authenticated using(public.current_user_has_gym_access(gym_id));

create table public.platform_payments (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete restrict,
  product_id uuid not null references public.platform_products(id) on delete restrict,
  item_type text not null check(item_type in('subscription','one_time_licence')),
  period_months integer,
  amount_paise bigint not null check(amount_paise>0),
  currency char(3) not null default 'INR' check(currency='INR'),
  status text not null default 'created' check(status in('created','pending','succeeded','failed','refunded','needs_review')),
  provider text not null default 'platform_razorpay' check(provider='platform_razorpay'),
  provider_order_id text,
  provider_payment_id text,
  request_key uuid not null,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  paid_at timestamptz,
  last_error text,
  unique(gym_id,request_key), unique(provider_payment_id), unique(gym_id,id)
);
alter table public.platform_payments enable row level security;
grant select on public.platform_payments to authenticated;
create policy platform_payments_select_manager on public.platform_payments for select to authenticated using(public.current_user_has_gym_role(gym_id,array['owner','manager']));
revoke insert,update,delete on public.platform_payments from anon,authenticated;

create table public.platform_payment_links (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete restrict,
  platform_payment_id uuid not null references public.platform_payments(id) on delete restrict,
  provider_link_id text unique,
  short_url text,
  reference_id text not null unique,
  status text not null default 'creating' check(status in('creating','created','paid','failed','unknown','needs_review')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key(gym_id,platform_payment_id) references public.platform_payments(gym_id,id) on delete restrict,
  unique(gym_id,id)
);
alter table public.platform_payment_links enable row level security;
revoke all on public.platform_payment_links from anon,authenticated;

create table public.platform_webhook_events (
  id uuid primary key default gen_random_uuid(),
  event_id text not null unique,
  payload jsonb not null,
  status text not null default 'queued' check(status in('queued','processing','processed','failed','needs_review')),
  attempts integer not null default 0,
  last_error text,
  received_at timestamptz not null default now(),
  processed_at timestamptz
);
alter table public.platform_webhook_events enable row level security;
revoke all on public.platform_webhook_events from anon,authenticated;

-- Resolve the current plan for application gating. An active perpetual licence takes
-- precedence over a recurring subscription. This rule is deterministic and documented.
create or replace function public.gymflow_entitlements(target_gym uuid)
returns jsonb language plpgsql stable security definer set search_path='' set row_security=off as $$
declare licence_ent jsonb; subscription_ent jsonb; result jsonb; subscription_status text; sub_end timestamptz; grace_end timestamptz;
begin
  if not public.current_user_has_gym_access(target_gym) and not public.is_platform_admin() then raise exception 'permission_denied'; end if;
  select l.scope_snapshot into licence_ent from public.platform_licences l
    where l.gym_id=target_gym and l.status='active' and l.revoked_at is null order by l.granted_at desc limit 1;
  if licence_ent is not null then return licence_ent || jsonb_build_object('billingSource','perpetual_licence','access','full'); end if;
  select p.entitlements,s.status,s.current_period_end,s.grace_until into subscription_ent,subscription_status,sub_end,grace_end
    from public.platform_subscriptions s join public.platform_products p on p.id=s.product_id
    where s.gym_id=target_gym order by s.created_at desc limit 1;
  if subscription_ent is null then return jsonb_build_object('billingSource','none','access','read_only'); end if;
  if subscription_status in('active','trialing','cancel_at_period_end') and (sub_end is null or sub_end>now()) then
    return subscription_ent || jsonb_build_object('billingSource','subscription','access','full');
  end if;
  if subscription_status in('past_due','grace_period') and grace_end is not null and grace_end>now() then
    return subscription_ent || jsonb_build_object('billingSource','subscription_grace','access','grace');
  end if;
  return jsonb_build_object('billingSource','expired','access','read_only');
end $$;
revoke all on function public.gymflow_entitlements(uuid) from public,anon;
grant execute on function public.gymflow_entitlements(uuid) to authenticated,service_role;

create or replace function public.create_platform_payment_request(target_gym uuid,target_product uuid,item_type text,request_key uuid)
returns table(platform_payment_id uuid,amount_paise bigint,reference_id text,is_new boolean)
language plpgsql security definer set search_path='' set row_security=off as $$
declare prod record; existing record; new_payment uuid; ref text; item_months integer;
begin
  if (select auth.uid()) is null then raise exception 'authentication_required'; end if;
  if not public.current_user_has_gym_role(target_gym,array['owner','manager']) then raise exception 'permission_denied'; end if;
  if request_key is null then raise exception 'idempotency_key_required'; end if;
  select pp.* into prod from public.platform_products pp where pp.id=target_product and pp.active=true and pp.billing_type=item_type;
  if not found then raise exception 'product_not_available'; end if;
  select p.id,p.amount_paise,pl.reference_id into existing from public.platform_payments p
    left join public.platform_payment_links pl on pl.platform_payment_id=p.id where p.gym_id=target_gym and p.request_key=create_platform_payment_request.request_key;
  if found then return query select existing.id,existing.amount_paise,existing.reference_id,false; return; end if;
  item_months:=prod.interval_months;
  new_payment:=gen_random_uuid(); ref:='GFS'||upper(substr(replace(new_payment::text,'-',''),1,28));
  insert into public.platform_payments(id,gym_id,product_id,item_type,period_months,amount_paise,request_key,created_by,status)
    values(new_payment,target_gym,target_product,item_type,item_months,prod.price_paise,request_key,(select auth.uid()),'created');
  insert into public.platform_payment_links(gym_id,platform_payment_id,reference_id) values(target_gym,new_payment,ref);
  return query select new_payment,prod.price_paise,ref,true;
end $$;

-- This RPC is service-role only and is called after provider-side capture verification.
-- It atomically posts platform payment + recurring subscription term or perpetual licence.
create or replace function public.apply_verified_platform_payment(
  target_payment uuid,provider_payment_reference text,received_amount_paise bigint,paid_time timestamptz
)
returns void language plpgsql security definer set search_path='' set row_security=off as $$
declare pay record; prod record; existing_status text; start_at timestamptz; end_at timestamptz; licence_key text;
begin
  select * into pay from public.platform_payments where id=target_payment for update;
  if not found then raise exception 'platform_payment_not_found'; end if;
  if pay.amount_paise<>received_amount_paise then raise exception 'platform_amount_mismatch'; end if;
  if pay.status='succeeded' then
    if pay.provider_payment_id=provider_payment_reference then return; else raise exception 'platform_payment_replay_conflict'; end if;
  end if;
  if pay.status not in('created','pending','needs_review') then raise exception 'platform_payment_not_payable'; end if;
  select * into prod from public.platform_products where id=pay.product_id;
  if not found or prod.active is false then raise exception 'platform_product_unavailable'; end if;
  update public.platform_payments set status='succeeded',provider_payment_id=provider_payment_reference,paid_at=coalesce(paid_time,now()),last_error=null where id=target_payment;
  update public.platform_payment_links set status='paid',updated_at=now() where platform_payment_id=target_payment;
  if pay.item_type='subscription' then
    select greatest(coalesce(max(s.current_period_end),now()),now()) into start_at from public.platform_subscriptions s
      where s.gym_id=pay.gym_id and s.status in('active','past_due','grace_period','cancel_at_period_end');
    end_at:=start_at+make_interval(months=>coalesce(pay.period_months,prod.interval_months));
    update public.platform_subscriptions set status='expired',updated_at=now()
      where gym_id=pay.gym_id and status in('active','past_due','grace_period','cancel_at_period_end');
    insert into public.platform_subscriptions(gym_id,product_id,status,current_period_start,current_period_end)
      values(pay.gym_id,pay.product_id,'active',start_at,end_at);
  else
    licence_key:='GYM-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,16));
    insert into public.platform_licences(gym_id,product_id,licence_code,status,scope_snapshot,terms_version)
      values(pay.gym_id,pay.product_id,licence_key,'active',prod.entitlements,'v1');
  end if;
end $$;

create or replace function public.platform_admin_metrics()
returns jsonb language plpgsql stable security definer set search_path='' set row_security=off as $$
declare result jsonb;
begin
  if not public.is_platform_admin() then raise exception 'permission_denied'; end if;
  select jsonb_build_object(
    'registeredGyms',(select count(*) from public.gyms),
    'activeSubscriptions',(select count(*) from public.platform_subscriptions where status in('active','trialing','grace_period','cancel_at_period_end')),
    'activeLicences',(select count(*) from public.platform_licences where status='active' and revoked_at is null),
    'mrrPaise',(select coalesce(sum(round(p.price_paise::numeric/nullif(p.interval_months,0))),0)::bigint from public.platform_subscriptions s join public.platform_products p on p.id=s.product_id where s.status in('active','trialing','grace_period')),
    'platformPaymentsPaise',(select coalesce(sum(amount_paise),0)::bigint from public.platform_payments where status='succeeded'),
    'failedPlatformPayments',(select count(*) from public.platform_payments where status in('failed','needs_review'))
  ) into result;
  return result;
end $$;
revoke all on function public.create_platform_payment_request(uuid,uuid,text,uuid) from public,anon;
revoke all on function public.apply_verified_platform_payment(uuid,text,bigint,timestamptz) from public,anon,authenticated;
revoke all on function public.platform_admin_metrics() from public,anon;
grant execute on function public.create_platform_payment_request(uuid,uuid,text,uuid) to authenticated;
grant execute on function public.apply_verified_platform_payment(uuid,text,bigint,timestamptz) to service_role;
grant execute on function public.platform_admin_metrics() to authenticated;

-- Seed starter products; prices are commercial hypotheses and can be edited before launch.
insert into public.platform_products(code,name,description,billing_type,price_paise,interval_months,entitlements,display_order)
values
 ('starter-monthly','Starter','Core member and collection management','subscription',69900,1,
  '{"maxMembers":100,"maxStaff":2,"whatsappAutomation":false,"onlinePayments":true,"advancedReports":false,"branches":1,"dataExport":true}'::jsonb,1),
 ('growth-monthly','Growth','Automation and advanced reporting','subscription',129900,1,
  '{"maxMembers":500,"maxStaff":8,"whatsappAutomation":true,"onlinePayments":true,"advancedReports":true,"branches":1,"dataExport":true}'::jsonb,2),
 ('perpetual-core','Perpetual Core Licence','Perpetual right to use the defined core version; infrastructure/support charged separately','one_time_licence',1499900,null,
  '{"maxMembers":200,"maxStaff":3,"whatsappAutomation":false,"onlinePayments":true,"advancedReports":false,"branches":1,"dataExport":true,"updates":"defined-version-only"}'::jsonb,3)
on conflict(code) do nothing;

-- Start every new gym with a 14-day trial of Starter. Existing gyms at migration time
-- also receive a trial if they have no subscription or active perpetual licence.
insert into public.platform_subscriptions(gym_id,product_id,status,current_period_start,current_period_end)
select g.id,p.id,'trialing',now(),now()+interval '14 days'
from public.gyms g cross join public.platform_products p
where p.code='starter-monthly'
  and not exists(select 1 from public.platform_subscriptions s where s.gym_id=g.id)
  and not exists(select 1 from public.platform_licences l where l.gym_id=g.id and l.status='active' and l.revoked_at is null);

create or replace function public.create_gym_for_current_user(gym_name text,gym_timezone text default 'Asia/Kolkata')
returns uuid language plpgsql security definer set search_path='' set row_security=off as $$
declare new_id uuid; starter_id uuid;
begin
  if (select auth.uid()) is null then raise exception 'authentication_required'; end if;
  if length(trim(coalesce(gym_name,'')))<2 or length(trim(gym_name))>120 then raise exception 'invalid_gym_name'; end if;
  if not exists(select 1 from pg_timezone_names where name=gym_timezone) then raise exception 'invalid_timezone'; end if;
  select id into starter_id from public.platform_products where code='starter-monthly' and active=true;
  if starter_id is null then raise exception 'starter_product_missing'; end if;
  insert into public.gyms(name,timezone) values(trim(gym_name),gym_timezone) returning id into new_id;
  insert into public.gym_users(gym_id,user_id,role) values(new_id,(select auth.uid()),'owner');
  insert into public.gym_member_counters(gym_id) values(new_id);
  insert into public.gym_invoice_counters(gym_id) values(new_id);
  insert into public.platform_subscriptions(gym_id,product_id,status,current_period_start,current_period_end)
    values(new_id,starter_id,'trialing',now(),now()+interval '14 days');
  insert into public.audit_logs(gym_id,actor_user_id,action,entity_type,entity_id,after_data)
    values(new_id,(select auth.uid()),'gym.created','gym',new_id,jsonb_build_object('name',trim(gym_name),'timezone',gym_timezone,'trial_days',14));
  return new_id;
end $$;
revoke all on function public.create_gym_for_current_user(text,text) from public,anon;
grant execute on function public.create_gym_for_current_user(text,text) to authenticated;

create or replace function public.enforce_member_entitlement()
returns trigger language plpgsql security definer set search_path='' set row_security=off as $$
declare ent jsonb; max_members integer; access_level text; current_count bigint;
begin
  ent:=public.gymflow_entitlements(new.gym_id);access_level:=coalesce(ent->>'access','read_only');
  if access_level not in('full','grace') then raise exception 'subscription_required'; end if;
  max_members:=nullif(ent->>'maxMembers','')::integer;
  if max_members is not null then
    select count(*) into current_count from public.members m where m.gym_id=new.gym_id and m.archived_at is null;
    if current_count>=max_members then raise exception 'member_limit_reached'; end if;
  end if;
  return new;
end $$;
create trigger members_entitlement_guard before insert on public.members for each row execute function public.enforce_member_entitlement();

create or replace function public.enforce_staff_entitlement()
returns trigger language plpgsql security definer set search_path='' set row_security=off as $$
declare ent jsonb; max_staff integer; current_count bigint;
begin
  if new.role not in('manager','staff','viewer') then return new; end if;
  ent:=public.gymflow_entitlements(new.gym_id);
  if coalesce(ent->>'access','read_only') not in('full','grace') then raise exception 'subscription_required'; end if;
  max_staff:=nullif(ent->>'maxStaff','')::integer;
  if max_staff is not null then
    select count(*) into current_count from public.gym_users gu where gu.gym_id=new.gym_id and gu.role in('manager','staff','viewer') and gu.user_id<>new.user_id;
    if current_count>=max_staff then raise exception 'staff_limit_reached'; end if;
  end if;
  return new;
end $$;
create trigger gym_users_entitlement_guard before insert or update of role on public.gym_users for each row execute function public.enforce_staff_entitlement();

create or replace function public.enforce_paid_feature_entitlement()
returns trigger language plpgsql security definer set search_path='' set row_security=off as $$
declare ent jsonb; feature_enabled boolean;
begin
  -- Disabling an integration must remain possible even after a plan expires.
  if tg_table_name='whatsapp_connections' and new.status <> 'active' then return new; end if;
  ent:=public.gymflow_entitlements(new.gym_id);
  if coalesce(ent->>'access','read_only') not in('full','grace') then raise exception 'subscription_required'; end if;
  if tg_table_name='whatsapp_connections' then
    feature_enabled:=coalesce((ent->>'whatsappAutomation')::boolean,false);
    if not feature_enabled then raise exception 'feature_not_in_plan:whatsappAutomation'; end if;
  elsif tg_table_name='payment_links' then
    feature_enabled:=coalesce((ent->>'onlinePayments')::boolean,false);
    if not feature_enabled then raise exception 'feature_not_in_plan:onlinePayments'; end if;
  end if;
  return new;
end $$;
create trigger whatsapp_entitlement_guard before insert or update on public.whatsapp_connections for each row execute function public.enforce_paid_feature_entitlement();
create trigger online_payment_entitlement_guard before insert on public.payment_links for each row execute function public.enforce_paid_feature_entitlement();

commit;
