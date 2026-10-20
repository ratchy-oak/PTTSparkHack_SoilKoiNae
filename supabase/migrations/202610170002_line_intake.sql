-- Run once AFTER 202610170001_initial_schema.sql. No sample data or keys.
begin;

create table public.line_accounts (
 line_user_id text primary key, member_id uuid not null unique references public.members(id),
 active boolean not null default true, linked_at timestamptz not null default now()
);
create table public.line_invitations (
 token_hash text primary key, member_id uuid not null references public.members(id),
 created_by uuid not null references public.profiles(id), created_at timestamptz not null default now(),
 expires_at timestamptz not null, used_at timestamptz
);
create table public.line_link_attempts (
 line_user_id text primary key, window_start timestamptz not null, attempts integer not null
);
create table public.line_withdrawals (
 message_id text primary key, line_user_id text not null, withdrawn_at timestamptz not null default now()
);
create table public.line_messages (
 id uuid primary key default gen_random_uuid(), event_id text not null unique references public.webhook_events(event_id),
 message_id text not null unique, member_id uuid not null references public.members(id),
 line_user_id text not null, body_text text, sent_at timestamptz not null,
 received_at timestamptz not null default now(), withdrawn_at timestamptz,
 activity_id uuid unique references public.activities(id),
 check(body_text is not null or withdrawn_at is not null)
);
create index line_messages_received on public.line_messages(received_at desc,id);
create index line_messages_member on public.line_messages(member_id,received_at desc);
create index line_invitations_member on public.line_invitations(member_id);
alter table public.line_accounts enable row level security;
alter table public.line_invitations enable row level security;
alter table public.line_link_attempts enable row level security;
alter table public.line_withdrawals enable row level security;
alter table public.line_messages enable row level security;
revoke all on public.line_accounts,public.line_invitations,public.line_link_attempts,public.line_withdrawals,public.line_messages from public,anon,authenticated;
grant all on public.line_accounts,public.line_invitations,public.line_link_attempts,public.line_withdrawals,public.line_messages,public.webhook_events to service_role;
-- Browser users cannot access LINE identifiers, invitations, or raw webhook events.
grant select(id,event_id,message_id,member_id,body_text,sent_at,received_at,withdrawn_at,activity_id) on public.line_messages to authenticated;
create policy line_messages_staff_read on public.line_messages for select to authenticated using(private.is_staff());

create function public.line_member_status(p_member_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare account public.line_accounts;
begin
 if not private.is_staff() then raise exception 'Staff required' using errcode='42501'; end if;
 select * into account from public.line_accounts where member_id=p_member_id;
 return jsonb_build_object('linked',found,'active',coalesce(account.active,false),'linked_at',account.linked_at);
end; $$;
revoke all on function public.line_member_status(uuid) from public,anon;
grant execute on function public.line_member_status(uuid) to authenticated;

create function public.create_line_invitation(p_member_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare token text; expiry timestamptz:=now()+interval '30 minutes';
begin
 if not private.can_manage() then raise exception 'Manager required' using errcode='42501'; end if;
 perform 1 from public.members where id=p_member_id and active for update;
 if not found then raise exception 'Active member required'; end if;
 if exists(select 1 from public.line_accounts where member_id=p_member_id) then raise exception 'Member already linked'; end if;
 update public.line_invitations set expires_at=now() where member_id=p_member_id and used_at is null and expires_at>now();
 token:=upper(replace(gen_random_uuid()::text,'-',''));
 insert into public.line_invitations(token_hash,member_id,created_by,expires_at)
 values(encode(sha256(convert_to(token,'UTF8')),'hex'),p_member_id,auth.uid(),expiry);
 return jsonb_build_object('code',token,'expires_at',expiry);
end; $$;
revoke all on function public.create_line_invitation(uuid) from public,anon;
grant execute on function public.create_line_invitation(uuid) to authenticated;

-- Atomic persistence/deduplication. Only a signed webhook's server client may execute.
-- Input p_kind: follow, unfollow, text, unsupported, unsend. No reply tokens are stored.
create function public.ingest_line_event(
 p_event_id text,p_kind text,p_line_user_id text,p_message_id text,p_text text,p_sent_at timestamptz
) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
 claimed text; reply text; code text; invitation public.line_invitations;
 account public.line_accounts; target uuid; attempt_count integer;
 message_record public.line_messages;
begin
 if length(p_event_id)>180 or length(p_line_user_id)>180 or length(coalesce(p_text,''))>5000
   or p_event_id is null or p_line_user_id is null or p_sent_at is null
   or p_kind not in ('follow','unfollow','text','unsupported','unsend') then raise exception 'Invalid event'; end if;
 insert into public.webhook_events(event_id,event_type,payload,processed_at,last_error)
 values(p_event_id,p_kind,jsonb_build_object('kind',p_kind),now(),case when p_kind in ('text','follow','unsupported') then 'line_reply_unconfirmed' else null end)
 on conflict(event_id) do nothing returning event_id into claimed;
 if claimed is null then return jsonb_build_object('duplicate',true); end if;
 -- Serialize operations per sender across concurrent webhook deliveries.
 perform pg_advisory_xact_lock(hashtextextended(p_line_user_id,0));
 if p_kind='unfollow' then
  update public.line_accounts set active=false where line_user_id=p_line_user_id;
  return jsonb_build_object('duplicate',false);
 elsif p_kind='follow' then
  update public.line_accounts set active=true where line_user_id=p_line_user_id;
  return jsonb_build_object('duplicate',false,'reply','สวัสดีครับ นาคุ้มช่วยส่งบันทึกให้ทีมส่งเสริมได้ ขอข้อความเชื่อมบัญชีจากเจ้าหน้าที่แล้วคัดลอกมาส่งในแชตนี้ได้เลยครับ');
 elsif p_kind='unsend' then
  insert into public.line_withdrawals(message_id,line_user_id) values(p_message_id,p_line_user_id) on conflict do nothing;
  select * into message_record from public.line_messages where message_id=p_message_id and line_user_id=p_line_user_id for update;
  if found then
   update public.line_messages set body_text=null,withdrawn_at=now() where id=message_record.id;
   if message_record.activity_id is not null then
    -- Redact both the record and historical audit copies of withdrawn text.
    update public.activities set description='ผู้ส่งยกเลิกข้อความต้นทาง กรุณาขอข้อมูลใหม่',occurred_on=null,
      status='needs_info',reviewed_by=null,reviewed_at=null,review_note=null where id=message_record.activity_id;
    -- A previously verified record first resets to pending in the review trigger.
    update public.activities set status='needs_info' where id=message_record.activity_id;
    update public.audit_log set old_data=old_data-'description',new_data=new_data-'description'
      where table_name='activities' and record_id=message_record.activity_id;
   end if;
  end if;
  return jsonb_build_object('duplicate',false);
 end if;
 if p_kind='unsupported' then
  return jsonb_build_object('duplicate',false,'reply','รุ่นนี้รับบันทึกเป็นข้อความก่อนครับ รูปและเสียงยังไม่ถูกบันทึก กรุณาพิมพ์กิจกรรม แปลง และวันที่ หรือขอเจ้าหน้าที่ช่วยครับ');
 end if;
 if trim(p_text) like 'เชื่อม %' then
  insert into public.line_link_attempts(line_user_id,window_start,attempts) values(p_line_user_id,now(),1)
  on conflict(line_user_id) do update set
   attempts=case when public.line_link_attempts.window_start<now()-interval '15 minutes' then 1 else public.line_link_attempts.attempts+1 end,
   window_start=case when public.line_link_attempts.window_start<now()-interval '15 minutes' then now() else public.line_link_attempts.window_start end
  returning attempts into attempt_count;
  if attempt_count>8 then return jsonb_build_object('duplicate',false,'reply','ลองเชื่อมหลายครั้งแล้ว กรุณารอ 15 นาทีแล้วลองใหม่ หรือติดต่อเจ้าหน้าที่ครับ'); end if;
  -- Thai character length is counted by PostgreSQL, not UTF-8 bytes.
  code:=upper(regexp_replace(substring(trim(p_text) from '^เชื่อม[[:space:]]+(.*)$'),'[[:space:]-]','','g'));
  if code is null or code !~ '^[A-F0-9]{32}$' then
   return jsonb_build_object('duplicate',false,'reply','ข้อความเชื่อมบัญชีไม่ถูกต้อง กรุณาคัดลอกทั้งข้อความที่เจ้าหน้าที่ให้มาครับ');
  end if;
  select * into invitation from public.line_invitations where token_hash=encode(sha256(convert_to(code,'UTF8')),'hex') and used_at is null and expires_at>now() for update;
  if not found then return jsonb_build_object('duplicate',false,'reply','ข้อความเชื่อมบัญชีใช้ไม่ได้หรือหมดอายุแล้ว กรุณาขอข้อความใหม่จากเจ้าหน้าที่ครับ'); end if;
  perform 1 from public.members where id=invitation.member_id and active for update;
  if not found or exists(select 1 from public.line_accounts where line_user_id=p_line_user_id or member_id=invitation.member_id) then
   return jsonb_build_object('duplicate',false,'reply','บัญชีนี้ยังเชื่อมไม่ได้ กรุณาให้เจ้าหน้าที่ตรวจสอบสมาชิกและบัญชี LINE ครับ');
  end if;
  insert into public.line_accounts(line_user_id,member_id) values(p_line_user_id,invitation.member_id);
  update public.line_invitations set used_at=now() where token_hash=invitation.token_hash;
  return jsonb_build_object('duplicate',false,'reply','เชื่อมบัญชีสำเร็จแล้วครับ ส่งข้อความบอกกิจกรรม ชื่อหรือรหัสแปลง และวันที่ทำได้เลย เช่น วันนี้รดน้ำแปลงหน้าบ้าน เจ้าหน้าที่จะตรวจข้อมูลก่อนยืนยันครับ');
 end if;
 select * into account from public.line_accounts where line_user_id=p_line_user_id and active;
 if not found then return jsonb_build_object('duplicate',false,'reply','กรุณาขอข้อความเชื่อมบัญชีจากเจ้าหน้าที่ก่อนครับ เพื่อให้บันทึกเข้าถูกสมาชิก'); end if;
 perform 1 from public.members where id=account.member_id and active;
 if not found then return jsonb_build_object('duplicate',false,'reply','สมาชิกนี้พักใช้งานอยู่ กรุณาติดต่อเจ้าหน้าที่ครับ'); end if;
 if trim(coalesce(p_text,''))='' then return jsonb_build_object('duplicate',false,'reply','กรุณาพิมพ์กิจกรรม แปลง และวันที่ทำครับ'); end if;
 if exists(select 1 from public.line_withdrawals where message_id=p_message_id and line_user_id=p_line_user_id) then
  update public.webhook_events set last_error=null where event_id=p_event_id;
  return jsonb_build_object('duplicate',false);
 end if;
 insert into public.line_messages(event_id,message_id,member_id,line_user_id,body_text,sent_at)
 values(p_event_id,p_message_id,account.member_id,p_line_user_id,p_text,p_sent_at)
 on conflict(message_id) do nothing returning id into target;
 if target is null then
  update public.webhook_events set last_error=null where event_id=p_event_id;
  return jsonb_build_object('duplicate',true);
 end if;
 return jsonb_build_object('duplicate',false,'reply','รับข้อความไว้ให้ทีมส่งเสริมแล้วครับ หากยังไม่ได้ระบุแปลงหรือวันที่ กรุณาส่งเพิ่มได้ การรับข้อความยังไม่ใช่การยืนยันบันทึกหรือรับรองมาตรฐานครับ');
end; $$;
revoke all on function public.ingest_line_event(text,text,text,text,text,timestamptz) from public,anon,authenticated;
grant execute on function public.ingest_line_event(text,text,text,text,text,timestamptz) to service_role;

create function public.record_line_activity(p_message_id uuid,p_plot_id uuid,p_occurred_on date,p_activity_type text,p_description text) returns uuid
language plpgsql security definer set search_path='' as $$
declare source public.line_messages; result uuid;
begin
 if not private.is_staff() then raise exception 'Staff required' using errcode='42501'; end if;
 select * into source from public.line_messages where id=p_message_id for update;
 if not found or source.withdrawn_at is not null then raise exception 'Message unavailable'; end if;
 if source.activity_id is not null then return source.activity_id; end if;
 perform 1 from public.members where id=source.member_id and active;
 if not found then raise exception 'Active member required'; end if;
 perform 1 from public.plots where id=p_plot_id and member_id=source.member_id;
 if not found then raise exception 'Plot does not belong to member'; end if;
 if p_occurred_on is null or p_occurred_on>(now() at time zone 'Asia/Bangkok')::date
  or p_activity_type not in ('เตรียมแปลง','ปลูก','ดูแลแปลง','เก็บเกี่ยว','อื่น ๆ')
  or p_description is null or length(trim(p_description))=0 or length(p_description)>10000 then raise exception 'Invalid activity'; end if;
 insert into public.activities(member_id,plot_id,activity_type,occurred_on,description,status,submitted_by,received_at)
 values(source.member_id,p_plot_id,p_activity_type,p_occurred_on,trim(p_description),'pending',auth.uid(),source.received_at) returning id into result;
 update public.line_messages set activity_id=result where id=source.id;
 return result;
end; $$;
revoke all on function public.record_line_activity(uuid,uuid,date,text,text) from public,anon;
grant execute on function public.record_line_activity(uuid,uuid,date,text,text) to authenticated;

create function public.review_line_activity(p_message_id uuid,p_status public.activity_status,p_note text) returns void
language plpgsql security definer set search_path='' as $$
declare source public.line_messages;
begin
 if not private.is_staff() then raise exception 'Staff required' using errcode='42501'; end if;
 select * into source from public.line_messages where id=p_message_id for update;
 if not found or source.withdrawn_at is not null or source.activity_id is null then raise exception 'Message unavailable'; end if;
 if p_status is null or p_status not in ('verified','needs_info') or p_note is null or length(trim(p_note))=0 then raise exception 'Review reason required'; end if;
 update public.activities set status=p_status,review_note=trim(p_note),reviewed_by=auth.uid(),reviewed_at=now() where id=source.activity_id;
end; $$;
revoke all on function public.review_line_activity(uuid,public.activity_status,text) from public,anon;
grant execute on function public.review_line_activity(uuid,public.activity_status,text) to authenticated;

create function public.line_intake_health() returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if not private.is_staff() then raise exception 'Staff required' using errcode='42501'; end if;
 return (select jsonb_build_object('last_received_at',max(received_at),'events_received',count(*),
   'reply_issues',count(*) filter(where last_error in ('line_reply_failed','line_reply_unconfirmed')))
   from public.webhook_events);
end; $$;
revoke all on function public.line_intake_health() from public,anon;
grant execute on function public.line_intake_health() to authenticated;

commit;
