begin;

-- Active member directory lookups are gym-scoped and normally newest-first.
create index if not exists members_gym_active_created_idx
  on public.members(gym_id, created_at desc)
  where archived_at is null;

create or replace function public.update_member_for_gym(
  target_gym uuid,
  target_member uuid,
  member_name text,
  member_phone text,
  member_address text default null
)
returns void
language plpgsql
security definer
set search_path=''
set row_security=off
as $$
declare before_row public.members%rowtype;
begin
  if (select auth.uid()) is null then raise exception 'authentication_required'; end if;
  if not public.current_user_has_gym_role(target_gym,array['owner','manager','staff']) then
    raise exception 'permission_denied';
  end if;
  if length(trim(coalesce(member_name,''))) not between 1 and 120 then
    raise exception 'invalid_member_name';
  end if;
  if coalesce(member_phone,'') !~ '^[+][1-9][0-9]{7,14}$' then
    raise exception 'invalid_member_phone';
  end if;
  if length(coalesce(member_address,'')) > 500 then
    raise exception 'invalid_member_address';
  end if;

  select * into before_row
  from public.members
  where gym_id=target_gym and id=target_member and archived_at is null
  for update;
  if not found then raise exception 'member_not_found'; end if;

  update public.members
  set full_name=trim(member_name),
      phone_e164=member_phone,
      address=nullif(trim(coalesce(member_address,'')),''),
      updated_at=now()
  where gym_id=target_gym and id=target_member;

  insert into public.audit_logs(gym_id,actor_user_id,action,entity_type,entity_id,before_data,after_data)
  values(
    target_gym,(select auth.uid()),'member.updated','member',target_member,
    jsonb_build_object('full_name',before_row.full_name,'phone_e164',before_row.phone_e164,'address',before_row.address),
    jsonb_build_object('full_name',trim(member_name),'phone_e164',member_phone,'address',nullif(trim(coalesce(member_address,'')),''))
  );
end;
$$;

create or replace function public.set_member_archived_for_gym(
  target_gym uuid,
  target_member uuid,
  should_archive boolean
)
returns void
language plpgsql
security definer
set search_path=''
set row_security=off
as $$
declare before_value timestamptz; after_value timestamptz;
begin
  if (select auth.uid()) is null then raise exception 'authentication_required'; end if;
  if not public.current_user_has_gym_role(target_gym,array['owner','manager']) then
    raise exception 'permission_denied';
  end if;
  if should_archive is null then raise exception 'invalid_archive_state'; end if;

  select archived_at into before_value
  from public.members
  where gym_id=target_gym and id=target_member
  for update;
  if not found then raise exception 'member_not_found'; end if;

  after_value := case when should_archive then coalesce(before_value,now()) else null end;
  update public.members
  set archived_at=after_value, updated_at=now()
  where gym_id=target_gym and id=target_member;

  insert into public.audit_logs(gym_id,actor_user_id,action,entity_type,entity_id,before_data,after_data)
  values(
    target_gym,(select auth.uid()),
    case when should_archive then 'member.archived' else 'member.restored' end,
    'member',target_member,
    jsonb_build_object('archived_at',before_value),
    jsonb_build_object('archived_at',after_value)
  );
end;
$$;

revoke all on function public.update_member_for_gym(uuid,uuid,text,text,text) from public,anon;
revoke all on function public.set_member_archived_for_gym(uuid,uuid,boolean) from public,anon;
grant execute on function public.update_member_for_gym(uuid,uuid,text,text,text) to authenticated;
grant execute on function public.set_member_archived_for_gym(uuid,uuid,boolean) to authenticated;

-- Return member fields with due memberships so the dues page avoids a second
-- round trip to fetch the corresponding member rows.
drop function public.gym_membership_dues(uuid,timestamptz);
create function public.gym_membership_dues(target_gym uuid,cutoff_at timestamptz)
returns table(
  membership_id uuid,
  member_id uuid,
  starts_at timestamptz,
  ends_at timestamptz,
  member_number char(5),
  member_name text,
  phone_e164 text
)
language sql
stable
security invoker
set search_path=''
as $$
  select latest.id,latest.member_id,latest.starts_at,latest.ends_at,
         member.member_number,member.full_name,member.phone_e164
  from (
    select distinct on(m.member_id) m.id,m.member_id,m.starts_at,m.ends_at,m.created_at
    from public.memberships m
    where m.gym_id=target_gym
      and m.payment_status in('paid','waived')
      and m.paused_at is null
      and m.cancelled_at is null
      and public.current_user_has_gym_access(target_gym)
    order by m.member_id,m.ends_at desc,m.created_at desc
  ) latest
  join public.members member
    on member.gym_id=target_gym and member.id=latest.member_id
  where latest.starts_at<=now() and latest.ends_at<=cutoff_at
  order by latest.ends_at;
$$;
revoke all on function public.gym_membership_dues(uuid,timestamptz) from public,anon;
grant execute on function public.gym_membership_dues(uuid,timestamptz) to authenticated;

commit;
