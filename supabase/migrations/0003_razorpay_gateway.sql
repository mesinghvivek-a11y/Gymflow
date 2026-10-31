begin;
create table public.webhook_events (
  id uuid primary key default gen_random_uuid(),
  provider text not null,
  provider_account_id text not null,
  event_id text not null,
  payload jsonb not null,
  status text not null default 'queued' check(status in('queued','processing','processed','failed','needs_review')),
  attempts integer not null default 0 check(attempts>=0),
  last_error text,
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  unique(provider,provider_account_id,event_id)
);
alter table public.webhook_events enable row level security;
revoke all on public.webhook_events from anon,authenticated;
create table public.gateway_connections (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete restrict,
  provider text not null default 'razorpay' check(provider='razorpay'),
  key_id text not null,
  encrypted_key_secret text not null,
  encrypted_webhook_secret text not null,
  mode text not null check(mode in('test','live')),
  status text not null default 'active' check(status in('active','disabled','needs_attention')),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(gym_id,provider), unique(gym_id,id)
);
alter table public.gateway_connections enable row level security;
revoke all on public.gateway_connections from anon,authenticated;

alter table public.payments add column if not exists provider_account_id uuid;
alter table public.payments add constraint payments_gym_gateway_fk
  foreign key(gym_id,provider_account_id) references public.gateway_connections(gym_id,id) on delete restrict;
create unique index if not exists payments_gateway_ref_unique on public.payments(provider_account_id,provider_payment_id)
  where provider='razorpay' and provider_account_id is not null and provider_payment_id is not null;

create table public.payment_links (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null,
  invoice_id uuid not null,
  member_id uuid not null,
  gateway_connection_id uuid not null,
  request_key uuid not null,
  reference_id text not null,
  provider_link_id text,
  short_url text,
  amount_paise bigint not null check(amount_paise>0),
  currency char(3) not null default 'INR' check(currency='INR'),
  status text not null default 'creating' check(status in('creating','created','paid','cancelled','expired','failed','unknown','needs_review')),
  payment_id uuid,
  expire_by timestamptz,
  last_error text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key(gym_id,invoice_id) references public.invoices(gym_id,id) on delete restrict,
  foreign key(gym_id,member_id) references public.members(gym_id,id) on delete restrict,
  foreign key(gym_id,gateway_connection_id) references public.gateway_connections(gym_id,id) on delete restrict,
  foreign key(gym_id,payment_id) references public.payments(gym_id,id) on delete restrict,
  unique(gym_id,id), unique(gym_id,request_key), unique(gateway_connection_id,reference_id),
  unique(gateway_connection_id,provider_link_id)
);
create unique index payment_links_one_unresolved_invoice on public.payment_links(gym_id,invoice_id)
  where status in('creating','created','unknown','needs_review');
create index payment_links_invoice_idx on public.payment_links(gym_id,invoice_id,created_at desc);
alter table public.payment_links enable row level security;
grant select on public.payment_links to authenticated;
create policy payment_links_select_gym on public.payment_links for select to authenticated using(public.current_user_has_gym_access(gym_id));
revoke insert,update,delete on public.payment_links from anon,authenticated;

create or replace function public.reserve_razorpay_payment_link(target_gym uuid,target_invoice uuid,request_key uuid)
returns table(payment_link_id uuid,invoice_id uuid,amount_paise bigint,reference_id text,invoice_number text,member_name text,member_phone text,link_status text,short_url text,is_new boolean)
language plpgsql security definer set search_path='' set row_security=off as $$
declare existing record; inv record; connection_key uuid; paid bigint; balance bigint; new_id uuid; ref text;
begin
  if (select auth.uid()) is null then raise exception 'authentication_required'; end if;
  if not public.current_user_has_gym_role(target_gym,array['owner','manager','staff']) then raise exception 'permission_denied'; end if;
  if request_key is null then raise exception 'idempotency_key_required'; end if;
  perform pg_advisory_xact_lock(hashtextextended(target_gym::text||':link:'||request_key::text,41));
  select pl.id,pl.invoice_id,pl.amount_paise,pl.reference_id,pl.status,pl.short_url into existing
    from public.payment_links pl where pl.gym_id=target_gym and pl.request_key=reserve_razorpay_payment_link.request_key;
  if found then
    if existing.invoice_id<>target_invoice then raise exception 'idempotency_conflict'; end if;
    select i.invoice_number,m.full_name,m.phone_e164 into inv from public.invoices i join public.members m on m.gym_id=i.gym_id and m.id=i.member_id where i.gym_id=target_gym and i.id=target_invoice;
    return query select existing.id,existing.invoice_id,existing.amount_paise,existing.reference_id,inv.invoice_number,inv.full_name,inv.phone_e164,existing.status,existing.short_url,false; return;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(target_gym::text||':invoice:'||target_invoice::text,42));
  select i.id,i.member_id,i.invoice_number,i.total_paise,i.status,m.full_name,m.phone_e164 into inv
    from public.invoices i join public.members m on m.gym_id=i.gym_id and m.id=i.member_id
    where i.gym_id=target_gym and i.id=target_invoice for update of i;
  if not found then raise exception 'invoice_not_found'; end if;
  if inv.status not in('open','partially_paid') then raise exception 'invoice_not_payable'; end if;
  select gc.id into connection_key from public.gateway_connections gc where gc.gym_id=target_gym and gc.status='active';
  if connection_key is null then raise exception 'razorpay_not_connected'; end if;
  select coalesce(sum(pa.amount_paise),0)::bigint into paid from public.payment_allocations pa join public.payments p on p.gym_id=pa.gym_id and p.id=pa.payment_id
    where pa.gym_id=target_gym and pa.invoice_id=target_invoice and p.status='succeeded';
  balance:=inv.total_paise-paid;
  if balance<=0 then raise exception 'invoice_not_payable'; end if;
  update public.payment_links pl set status='expired',updated_at=now() where pl.gym_id=target_gym and pl.invoice_id=target_invoice and pl.status='created' and pl.expire_by<=now();
  if exists(select 1 from public.payment_links pl where pl.gym_id=target_gym and pl.invoice_id=target_invoice and pl.status in('creating','created','unknown','needs_review')) then raise exception 'active_payment_link_exists'; end if;
  new_id:=gen_random_uuid(); ref:='GF'||upper(substr(replace(new_id::text,'-',''),1,30));
  insert into public.payment_links(id,gym_id,invoice_id,member_id,gateway_connection_id,request_key,reference_id,amount_paise,status,created_by)
    values(new_id,target_gym,target_invoice,inv.member_id,connection_key,request_key,ref,balance,'creating',(select auth.uid()));
  return query select new_id,target_invoice,balance,ref,inv.invoice_number,inv.full_name,inv.phone_e164,'creating'::text,null::text,true;
end $$;

create or replace function public.enqueue_razorpay_webhook_event(target_connection uuid,target_event_id text,event_payload jsonb)
returns table(event_row_id uuid,was_inserted boolean)
language plpgsql security definer set search_path='' set row_security=off as $$
declare new_event uuid; old_status text;
begin
  if not exists(select 1 from public.gateway_connections gc where gc.id=target_connection) then raise exception 'gateway_connection_not_found'; end if;
  if target_event_id is null or length(target_event_id) not between 1 and 128 or jsonb_typeof(event_payload)<>'object' then raise exception 'invalid_event'; end if;
  insert into public.webhook_events(provider,provider_account_id,event_id,payload,status)
    values('razorpay',target_connection::text,target_event_id,event_payload,'queued')
    on conflict(provider,provider_account_id,event_id) do nothing returning id into new_event;
  if new_event is not null then return query select new_event,true; return; end if;
  select we.id,we.status into new_event,old_status from public.webhook_events we
    where we.provider='razorpay' and we.provider_account_id=target_connection::text and we.event_id=target_event_id;
  return query select new_event,false;
end $$;

create or replace function public.claim_razorpay_webhook_events(batch_size integer default 5)
returns table(id uuid,provider_account_id text,payload jsonb,attempts integer)
language plpgsql security definer set search_path='' set row_security=off as $$
begin
  update public.webhook_events set status='queued' where provider='razorpay' and status='processing' and received_at<now()-interval '10 minutes';
  return query with due as (
    select we.id from public.webhook_events we where we.provider='razorpay' and we.status='queued'
    order by we.received_at for update skip locked limit greatest(least(coalesce(batch_size,5),20),1)
  ), claimed as (
    update public.webhook_events we set status='processing',attempts=we.attempts+1 from due where we.id=due.id returning we.*
  ) select c.id,c.provider_account_id,c.payload,c.attempts from claimed c;
end $$;

create or replace function public.record_verified_razorpay_payment(target_payment_link uuid,target_gateway_connection uuid,provider_payment_reference text,received_amount_paise bigint,captured_at timestamptz)
returns table(payment_id uuid,invoice_id uuid,remaining_paise bigint)
language plpgsql security definer set search_path='' set row_security=off as $$
declare linkrow record; inv record; paid bigint; balance bigint; new_payment uuid; existing record;
begin
  select pl.* into linkrow from public.payment_links pl where pl.id=target_payment_link for update;
  if not found then raise exception 'payment_link_not_found'; end if;
  if linkrow.gateway_connection_id<>target_gateway_connection then raise exception 'gateway_account_mismatch'; end if;
  if linkrow.currency<>'INR' or linkrow.amount_paise<>received_amount_paise then raise exception 'payment_amount_mismatch'; end if;
  select p.id,p.amount_paise,p.provider_account_id,pa.invoice_id into existing from public.payments p left join public.payment_allocations pa on pa.gym_id=p.gym_id and pa.payment_id=p.id
    where p.provider='razorpay' and p.provider_payment_id=provider_payment_reference;
  if found then
    if existing.amount_paise<>received_amount_paise or existing.provider_account_id is distinct from target_gateway_connection or existing.invoice_id is distinct from linkrow.invoice_id then raise exception 'provider_payment_already_applied'; end if;
    update public.payment_links set status='paid',payment_id=existing.id,updated_at=now() where id=target_payment_link;
    return query select existing.id,linkrow.invoice_id,0::bigint; return;
  end if;
  select i.* into inv from public.invoices i where i.gym_id=linkrow.gym_id and i.id=linkrow.invoice_id for update;
  if not found or inv.status not in('open','partially_paid') then raise exception 'invoice_not_payable'; end if;
  select coalesce(sum(pa.amount_paise),0)::bigint into paid from public.payment_allocations pa join public.payments p on p.gym_id=pa.gym_id and p.id=pa.payment_id where pa.gym_id=linkrow.gym_id and pa.invoice_id=linkrow.invoice_id and p.status='succeeded';
  balance:=inv.total_paise-paid;
  if balance<>received_amount_paise or linkrow.status not in('created','paid') then raise exception 'payment_link_invoice_balance_changed'; end if;
  insert into public.payments(gym_id,member_id,provider,provider_account_id,provider_payment_id,amount_paise,status,received_at,notes)
    values(linkrow.gym_id,linkrow.member_id,'razorpay',target_gateway_connection,provider_payment_reference,received_amount_paise,'succeeded',coalesce(captured_at,now()),'Provider capture verified by webhook worker') returning id into new_payment;
  insert into public.payment_allocations(gym_id,payment_id,invoice_id,amount_paise) values(linkrow.gym_id,new_payment,linkrow.invoice_id,received_amount_paise);
  update public.invoices set status='paid',updated_at=now() where gym_id=linkrow.gym_id and id=linkrow.invoice_id;
  if inv.membership_id is not null then update public.memberships set payment_status='paid',updated_at=now() where gym_id=linkrow.gym_id and id=inv.membership_id; end if;
  update public.payment_links set status='paid',payment_id=new_payment,updated_at=now() where id=target_payment_link;
  insert into public.audit_logs(gym_id,actor_user_id,action,entity_type,entity_id,after_data)
    values(linkrow.gym_id,null,'payment.razorpay_verified','payment',new_payment,jsonb_build_object('invoice_id',linkrow.invoice_id,'amount_paise',received_amount_paise));
  return query select new_payment,linkrow.invoice_id,0::bigint;
end $$;

revoke all on function public.enqueue_razorpay_webhook_event(uuid,text,jsonb) from public,anon,authenticated;
revoke all on function public.claim_razorpay_webhook_events(integer) from public,anon,authenticated;
revoke all on function public.record_verified_razorpay_payment(uuid,uuid,text,bigint,timestamptz) from public,anon,authenticated;
revoke all on function public.reserve_razorpay_payment_link(uuid,uuid,uuid) from public,anon;
grant execute on function public.enqueue_razorpay_webhook_event(uuid,text,jsonb) to service_role;
grant execute on function public.claim_razorpay_webhook_events(integer) to service_role;
grant execute on function public.record_verified_razorpay_payment(uuid,uuid,text,bigint,timestamptz) to service_role;
grant execute on function public.reserve_razorpay_payment_link(uuid,uuid,uuid) to authenticated;
commit;
