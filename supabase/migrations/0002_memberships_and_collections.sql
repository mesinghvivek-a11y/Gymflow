begin;

create or replace function public.create_member_for_gym(
  target_gym uuid, member_name text, member_phone text, member_address text, p_request_key uuid
)
returns table(id uuid, member_number char(5), full_name text, phone_e164 text, created_at timestamptz)
language plpgsql security definer set search_path='' set row_security=off as $$
declare candidate integer; new_member_id uuid; new_number char(5); existing_row record;
begin
  if (select auth.uid()) is null then raise exception 'authentication_required'; end if;
  if not public.current_user_has_gym_role(target_gym,array['owner','manager','staff']) then raise exception 'permission_denied'; end if;
  if length(trim(coalesce(member_name,'')))<1 or length(trim(member_name))>120 then raise exception 'invalid_member_name'; end if;
  if member_phone !~ '^\+[1-9][0-9]{7,14}$' then raise exception 'invalid_phone'; end if;
  if p_request_key is null then raise exception 'idempotency_key_required'; end if;
  perform pg_advisory_xact_lock(hashtextextended(target_gym::text||':member:'||p_request_key::text,11));
  select m.* into existing_row from public.members m where m.gym_id=target_gym and m.request_key=p_request_key;
  if found then
    if existing_row.full_name<>trim(member_name) or existing_row.phone_e164<>member_phone then raise exception 'idempotency_conflict'; end if;
    return query select existing_row.id,existing_row.member_number,existing_row.full_name,existing_row.phone_e164,existing_row.created_at; return;
  end if;
  loop
    update public.gym_member_counters set next_member_number=next_member_number+1,updated_at=now()
      where gym_id=target_gym and next_member_number<=99999
      returning next_member_number-1 into candidate;
    if candidate is null then raise exception 'member_id_space_exhausted'; end if;
    exit when not exists(select 1 from public.members m where m.gym_id=target_gym and m.member_number=lpad(candidate::text,5,'0'));
  end loop;
  insert into public.members(gym_id,member_number,full_name,phone_e164,address,request_key)
    values(target_gym,lpad(candidate::text,5,'0'),trim(member_name),member_phone,nullif(trim(coalesce(member_address,'')),''),p_request_key)
    returning public.members.id,public.members.member_number into new_member_id,new_number;
  insert into public.audit_logs(gym_id,actor_user_id,action,entity_type,entity_id,after_data)
    values(target_gym,(select auth.uid()),'member.created','member',new_member_id,jsonb_build_object('member_number',new_number,'full_name',trim(member_name)));
  return query select m.id,m.member_number,m.full_name,m.phone_e164,m.created_at from public.members m where m.gym_id=target_gym and m.id=new_member_id;
end $$;

create or replace function public.create_membership_plan_for_gym(
  target_gym uuid, plan_name text, duration_months integer, duration_days integer, price_paise bigint
)
returns table(plan_id uuid, plan_label text, plan_duration_months integer, plan_duration_days integer, plan_price_paise bigint, is_active boolean)
language plpgsql security definer set search_path='' set row_security=off as $$
declare new_id uuid;
begin
  if (select auth.uid()) is null then raise exception 'authentication_required'; end if;
  if not public.current_user_has_gym_role(target_gym,array['owner','manager']) then raise exception 'permission_denied'; end if;
  if length(trim(coalesce(plan_name,'')))<2 or length(plan_name)>100 then raise exception 'invalid_plan_name'; end if;
  if price_paise is null or price_paise<0 then raise exception 'invalid_plan_price'; end if;
  if not ((duration_months between 1 and 120 and duration_days is null) or (duration_days between 1 and 3650 and duration_months is null)) then raise exception 'invalid_plan_duration'; end if;
  insert into public.membership_plans(gym_id,name,duration_months,duration_days,price_paise)
    values(target_gym,trim(plan_name),duration_months,duration_days,price_paise) returning id into new_id;
  insert into public.audit_logs(gym_id,actor_user_id,action,entity_type,entity_id,after_data)
    values(target_gym,(select auth.uid()),'membership_plan.created','membership_plan',new_id,
      jsonb_build_object('name',trim(plan_name),'duration_months',duration_months,'duration_days',duration_days,'price_paise',price_paise));
  return query select p.id,p.name,p.duration_months,p.duration_days,p.price_paise,p.active from public.membership_plans p where p.gym_id=target_gym and p.id=new_id;
end $$;

create or replace function public.create_membership_for_gym(
  target_gym uuid, target_member uuid, target_plan uuid, selected_start_date date, request_key uuid
)
returns table(membership_id uuid, invoice_id uuid, invoice_number text, starts_at timestamptz, ends_at timestamptz, total_paise bigint, payment_status text)
language plpgsql security definer set search_path='' set row_security=off as $$
declare gym_tz text; plan_row record; latest_end timestamptz; start_at timestamptz; end_at timestamptz;
  membership_new uuid; invoice_new uuid; invoice_seq bigint; invoice_no text; existing_row record;
begin
  if (select auth.uid()) is null then raise exception 'authentication_required'; end if;
  if not public.current_user_has_gym_role(target_gym,array['owner','manager','staff']) then raise exception 'permission_denied'; end if;
  if request_key is null then raise exception 'idempotency_key_required'; end if;
  perform pg_advisory_xact_lock(hashtextextended(target_gym::text||':'||target_member::text,21));
  select m.id as mid,i.id as iid,i.invoice_number,m.starts_at,m.ends_at,i.total_paise,m.payment_status,m.member_id,m.plan_id
    into existing_row from public.memberships m join public.invoices i on i.gym_id=m.gym_id and i.membership_id=m.id
    where m.gym_id=target_gym and m.request_key=create_membership_for_gym.request_key;
  if found then
    if existing_row.member_id<>target_member or existing_row.plan_id<>target_plan then raise exception 'idempotency_conflict'; end if;
    return query select existing_row.mid,existing_row.iid,existing_row.invoice_number,existing_row.starts_at,existing_row.ends_at,existing_row.total_paise,existing_row.payment_status; return;
  end if;
  if exists(select 1 from public.memberships m where m.gym_id=target_gym and m.member_id=target_member and m.payment_status in ('pending','partial') and m.cancelled_at is null) then raise exception 'pending_membership_exists'; end if;
  select g.timezone into gym_tz from public.gyms g where g.id=target_gym;
  if gym_tz is null then raise exception 'gym_not_found'; end if;
  if not exists(select 1 from public.members m where m.gym_id=target_gym and m.id=target_member and m.archived_at is null) then raise exception 'member_not_found'; end if;
  select p.* into plan_row from public.membership_plans p where p.gym_id=target_gym and p.id=target_plan and p.active=true;
  if not found then raise exception 'plan_not_found'; end if;
  select max(m.ends_at) into latest_end from public.memberships m where m.gym_id=target_gym and m.member_id=target_member
    and m.payment_status in ('paid','waived') and m.ends_at>now() and m.paused_at is null and m.cancelled_at is null;
  start_at := case when latest_end is not null then latest_end else coalesce(selected_start_date,(now() at time zone gym_tz)::date)::timestamp at time zone gym_tz end;
  end_at := case when plan_row.duration_months is not null
    then ((start_at at time zone gym_tz)+make_interval(months=>plan_row.duration_months)) at time zone gym_tz
    else ((start_at at time zone gym_tz)+make_interval(days=>plan_row.duration_days)) at time zone gym_tz end;
  if end_at<=start_at then raise exception 'invalid_membership_term'; end if;
  insert into public.memberships(gym_id,member_id,plan_id,plan_name_snapshot,duration_months_snapshot,duration_days_snapshot,
    price_paise_snapshot,starts_at,ends_at,payment_status,request_key)
  values(target_gym,target_member,target_plan,plan_row.name,plan_row.duration_months,plan_row.duration_days,
    plan_row.price_paise,start_at,end_at,case when plan_row.price_paise=0 then 'waived' else 'pending' end,request_key)
  returning id into membership_new;
  update public.gym_invoice_counters set next_invoice_number=next_invoice_number+1,updated_at=now()
    where gym_id=target_gym returning next_invoice_number-1 into invoice_seq;
  if invoice_seq is null then raise exception 'invoice_counter_missing'; end if;
  invoice_no:='GF-'||lpad(invoice_seq::text,8,'0');
  insert into public.invoices(gym_id,member_id,membership_id,invoice_number,subtotal_paise,discount_paise,total_paise,status)
    values(target_gym,target_member,membership_new,invoice_no,plan_row.price_paise,0,plan_row.price_paise,case when plan_row.price_paise=0 then 'paid' else 'open' end)
    returning id into invoice_new;
  insert into public.invoice_items(gym_id,invoice_id,description,quantity,unit_price_paise,line_total_paise)
    values(target_gym,invoice_new,plan_row.name,1,plan_row.price_paise,plan_row.price_paise);
  insert into public.audit_logs(gym_id,actor_user_id,action,entity_type,entity_id,after_data)
    values(target_gym,(select auth.uid()),'membership.created','membership',membership_new,
      jsonb_build_object('member_id',target_member,'plan_id',target_plan,'invoice_id',invoice_new,'starts_at',start_at,'ends_at',end_at,'price_paise',plan_row.price_paise));
  return query select membership_new,invoice_new,invoice_no,start_at,end_at,plan_row.price_paise,case when plan_row.price_paise=0 then 'waived' else 'pending' end;
end $$;

create or replace function public.record_manual_payment_for_gym(
  target_gym uuid,target_invoice uuid,amount_paise bigint,payment_method text,payment_reference text,idempotency_key uuid
)
returns table(payment_id uuid,invoice_id uuid,recorded_amount_paise bigint,invoice_status text,remaining_paise bigint)
language plpgsql security definer set search_path='' set row_security=off as $$
declare inv record; already_paid bigint; remaining bigint; payment_new uuid; next_status text; old_payment record;
begin
  if (select auth.uid()) is null then raise exception 'authentication_required'; end if;
  if not public.current_user_has_gym_role(target_gym,array['owner','manager','staff']) then raise exception 'permission_denied'; end if;
  if amount_paise is null or amount_paise<=0 then raise exception 'invalid_payment_amount'; end if;
  if payment_method not in ('manual_cash','manual_upi','manual_bank') then raise exception 'invalid_payment_method'; end if;
  if idempotency_key is null then raise exception 'idempotency_key_required'; end if;
  perform pg_advisory_xact_lock(hashtextextended(target_gym::text||':payment:'||idempotency_key::text,31));
  select p.id,pa.invoice_id,p.amount_paise,i.status into old_payment from public.payments p
    join public.payment_allocations pa on pa.gym_id=p.gym_id and pa.payment_id=p.id
    join public.invoices i on i.gym_id=pa.gym_id and i.id=pa.invoice_id
    where p.gym_id=target_gym and p.idempotency_key=record_manual_payment_for_gym.idempotency_key;
  if found then
    if old_payment.invoice_id<>target_invoice or old_payment.amount_paise<>amount_paise then raise exception 'idempotency_conflict'; end if;
    select i.total_paise-coalesce(sum(pa.amount_paise) filter(where p.status='succeeded'),0) into remaining
      from public.invoices i left join public.payment_allocations pa on pa.gym_id=i.gym_id and pa.invoice_id=i.id
      left join public.payments p on p.gym_id=pa.gym_id and p.id=pa.payment_id where i.gym_id=target_gym and i.id=target_invoice group by i.total_paise;
    return query select old_payment.id,target_invoice,old_payment.amount_paise,old_payment.status,greatest(coalesce(remaining,0),0); return;
  end if;
  select i.* into inv from public.invoices i where i.gym_id=target_gym and i.id=target_invoice for update;
  if not found then raise exception 'invoice_not_found'; end if;
  if inv.status not in ('open','partially_paid') then raise exception 'invoice_not_payable'; end if;
  select coalesce(sum(pa.amount_paise),0)::bigint into already_paid from public.payment_allocations pa
    join public.payments p on p.gym_id=pa.gym_id and p.id=pa.payment_id
    where pa.gym_id=target_gym and pa.invoice_id=target_invoice and p.status='succeeded';
  remaining:=inv.total_paise-already_paid;
  if amount_paise>remaining then raise exception 'payment_exceeds_balance'; end if;
  insert into public.payments(gym_id,member_id,provider,idempotency_key,amount_paise,status,received_at,notes,created_by)
    values(target_gym,inv.member_id,payment_method,idempotency_key,amount_paise,'succeeded',now(),nullif(trim(coalesce(payment_reference,'')),''),(select auth.uid())) returning id into payment_new;
  insert into public.payment_allocations(gym_id,payment_id,invoice_id,amount_paise) values(target_gym,payment_new,target_invoice,amount_paise);
  remaining:=remaining-amount_paise; next_status:=case when remaining=0 then 'paid' else 'partially_paid' end;
  update public.invoices set status=next_status,updated_at=now() where gym_id=target_gym and id=target_invoice;
  if inv.membership_id is not null then update public.memberships set payment_status=case when remaining=0 then 'paid' else 'partial' end,updated_at=now() where gym_id=target_gym and id=inv.membership_id; end if;
  insert into public.audit_logs(gym_id,actor_user_id,action,entity_type,entity_id,after_data)
    values(target_gym,(select auth.uid()),'payment.manual_recorded','payment',payment_new,jsonb_build_object('invoice_id',target_invoice,'amount_paise',amount_paise,'method',payment_method));
  return query select payment_new,target_invoice,amount_paise,next_status,remaining;
end $$;

create or replace function public.void_pending_membership_for_gym(target_gym uuid,target_membership uuid)
returns void language plpgsql security definer set search_path='' set row_security=off as $$
declare member_key uuid; invoice_key uuid; inv_status text; pay_status text;
begin
  if (select auth.uid()) is null then raise exception 'authentication_required'; end if;
  if not public.current_user_has_gym_role(target_gym,array['owner','manager']) then raise exception 'permission_denied'; end if;
  select m.member_id,i.id into member_key,invoice_key from public.memberships m join public.invoices i on i.gym_id=m.gym_id and i.membership_id=m.id where m.gym_id=target_gym and m.id=target_membership;
  if not found then raise exception 'membership_not_found'; end if;
  perform pg_advisory_xact_lock(hashtextextended(target_gym::text||':'||member_key::text,21));
  select status into inv_status from public.invoices where gym_id=target_gym and id=invoice_key for update;
  select payment_status into pay_status from public.memberships where gym_id=target_gym and id=target_membership for update;
  if pay_status<>'pending' or inv_status<>'open' then raise exception 'membership_not_voidable'; end if;
  if exists(select 1 from public.payment_allocations pa join public.payments p on p.gym_id=pa.gym_id and p.id=pa.payment_id where pa.gym_id=target_gym and pa.invoice_id=invoice_key and p.status='succeeded') then raise exception 'membership_has_payments'; end if;
  update public.invoices set status='void',updated_at=now() where gym_id=target_gym and id=invoice_key;
  update public.memberships set payment_status='cancelled',cancelled_at=now(),updated_at=now() where gym_id=target_gym and id=target_membership;
  insert into public.audit_logs(gym_id,actor_user_id,action,entity_type,entity_id) values(target_gym,(select auth.uid()),'membership.pending_voided','membership',target_membership);
end $$;

create or replace function public.gym_membership_dues(target_gym uuid,cutoff_at timestamptz)
returns table(membership_id uuid,member_id uuid,starts_at timestamptz,ends_at timestamptz)
language sql stable security invoker set search_path='' as $$
  select latest.id,latest.member_id,latest.starts_at,latest.ends_at from (
    select distinct on(m.member_id) m.id,m.member_id,m.starts_at,m.ends_at,m.created_at
    from public.memberships m where m.gym_id=target_gym and m.payment_status in('paid','waived')
      and m.paused_at is null and m.cancelled_at is null and public.current_user_has_gym_access(target_gym)
    order by m.member_id,m.ends_at desc,m.created_at desc
  ) latest where latest.starts_at<=now() and latest.ends_at<=cutoff_at order by latest.ends_at;
$$;

create or replace function public.gym_finance_summary(target_gym uuid)
returns table(total_collected_paise bigint,refunds_paise bigint,net_collected_paise bigint,outstanding_paise bigint,active_members bigint,upcoming_7d bigint)
language sql stable security invoker set search_path='' as $$
 select
  coalesce((select sum(p.amount_paise) from public.payments p where p.gym_id=target_gym and p.status='succeeded'),0)::bigint,
  coalesce((select sum(r.amount_paise) from public.refunds r where r.gym_id=target_gym and r.status='succeeded'),0)::bigint,
  (coalesce((select sum(p.amount_paise) from public.payments p where p.gym_id=target_gym and p.status='succeeded'),0)-coalesce((select sum(r.amount_paise) from public.refunds r where r.gym_id=target_gym and r.status='succeeded'),0))::bigint,
  coalesce((select sum(i.total_paise-coalesce(a.paid,0)) from public.invoices i left join lateral (select sum(pa.amount_paise) paid from public.payment_allocations pa join public.payments p on p.gym_id=pa.gym_id and p.id=pa.payment_id where pa.gym_id=i.gym_id and pa.invoice_id=i.id and p.status='succeeded') a on true where i.gym_id=target_gym and i.status in('open','partially_paid')),0)::bigint,
  (select count(distinct m.member_id) from public.memberships m where m.gym_id=target_gym and m.payment_status in('paid','waived') and m.starts_at<=now() and m.ends_at>now() and m.paused_at is null and m.cancelled_at is null),
  (select count(*) from public.memberships m where m.gym_id=target_gym and m.payment_status in('paid','waived') and m.ends_at>now() and m.ends_at<=now()+interval '7 days' and m.paused_at is null and m.cancelled_at is null)
 where public.current_user_has_gym_access(target_gym);
$$;

revoke all on function public.create_member_for_gym(uuid,text,text,text,uuid) from public,anon;
revoke all on function public.create_membership_plan_for_gym(uuid,text,integer,integer,bigint) from public,anon;
revoke all on function public.create_membership_for_gym(uuid,uuid,uuid,date,uuid) from public,anon;
revoke all on function public.record_manual_payment_for_gym(uuid,uuid,bigint,text,text,uuid) from public,anon;
revoke all on function public.void_pending_membership_for_gym(uuid,uuid) from public,anon;
revoke all on function public.gym_membership_dues(uuid,timestamptz) from public,anon;
revoke all on function public.gym_finance_summary(uuid) from public,anon;
grant execute on function public.create_member_for_gym(uuid,text,text,text,uuid) to authenticated;
grant execute on function public.create_membership_plan_for_gym(uuid,text,integer,integer,bigint) to authenticated;
grant execute on function public.create_membership_for_gym(uuid,uuid,uuid,date,uuid) to authenticated;
grant execute on function public.record_manual_payment_for_gym(uuid,uuid,bigint,text,text,uuid) to authenticated;
grant execute on function public.void_pending_membership_for_gym(uuid,uuid) to authenticated;
grant execute on function public.gym_membership_dues(uuid,timestamptz) to authenticated;
grant execute on function public.gym_finance_summary(uuid) to authenticated;
commit;
