begin;
alter table public.gyms add column if not exists whatsapp_reminder_local_time time not null default time '10:00';
alter table public.members add column if not exists whatsapp_opt_in boolean not null default false,
  add column if not exists whatsapp_opted_in_at timestamptz,
  add column if not exists whatsapp_opted_out_at timestamptz,
  add column if not exists whatsapp_consent_source text;

create table public.whatsapp_connections (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms(id) on delete restrict,
  provider text not null default 'meta_cloud' check(provider='meta_cloud'),
  business_account_id text not null,
  phone_number_id text not null unique,
  display_phone_number text,
  verified_name text,
  encrypted_access_token text not null,
  graph_api_version text not null check(graph_api_version ~ '^v[0-9]{1,3}\.[0-9]{1,2}$'),
  language_code text not null default 'en',
  pre_expiry_template text not null,
  due_today_template text not null,
  status text not null default 'active' check(status in('active','disabled','needs_attention')),
  last_verified_at timestamptz,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(gym_id,provider),unique(gym_id,id)
);
alter table public.whatsapp_connections enable row level security;
revoke all on public.whatsapp_connections from anon,authenticated;

create table public.reminder_jobs (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null,
  membership_id uuid not null,
  member_id uuid not null,
  reminder_type text not null check(reminder_type in('pre_expiry','due_today')),
  expiry_date date not null,
  cycle_version integer not null check(cycle_version>0),
  scheduled_at timestamptz not null,
  status text not null default 'pending' check(status in('pending','sending','sent','failed','unknown','skipped','cancelled')),
  attempts integer not null default 0 check(attempts>=0),
  claimed_at timestamptz,
  processed_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key(gym_id,membership_id) references public.memberships(gym_id,id) on delete restrict,
  foreign key(gym_id,member_id) references public.members(gym_id,id) on delete restrict,
  unique(membership_id,expiry_date,reminder_type,cycle_version),unique(gym_id,id)
);
create index reminder_jobs_due_idx on public.reminder_jobs(scheduled_at) where status='pending';
alter table public.reminder_jobs enable row level security;
grant select on public.reminder_jobs to authenticated;
create policy reminder_jobs_select_gym on public.reminder_jobs for select to authenticated using(public.current_user_has_gym_access(gym_id));

create table public.whatsapp_messages (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null,
  reminder_job_id uuid not null,
  connection_id uuid not null,
  member_id uuid not null,
  provider_message_id text,
  recipient_phone text not null,
  template_name text not null,
  status text not null default 'sending' check(status in('sending','accepted','sent','delivered','read','failed','unknown')),
  accepted_at timestamptz,
  sent_at timestamptz,
  delivered_at timestamptz,
  read_at timestamptz,
  error_code text,
  error_message text,
  provider_timestamp timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key(gym_id,reminder_job_id) references public.reminder_jobs(gym_id,id) on delete restrict,
  foreign key(gym_id,connection_id) references public.whatsapp_connections(gym_id,id) on delete restrict,
  foreign key(gym_id,member_id) references public.members(gym_id,id) on delete restrict,
  unique(reminder_job_id),unique(connection_id,provider_message_id),unique(gym_id,id)
);
alter table public.whatsapp_messages enable row level security;
grant select on public.whatsapp_messages to authenticated;
create policy whatsapp_messages_select_gym on public.whatsapp_messages for select to authenticated using(public.current_user_has_gym_access(gym_id));

create table public.whatsapp_webhook_events (
  id uuid primary key default gen_random_uuid(),
  connection_id uuid not null references public.whatsapp_connections(id) on delete restrict,
  event_key text not null,
  provider_message_id text not null,
  provider_status text not null check(provider_status in('sent','delivered','read','failed')),
  provider_timestamp timestamptz,
  error_code text,
  error_message text,
  payload jsonb not null,
  received_at timestamptz not null default now(),
  applied_at timestamptz,
  unique(connection_id,event_key)
);
alter table public.whatsapp_webhook_events enable row level security;
revoke all on public.whatsapp_webhook_events from anon,authenticated;
create index whatsapp_status_events_pending on public.whatsapp_webhook_events(received_at) where applied_at is null;

create table public.whatsapp_inbound_events (
  id uuid primary key default gen_random_uuid(),
  connection_id uuid not null references public.whatsapp_connections(id) on delete restrict,
  provider_message_id text not null,
  from_phone text not null,
  received_at timestamptz not null default now(),
  unique(connection_id,provider_message_id)
);
alter table public.whatsapp_inbound_events enable row level security;
revoke all on public.whatsapp_inbound_events from anon,authenticated;

create or replace function public.schedule_whatsapp_membership_reminders()
returns trigger language plpgsql security definer set search_path='' set row_security=off as $$
declare tz text; send_time time; exp_date date;
begin
  select g.timezone,g.whatsapp_reminder_local_time into tz,send_time from public.gyms g where g.id=new.gym_id;
  if tz is null then raise exception 'gym_timezone_missing'; end if;
  update public.reminder_jobs r set status='cancelled',last_error='membership_cycle_changed',updated_at=now()
    where r.gym_id=new.gym_id and r.membership_id=new.id and r.status='pending'
      and (new.payment_status not in('paid','waived') or new.paused_at is not null or new.cancelled_at is not null
        or r.cycle_version<>new.cycle_version or r.expiry_date<>(new.ends_at at time zone tz)::date);
  if new.payment_status not in('paid','waived') or new.paused_at is not null or new.cancelled_at is not null then return new; end if;
  -- Suppress pending reminders for the previous term when an advance renewal
  -- has been paid and starts exactly at that previous term's exclusive expiry.
  update public.reminder_jobs r set status='cancelled',last_error='membership_renewed',updated_at=now()
    from public.memberships older
    where r.gym_id=new.gym_id and r.membership_id=older.id and r.member_id=new.member_id
      and older.gym_id=new.gym_id and older.id<>new.id and older.payment_status in('paid','waived')
      and older.ends_at=new.starts_at and r.status='pending';
  exp_date:=(new.ends_at at time zone tz)::date;
  insert into public.reminder_jobs(gym_id,membership_id,member_id,reminder_type,expiry_date,cycle_version,scheduled_at)
  values
    (new.gym_id,new.id,new.member_id,'pre_expiry',exp_date,new.cycle_version,((exp_date-3)+send_time) at time zone tz),
    (new.gym_id,new.id,new.member_id,'due_today',exp_date,new.cycle_version,(exp_date+send_time) at time zone tz)
  on conflict(membership_id,expiry_date,reminder_type,cycle_version) do nothing;
  return new;
end $$;
create trigger membership_schedule_whatsapp after insert or update of payment_status,ends_at,cycle_version,paused_at,cancelled_at
  on public.memberships for each row execute function public.schedule_whatsapp_membership_reminders();

create or replace function public.set_member_whatsapp_consent_for_gym(target_gym uuid,target_member uuid,is_opted_in boolean,consent_source text)
returns void language plpgsql security definer set search_path='' set row_security=off as $$
declare previous_value boolean;
begin
  if (select auth.uid()) is null then raise exception 'authentication_required'; end if;
  if not public.current_user_has_gym_role(target_gym,array['owner','manager','staff']) then raise exception 'permission_denied'; end if;
  if is_opted_in and consent_source not in('signed_form','in_person_verbal','website_form','recorded_message','other') then raise exception 'valid_consent_source_required'; end if;
  select m.whatsapp_opt_in into previous_value from public.members m where m.gym_id=target_gym and m.id=target_member and m.archived_at is null for update;
  if not found then raise exception 'member_not_found'; end if;
  update public.members set whatsapp_opt_in=is_opted_in,whatsapp_opted_in_at=case when is_opted_in then now() else whatsapp_opted_in_at end,
    whatsapp_opted_out_at=case when is_opted_in then null else now() end,whatsapp_consent_source=case when is_opted_in then consent_source else 'opt_out' end,updated_at=now()
    where gym_id=target_gym and id=target_member;
  if not is_opted_in then update public.reminder_jobs set status='cancelled',last_error='member_opted_out',updated_at=now()
    where gym_id=target_gym and member_id=target_member and status='pending'; end if;
  insert into public.audit_logs(gym_id,actor_user_id,action,entity_type,entity_id,before_data,after_data)
    values(target_gym,(select auth.uid()),'member.whatsapp_consent_updated','member',target_member,
      jsonb_build_object('whatsapp_opt_in',previous_value),jsonb_build_object('whatsapp_opt_in',is_opted_in,'source',consent_source));
end $$;

create or replace function public.update_gym_whatsapp_reminder_time(target_gym uuid,local_send_time time)
returns void language plpgsql security definer set search_path='' set row_security=off as $$
declare tz text;
begin
  if (select auth.uid()) is null then raise exception 'authentication_required'; end if;
  if not public.current_user_has_gym_role(target_gym,array['owner','manager']) then raise exception 'permission_denied'; end if;
  update public.gyms set whatsapp_reminder_local_time=local_send_time where id=target_gym returning timezone into tz;
  if tz is null then raise exception 'gym_not_found'; end if;
  update public.reminder_jobs r set scheduled_at=((r.expiry_date-case when r.reminder_type='pre_expiry' then 3 else 0 end)+local_send_time) at time zone tz,updated_at=now()
    where r.gym_id=target_gym and r.status='pending';
  insert into public.audit_logs(gym_id,actor_user_id,action,entity_type,entity_id,after_data)
    values(target_gym,(select auth.uid()),'gym.whatsapp_reminder_time_changed','gym',target_gym,jsonb_build_object('local_time',local_send_time,'timezone',tz));
end $$;

create or replace function public.claim_whatsapp_reminder_jobs(batch_size integer default 10)
returns table(job_id uuid,gym_id uuid,membership_id uuid,member_id uuid,reminder_type text,expiry_date date,cycle_version integer,
  connection_id uuid,phone_number_id text,encrypted_access_token text,graph_api_version text,language_code text,template_name text,
  member_name text,recipient_phone text,gym_name text,gym_timezone text,membership_ends_at timestamptz)
language plpgsql security definer set search_path='' set row_security=off as $$
begin
  update public.reminder_jobs set status='unknown',last_error='worker_interrupted_unknown_delivery',updated_at=now()
    where status='sending' and claimed_at<now()-interval '15 minutes';
  update public.whatsapp_messages wm set status='unknown',error_message='worker_interrupted_unknown_delivery',updated_at=now()
    from public.reminder_jobs r where wm.reminder_job_id=r.id and r.status='unknown' and wm.status='sending';
  return query with due as (
    select r.id from public.reminder_jobs r join public.gyms g on g.id=r.gym_id
      join public.members m on m.gym_id=r.gym_id and m.id=r.member_id
      join public.memberships ms on ms.gym_id=r.gym_id and ms.id=r.membership_id
      join public.whatsapp_connections wc on wc.gym_id=r.gym_id and wc.status='active'
    where r.status='pending' and r.scheduled_at<=now() and m.whatsapp_opt_in and m.whatsapp_opted_out_at is null and m.archived_at is null
      and ms.payment_status in('paid','waived') and ms.paused_at is null and ms.cancelled_at is null and ms.cycle_version=r.cycle_version
      and (ms.ends_at at time zone g.timezone)::date=r.expiry_date
      and not exists(select 1 from public.memberships successor
        where successor.gym_id=ms.gym_id and successor.member_id=ms.member_id and successor.id<>ms.id
          and successor.payment_status in('paid','waived') and successor.cancelled_at is null and successor.starts_at=ms.ends_at)
      and ((now() at time zone g.timezone)::date<=r.expiry_date)
      and (r.reminder_type<>'pre_expiry' or (now() at time zone g.timezone)::date<=r.expiry_date-3)
    order by r.scheduled_at for update of r skip locked limit greatest(least(coalesce(batch_size,10),20),1)
  ), claimed as (
    update public.reminder_jobs r set status='sending',attempts=r.attempts+1,claimed_at=now(),updated_at=now()
      from due where r.id=due.id returning r.*
  )
  select c.id,c.gym_id,c.membership_id,c.member_id,c.reminder_type,c.expiry_date,c.cycle_version,wc.id,wc.phone_number_id,wc.encrypted_access_token,
    wc.graph_api_version,wc.language_code,case when c.reminder_type='pre_expiry' then wc.pre_expiry_template else wc.due_today_template end,
    m.full_name,m.phone_e164,g.name,g.timezone,ms.ends_at
  from claimed c join public.gyms g on g.id=c.gym_id join public.members m on m.gym_id=c.gym_id and m.id=c.member_id
    join public.memberships ms on ms.gym_id=c.gym_id and ms.id=c.membership_id join public.whatsapp_connections wc on wc.gym_id=c.gym_id and wc.status='active';
end $$;

create or replace function public.apply_whatsapp_delivery_update(target_connection uuid,target_message_id text,target_status text,provider_time timestamptz,error_code text,error_message text)
returns void language plpgsql security definer set search_path='' set row_security=off as $$
declare current_row public.whatsapp_messages%rowtype;
begin
  if target_status not in('sent','delivered','read','failed') then raise exception 'invalid_whatsapp_status'; end if;
  select * into current_row from public.whatsapp_messages where connection_id=target_connection and provider_message_id=target_message_id for update;
  if not found then raise exception 'whatsapp_message_not_found'; end if;
  if provider_time is not null and current_row.provider_timestamp is not null and provider_time<current_row.provider_timestamp then return; end if;
  update public.whatsapp_messages set status=case
    when current_row.status='read' then 'read'
    when current_row.status='delivered' and target_status in('sent','failed') then 'delivered'
    else target_status end,
    sent_at=case when target_status='sent' then coalesce(sent_at,provider_time,now()) else sent_at end,
    delivered_at=case when target_status='delivered' then coalesce(delivered_at,provider_time,now()) else delivered_at end,
    read_at=case when target_status='read' then coalesce(read_at,provider_time,now()) else read_at end,
    error_code=case when target_status='failed' then public.apply_whatsapp_delivery_update.error_code else current_row.error_code end,
    error_message=case when target_status='failed' then left(public.apply_whatsapp_delivery_update.error_message,500) else current_row.error_message end,
    provider_timestamp=coalesce(provider_time,current_row.provider_timestamp),updated_at=now()
    where id=current_row.id;
end $$;

create or replace function public.apply_whatsapp_inbound_opt_out(target_connection uuid,target_provider_message_id text,sender_phone text,body_content text,received_time timestamptz)
returns boolean language plpgsql security definer set search_path='' set row_security=off as $$
declare gym_key uuid; inserted uuid; keyword text;
begin
  select gym_id into gym_key from public.whatsapp_connections where id=target_connection and status in('active','needs_attention');
  if gym_key is null then raise exception 'whatsapp_connection_not_found'; end if;
  if sender_phone !~ '^[1-9][0-9]{7,14}$' then raise exception 'invalid_sender_phone'; end if;
  insert into public.whatsapp_inbound_events(connection_id,provider_message_id,from_phone) values(target_connection,target_provider_message_id,'+'||sender_phone)
    on conflict(connection_id,provider_message_id) do nothing returning id into inserted;
  if inserted is null then return false; end if;
  keyword:=upper(trim(coalesce(body_content,'')));
  if keyword not in('STOP','UNSUBSCRIBE','CANCEL','END','QUIT') then return true; end if;
  with changed as (update public.members set whatsapp_opt_in=false,whatsapp_opted_out_at=coalesce(received_time,now()),whatsapp_consent_source='member_keyword',updated_at=now()
      where gym_id=gym_key and phone_e164='+'||sender_phone and whatsapp_opt_in returning id),
    logrow as (insert into public.audit_logs(gym_id,action,entity_type,entity_id,after_data) select gym_key,'member.whatsapp_opted_out','member',id,jsonb_build_object('keyword',keyword) from changed returning entity_id)
  update public.reminder_jobs set status='cancelled',last_error='member_opted_out',updated_at=now() where gym_id=gym_key and member_id in(select entity_id from logrow) and status='pending';
  return true;
end $$;


create or replace function public.skip_ineligible_whatsapp_jobs()
returns integer language plpgsql security definer set search_path='' set row_security=off as $$
declare changed integer;
begin
  update public.reminder_jobs r set status='skipped',processed_at=now(),updated_at=now(),last_error='reminder_no_longer_eligible'
  from public.gyms g,public.members m,public.memberships ms
  where r.status='pending' and r.scheduled_at<=now() and g.id=r.gym_id and m.gym_id=r.gym_id and m.id=r.member_id
    and ms.gym_id=r.gym_id and ms.id=r.membership_id
    and (not m.whatsapp_opt_in or m.whatsapp_opted_out_at is not null or m.archived_at is not null
      or ms.payment_status not in('paid','waived') or ms.paused_at is not null or ms.cancelled_at is not null
      or ms.cycle_version<>r.cycle_version
      or exists(select 1 from public.memberships successor where successor.gym_id=ms.gym_id
        and successor.member_id=ms.member_id and successor.id<>ms.id
        and successor.payment_status in('paid','waived') and successor.cancelled_at is null and successor.starts_at=ms.ends_at)
      or (ms.ends_at at time zone g.timezone)::date<>r.expiry_date
      or (now() at time zone g.timezone)::date>r.expiry_date
      or (r.reminder_type='pre_expiry' and (now() at time zone g.timezone)::date>r.expiry_date-3)
      or not exists(select 1 from public.whatsapp_connections wc where wc.gym_id=r.gym_id and wc.status='active'));
  get diagnostics changed=row_count;return changed;
end $$;

create or replace function public.apply_pending_whatsapp_status_events(batch_size integer default 100)
returns integer language plpgsql security definer set search_path='' set row_security=off as $$
declare e record; applied integer:=0;
begin
  for e in select w.id,w.connection_id,w.provider_message_id,w.provider_status,w.provider_timestamp,w.error_code,w.error_message
    from public.whatsapp_webhook_events w join public.whatsapp_messages m on m.connection_id=w.connection_id and m.provider_message_id=w.provider_message_id
    where w.applied_at is null order by w.received_at for update of w skip locked limit greatest(least(coalesce(batch_size,100),500),1)
  loop
    perform public.apply_whatsapp_delivery_update(e.connection_id,e.provider_message_id,e.provider_status,e.provider_timestamp,e.error_code,e.error_message);
    update public.whatsapp_webhook_events set applied_at=now() where id=e.id;applied:=applied+1;
  end loop;
  return applied;
end $$;

revoke all on function public.set_member_whatsapp_consent_for_gym(uuid,uuid,boolean,text) from public,anon;
revoke all on function public.update_gym_whatsapp_reminder_time(uuid,time) from public,anon;
revoke all on function public.claim_whatsapp_reminder_jobs(integer) from public,anon,authenticated;
revoke all on function public.skip_ineligible_whatsapp_jobs() from public,anon,authenticated;
revoke all on function public.apply_pending_whatsapp_status_events(integer) from public,anon,authenticated;
revoke all on function public.apply_whatsapp_delivery_update(uuid,text,text,timestamptz,text,text) from public,anon,authenticated;
revoke all on function public.apply_whatsapp_inbound_opt_out(uuid,text,text,text,timestamptz) from public,anon,authenticated;
grant execute on function public.set_member_whatsapp_consent_for_gym(uuid,uuid,boolean,text) to authenticated;
grant execute on function public.update_gym_whatsapp_reminder_time(uuid,time) to authenticated;
grant execute on function public.claim_whatsapp_reminder_jobs(integer) to service_role;
grant execute on function public.skip_ineligible_whatsapp_jobs() to service_role;
grant execute on function public.apply_pending_whatsapp_status_events(integer) to service_role;
grant execute on function public.apply_whatsapp_delivery_update(uuid,text,text,timestamptz,text,text) to service_role;
grant execute on function public.apply_whatsapp_inbound_opt_out(uuid,text,text,text,timestamptz) to service_role;
commit;
