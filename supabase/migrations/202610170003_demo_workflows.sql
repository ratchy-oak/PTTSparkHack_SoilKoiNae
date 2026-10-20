-- Additive migration. Run once after 001 and 002. No farmer/demo rows are inserted.
begin;
alter table public.members add column revision integer not null default 1;
alter table public.plots add column revision integer not null default 1;
alter table public.material_requests add column revision integer not null default 1;
alter table public.material_requests add column conditions text;
alter table public.material_requests add constraint material_owner_unique unique(id,member_id,plot_id);
alter table public.activities add column material_request_id uuid;
alter table public.activities add constraint activity_material_owner foreign key(material_request_id,member_id,plot_id) references public.material_requests(id,member_id,plot_id);
alter table public.audit_log add column reason text;
alter table public.checklist_requirements add column active boolean not null default true;
alter table public.checklist_requirements add column requires_evidence boolean not null default false;
alter table public.checklist_requirements add column revision integer not null default 1;
alter table public.line_messages add column message_type text not null default 'text' check(message_type in ('text','image','audio'));
alter table public.line_messages add column material_request_id uuid unique references public.material_requests(id);
alter table public.line_messages add constraint line_one_record check(activity_id is null or material_request_id is null);
grant select(message_type,material_request_id) on public.line_messages to authenticated;

create or replace function private.audit_change() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 insert into public.audit_log(actor_id,table_name,record_id,operation,old_data,new_data,reason)
 values(auth.uid(),tg_table_name,case when tg_op='DELETE' then old.id else new.id end,tg_op,
 case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) else null end,
 case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) else null end,nullif(current_setting('app.change_reason',true),''));
 return coalesce(new,old);
end; $$;
create function private.bump_revision() returns trigger language plpgsql set search_path='' as $$
begin new.revision:=old.revision+1;return new;end; $$;
revoke all on function private.bump_revision() from public;
create trigger members_revision before update on public.members for each row execute function private.bump_revision();
create trigger plots_revision before update on public.plots for each row execute function private.bump_revision();
create trigger materials_revision before update on public.material_requests for each row execute function private.bump_revision();
create trigger requirements_revision before update on public.checklist_requirements for each row execute function private.bump_revision();
create trigger audit_plots after insert or update on public.plots for each row execute function private.audit_change();
create trigger audit_seasons after insert or update on public.seasons for each row execute function private.audit_change();
create trigger audit_requirements after insert or update on public.checklist_requirements for each row execute function private.audit_change();

-- All edits use checked RPCs, so reason and concurrency checks cannot be skipped by clients.
revoke update on public.members,public.plots,public.activities,public.material_requests,public.checklist_requirements from authenticated;
revoke insert on public.checklist_requirements from authenticated;
create function public.edit_member(p_id uuid,p_revision integer,p_code text,p_name text,p_village text,p_active boolean,p_reason text) returns public.members
language plpgsql security definer set search_path='' as $$
declare row public.members;
begin
 if not private.can_manage() then raise exception 'Manager required' using errcode='42501';end if;
 select * into row from public.members where id=p_id for update;
 if not found or row.revision is distinct from p_revision then raise exception 'STALE_RECORD';end if;
 if coalesce(trim(p_code),'')='' or coalesce(trim(p_name),'')='' or coalesce(trim(p_reason),'')='' or p_active is null then raise exception 'Required fields missing';end if;
 perform set_config('app.change_reason',trim(p_reason),true);
 update public.members set code=trim(p_code),display_name=trim(p_name),village=nullif(trim(p_village),''),active=p_active where id=p_id returning * into row;
 return row;
end; $$;
create function public.edit_plot(p_id uuid,p_revision integer,p_code text,p_name text,p_area numeric,p_reason text) returns public.plots
language plpgsql security definer set search_path='' as $$
declare row public.plots;
begin
 if not private.is_staff() then raise exception 'Staff required' using errcode='42501';end if;
 select * into row from public.plots where id=p_id for update;
 if not found or row.revision is distinct from p_revision then raise exception 'STALE_RECORD';end if;
 if coalesce(trim(p_code),'')='' or coalesce(trim(p_name),'')='' or coalesce(trim(p_reason),'')='' or (p_area is not null and (p_area<=0 or p_area<>round(p_area,2))) then raise exception 'Required fields missing';end if;
 perform set_config('app.change_reason',trim(p_reason),true);
 update public.plots set code=trim(p_code),name=trim(p_name),area_rai=p_area where id=p_id returning * into row;
 return row;
end; $$;

create or replace function private.protect_activity_review() returns trigger
language plpgsql set search_path='' as $$
begin
 if tg_op='UPDATE' then
  if new.member_id<>old.member_id or new.submitted_by<>old.submitted_by or new.received_at<>old.received_at then raise exception 'Ownership and provenance cannot be changed';end if;
  new.revision:=old.revision+1;
  if old.status='verified' and (new.description is distinct from old.description or new.occurred_on is distinct from old.occurred_on or new.activity_type is distinct from old.activity_type or new.season_id is distinct from old.season_id or new.plot_id is distinct from old.plot_id or new.material_request_id is distinct from old.material_request_id) then
   new.status:='pending';new.reviewed_by:=null;new.reviewed_at:=null;new.review_note:=null;
  end if;
 end if;
 if new.status='verified' and (tg_op='INSERT' or old.status is distinct from new.status) then
  if not private.is_staff() then raise exception 'Staff review required';end if;
  new.reviewed_by:=auth.uid();new.reviewed_at:=now();
 end if;
 new.updated_at:=now();return new;
end; $$;
create function public.save_activity(p_id uuid,p_revision integer,p_member_id uuid,p_plot_id uuid,p_season_id uuid,p_date date,p_type text,p_description text,p_material_id uuid,p_reason text) returns uuid
language plpgsql security definer set search_path='' as $$
declare row public.activities;result uuid;
begin
 if not private.is_staff() then raise exception 'Staff required' using errcode='42501';end if;
 perform 1 from public.members where id=p_member_id and active for share;
 if not found then raise exception 'Active member required';end if;
 if p_date is null or p_date>(now() at time zone 'Asia/Bangkok')::date or coalesce(trim(p_type),'')='' or coalesce(trim(p_description),'')='' then raise exception 'Required fields missing';end if;
 perform 1 from public.plots where id=p_plot_id and member_id=p_member_id;
 if not found then raise exception 'Wrong plot';end if;
 if p_id is null then
  insert into public.activities(member_id,plot_id,season_id,activity_type,occurred_on,description,status,material_request_id)
  values(p_member_id,p_plot_id,p_season_id,trim(p_type),p_date,trim(p_description),'pending',p_material_id) returning id into result;
 else
  -- Lock the source before the activity, matching webhook/withdrawal lock order.
  perform 1 from public.line_messages where activity_id=p_id for update;
  if exists(select 1 from public.line_messages where activity_id=p_id and withdrawn_at is not null) then raise exception 'Source withdrawn';end if;
  select * into row from public.activities where id=p_id for update;
  if not found or row.revision is distinct from p_revision then raise exception 'STALE_RECORD';end if;
  if row.member_id<>p_member_id or coalesce(trim(p_reason),'')='' then raise exception 'Correction reason required';end if;
  perform set_config('app.change_reason',trim(p_reason),true);
  update public.activities set plot_id=p_plot_id,season_id=p_season_id,activity_type=trim(p_type),occurred_on=p_date,description=trim(p_description),material_request_id=p_material_id,status='pending',reviewed_by=null,reviewed_at=null,review_note=null where id=p_id returning id into result;
 end if;
 return result;
end; $$;
create function public.review_activity(p_id uuid,p_revision integer,p_status public.activity_status,p_note text) returns void
language plpgsql security definer set search_path='' as $$
declare row public.activities;
begin
 if not private.is_staff() then raise exception 'Staff required' using errcode='42501';end if;
 perform 1 from public.line_messages where activity_id=p_id for update;
 if exists(select 1 from public.line_messages where activity_id=p_id and withdrawn_at is not null) then raise exception 'Source withdrawn';end if;
 select * into row from public.activities where id=p_id for update;
 if not found or row.revision is distinct from p_revision then raise exception 'STALE_RECORD';end if;
 if not exists(select 1 from public.members where id=row.member_id and active) then raise exception 'Active member required';end if;
 if p_status is null or p_status not in ('verified','needs_info') or coalesce(trim(p_note),'')='' then raise exception 'Review reason required';end if;
 perform set_config('app.change_reason',trim(p_note),true);
 update public.activities set status=p_status,review_note=trim(p_note),reviewed_by=auth.uid(),reviewed_at=now() where id=p_id;
end; $$;

create function public.submit_material_request(p_member_id uuid,p_plot_id uuid,p_name text,p_ingredients text,p_intended_on date,p_source_id uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare result uuid;source public.line_messages;
begin
 if not private.is_staff() then raise exception 'Staff required' using errcode='42501';end if;
 if not exists(select 1 from public.members where id=p_member_id and active) then raise exception 'Active member required';end if;
 if coalesce(trim(p_name),'')='' or coalesce(trim(p_ingredients),'')='' or p_intended_on is null then raise exception 'Required fields missing';end if;
 if p_source_id is not null then
  select * into source from public.line_messages where id=p_source_id for update;
  if not found or source.member_id<>p_member_id or source.withdrawn_at is not null or source.activity_id is not null then raise exception 'Invalid source';end if;
  if source.material_request_id is not null then return source.material_request_id;end if;
 end if;
 insert into public.material_requests(member_id,plot_id,material_name,ingredients,intended_on)
 values(p_member_id,p_plot_id,trim(p_name),trim(p_ingredients),p_intended_on) returning id into result;
 if p_source_id is not null then update public.line_messages set material_request_id=result where id=p_source_id;end if;
 return result;
end; $$;
create function public.decide_material_request(p_id uuid,p_revision integer,p_status public.request_status,p_reason text,p_conditions text,p_valid_from date,p_valid_until date) returns void
language plpgsql security definer set search_path='' as $$
declare row public.material_requests;
begin
 if not private.can_manage() then raise exception 'Manager required' using errcode='42501';end if;
 select * into row from public.material_requests where id=p_id for update;
 if not found or row.revision is distinct from p_revision then raise exception 'STALE_RECORD';end if;
 if row.status not in ('pending','needs_info') then raise exception 'Decision final; submit new request for a changed formula';end if;
 if p_status is null or p_status not in ('approved','rejected','needs_info') or coalesce(trim(p_reason),'')='' then raise exception 'Decision reason required';end if;
 if p_status='approved' and (coalesce(trim(p_conditions),'')='' or p_valid_from is null or p_valid_until is null or p_valid_until<p_valid_from) then raise exception 'Approval conditions and validity required';end if;
 if exists(select 1 from public.line_messages where material_request_id=p_id and withdrawn_at is not null) then raise exception 'Source withdrawn';end if;
 perform set_config('app.change_reason',trim(p_reason),true);
 update public.material_requests set status=p_status,decision_reason=trim(p_reason),conditions=nullif(trim(p_conditions),''),valid_from=case when p_status='approved' then p_valid_from else null end,valid_until=case when p_status='approved' then p_valid_until else null end where id=p_id;
end; $$;

create function public.configure_requirement(p_id uuid,p_revision integer,p_season_id uuid,p_title text,p_due date,p_version text,p_requires_evidence boolean,p_active boolean,p_reason text) returns uuid
language plpgsql security definer set search_path='' as $$
declare result uuid;row public.checklist_requirements;
begin
 if not private.can_manage() then raise exception 'Manager required' using errcode='42501';end if;
 if coalesce(trim(p_title),'')='' or p_due is null or coalesce(trim(p_version),'')='' or p_active is null or p_requires_evidence is null then raise exception 'Required fields missing';end if;
 if p_id is null then
  insert into public.checklist_requirements(season_id,title,due_on,rule_version,requires_evidence,active) values(p_season_id,trim(p_title),p_due,trim(p_version),p_requires_evidence,p_active) returning id into result;
 else
  select * into row from public.checklist_requirements where id=p_id for update;
  if not found or row.revision is distinct from p_revision then raise exception 'STALE_RECORD';end if;
  if row.season_id<>p_season_id or coalesce(trim(p_reason),'')='' then raise exception 'Correction reason required';end if;
  perform set_config('app.change_reason',trim(p_reason),true);
  update public.checklist_requirements set title=trim(p_title),due_on=p_due,rule_version=trim(p_version),requires_evidence=p_requires_evidence,active=p_active where id=p_id returning id into result;
 end if;return result;
end; $$;
create function public.match_requirement(p_id uuid,p_revision integer,p_activity_id uuid,p_note text) returns void
language plpgsql security definer set search_path='' as $$
declare row public.checklist_requirements;target public.activities;plot uuid;
begin
 if not private.is_staff() then raise exception 'Staff required' using errcode='42501';end if;
 select * into row from public.checklist_requirements where id=p_id for update;
 if not found or row.revision is distinct from p_revision then raise exception 'STALE_RECORD';end if;
 select plot_id into plot from public.seasons where id=row.season_id;
 if p_activity_id is not null then
  select * into target from public.activities where id=p_activity_id;
  if not found or target.season_id is distinct from row.season_id or target.plot_id<>plot then raise exception 'Activity must match season and plot';end if;
 end if;
 if coalesce(trim(p_note),'')='' then raise exception 'Review note required';end if;
 perform set_config('app.change_reason',trim(p_note),true);
 update public.checklist_requirements set verified_activity_id=p_activity_id where id=p_id;
end; $$;

create table public.line_media (
 id uuid primary key default gen_random_uuid(),source_id uuid not null unique references public.line_messages(id),
 storage_path text not null unique,media_type text not null check(media_type in ('image','audio')),
 mime_type text,byte_size integer check(byte_size between 1 and 10485760),sha256 text,
 status text not null default 'pending' check(status in ('pending','ready','failed','withdrawn')),
 created_at timestamptz not null default now()
);
alter table public.line_media enable row level security;
revoke all on public.line_media from public,anon,authenticated;
grant select on public.line_media to authenticated;
grant all on public.line_media to service_role;
create policy line_media_read on public.line_media for select to authenticated using(private.is_staff() and exists(select 1 from public.line_messages m where m.id=source_id and m.withdrawn_at is null));
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('line-media','line-media',false,10485760,array['image/jpeg','image/png','image/webp','image/gif','audio/mpeg','audio/mp4','audio/ogg','audio/wav','audio/x-m4a']);
create policy line_media_objects_read on storage.objects for select to authenticated using(bucket_id='line-media' and private.is_staff() and exists(select 1 from public.line_media m join public.line_messages s on s.id=m.source_id where m.storage_path=name and m.status='ready' and s.withdrawn_at is null));

-- Wrapper preserves the original signed-event transaction and adds durable media intake.
create function public.ingest_line_event_v3(p_event_id text,p_kind text,p_line_user_id text,p_message_id text,p_text text,p_sent_at timestamptz) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;source public.line_messages;media public.line_media;paths jsonb;
begin
 result:=public.ingest_line_event(p_event_id,case when p_kind in ('image','audio') then 'text' else p_kind end,p_line_user_id,p_message_id,
  case when p_kind='image' then 'รูปภาพจาก LINE' when p_kind='audio' then 'เสียงจาก LINE' else p_text end,p_sent_at);
 select * into source from public.line_messages where message_id=p_message_id and line_user_id=p_line_user_id for update;
 if p_kind='unsend' and found then
  update public.line_media set status='withdrawn' where source_id=source.id;
  if source.material_request_id is not null then
   perform set_config('app.change_reason','ผู้ส่งยกเลิกข้อความต้นทาง',true);
   update public.material_requests set material_name='ข้อมูลจาก LINE ถูกยกเลิก',ingredients='ผู้ส่งยกเลิกข้อความต้นทาง',status='pending',decided_by=null,decided_at=null,decision_reason=null,conditions=null,valid_from=null,valid_until=null where id=source.material_request_id;
   update public.audit_log set old_data=old_data-array['ingredients','material_name'],new_data=new_data-array['ingredients','material_name'] where table_name='material_requests' and record_id=source.material_request_id;
  end if;
  select coalesce(jsonb_agg(storage_path),'[]'::jsonb) into paths from public.line_media where source_id=source.id;
  return result||jsonb_build_object('purge_paths',paths);
 end if;
 if p_kind in ('image','audio') and source.id is not null and source.withdrawn_at is null then
  update public.line_messages set message_type=p_kind where id=source.id;
  insert into public.line_media(source_id,storage_path,media_type) values(source.id,'line/'||source.id::text||'/'||source.message_id,p_kind) on conflict(source_id) do nothing;
  select * into media from public.line_media where source_id=source.id;
  if media.status in ('pending','failed') then result:=result||jsonb_build_object('media',jsonb_build_object('id',media.id,'path',media.storage_path,'kind',media.media_type));end if;
  if not coalesce((result->>'duplicate')::boolean,false) then result:=result||jsonb_build_object('reply','รับหลักฐานแล้วครับ เจ้าหน้าที่จะตรวจแปลงและวันที่ก่อนยืนยัน');end if;
 end if;return result;
end; $$;
revoke all on function public.ingest_line_event_v3(text,text,text,text,text,timestamptz) from public,anon,authenticated;
grant execute on function public.ingest_line_event_v3(text,text,text,text,text,timestamptz) to service_role;

-- Add server-checked evidence registration. A path cannot point to another activity.
create function public.register_evidence(p_activity_id uuid,p_path text,p_type text,p_name text) returns uuid
language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 if not private.is_staff() then raise exception 'Staff required' using errcode='42501';end if;
 perform 1 from public.activities where id=p_activity_id and status<>'verified' for update;
 if not found then raise exception 'Reopen the activity before adding evidence';end if;
 if split_part(p_path,'/',1)<>p_activity_id::text or p_type not in ('image','audio','document') then raise exception 'Invalid path';end if;
 if not exists(select 1 from storage.objects where bucket_id='evidence' and name=p_path and owner_id=auth.uid()::text) then raise exception 'Upload required';end if;
 insert into public.evidence(activity_id,storage_path,media_type,original_filename) values(p_activity_id,p_path,p_type,p_name) returning id into result;
 return result;
end; $$;
revoke insert on public.evidence from authenticated;

create function public.member_history(p_member_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.is_staff() then raise exception 'Staff required' using errcode='42501';end if;
 return (select coalesce(jsonb_agg(x order by x.created_at desc,x.id desc),'[]') from (
  select l.id,l.created_at,l.table_name,l.operation,l.reason,p.display_name actor,l.old_data-'profile_id' old_data,l.new_data-'profile_id' new_data
  from public.audit_log l left join public.profiles p on p.id=l.actor_id
  where (l.table_name='members' and l.record_id=p_member_id)
    or (l.table_name in ('plots','activities','material_requests') and coalesce(l.new_data->>'member_id',l.old_data->>'member_id')=p_member_id::text)
    or (l.table_name='seasons' and exists(select 1 from public.plots where id=coalesce(l.new_data->>'plot_id',l.old_data->>'plot_id')::uuid and member_id=p_member_id))
    or (l.table_name='checklist_requirements' and exists(select 1 from public.seasons s join public.plots p on p.id=s.plot_id where s.id=coalesce(l.new_data->>'season_id',l.old_data->>'season_id')::uuid and p.member_id=p_member_id))
  order by l.created_at desc,l.id desc limit 200
 ) x);
end; $$;

-- A source withdrawn in LINE must never expose copied formula text through browser reads.
create function public.material_request_list(p_member_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.is_staff() then raise exception 'Staff required' using errcode='42501';end if;
 return (select coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('source_withdrawn',exists(select 1 from public.line_messages s where s.material_request_id=r.id and s.withdrawn_at is not null),'ingredients',case when exists(select 1 from public.line_messages s where s.material_request_id=r.id and s.withdrawn_at is not null) then 'ผู้ส่งยกเลิกข้อความต้นทาง' else r.ingredients end) order by r.created_at desc),'[]') from public.material_requests r where r.member_id=p_member_id);
end; $$;

create function public.member_summary(p_member_id uuid,p_as_of date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if not private.is_staff() then raise exception 'Staff required' using errcode='42501';end if;
 if p_as_of is null or p_as_of>(now() at time zone 'Asia/Bangkok')::date then raise exception 'Invalid report date';end if;
 select jsonb_build_object(
  'generated_at',now(),'as_of',p_as_of,'member',to_jsonb(m)-'profile_id',
  'plots',(select coalesce(jsonb_agg(p order by p.code),'[]') from public.plots p where p.member_id=m.id),
  'seasons',(select coalesce(jsonb_agg(s order by s.starts_on desc),'[]') from public.seasons s join public.plots p on p.id=s.plot_id where p.member_id=m.id),
  'activities',(select coalesce(jsonb_agg(a order by a.occurred_on desc,a.id),'[]') from public.activities a where a.member_id=m.id and (a.occurred_on<=p_as_of or a.occurred_on is null)),
  'materials',public.material_request_list(m.id),
  'requirements',(select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'title',r.title,'due_on',r.due_on,'rule_version',r.rule_version,'requires_evidence',r.requires_evidence,'revision',r.revision,'season_id',r.season_id,'plot_id',s.plot_id,'activity_id',r.verified_activity_id,'due',r.due_on<=p_as_of,'complete',
   exists(select 1 from public.activities a where a.id=r.verified_activity_id and a.status='verified' and a.season_id=r.season_id and a.plot_id=s.plot_id and a.occurred_on<=p_as_of
    and (not r.requires_evidence or exists(select 1 from public.evidence e where e.activity_id=a.id) or exists(select 1 from public.line_messages lm join public.line_media media on media.source_id=lm.id where lm.activity_id=a.id and lm.withdrawn_at is null and media.status='ready'))
   )) order by r.due_on,r.id),'[]') from public.checklist_requirements r join public.seasons s on s.id=r.season_id join public.plots p on p.id=s.plot_id where p.member_id=m.id and r.active),
  'material_risks',(select coalesce(jsonb_agg(jsonb_build_object('activity_id',a.id,'material_name',r.material_name,'date',a.occurred_on,'reason','ต้องสอบทานการใช้วัสดุ สถานะอนุมัติ เงื่อนไข และช่วงวันที่')),'[]') from public.activities a join public.material_requests r on r.id=a.material_request_id where a.member_id=m.id and a.occurred_on<=p_as_of and (r.status<>'approved' or r.decided_at is null or r.valid_from is null or r.valid_until is null or a.occurred_on<=((r.decided_at at time zone 'Asia/Bangkok')::date) or a.occurred_on<r.valid_from or a.occurred_on>r.valid_until))
 ) into result from public.members m where m.id=p_member_id;
 return result;
end; $$;

create or replace function private.protect_material_decision() returns trigger
language plpgsql set search_path='' as $$
begin
 if tg_op='INSERT' and new.status<>'pending' then raise exception 'New requests must be pending';end if;
 if tg_op='UPDATE' then
  if auth.uid() is null and new.material_name='ข้อมูลจาก LINE ถูกยกเลิก' and new.ingredients='ผู้ส่งยกเลิกข้อความต้นทาง' and new.status='pending' and new.decided_by is null and new.decided_at is null and new.decision_reason is null and new.conditions is null and new.valid_from is null and new.valid_until is null
   and exists(select 1 from public.line_messages where material_request_id=old.id and withdrawn_at is not null)
   and (to_jsonb(new)-array['revision','material_name','ingredients','status','decided_by','decided_at','decision_reason','conditions','valid_from','valid_until'])=(to_jsonb(old)-array['revision','material_name','ingredients','status','decided_by','decided_at','decision_reason','conditions','valid_from','valid_until']) then return new;end if;
  if new.member_id<>old.member_id or new.plot_id<>old.plot_id or new.ingredients<>old.ingredients or new.material_name<>old.material_name or new.created_by<>old.created_by or new.created_at<>old.created_at then raise exception 'Submit a new request when formula or ownership changes';end if;
  if not private.can_manage() then raise exception 'Manager decision required';end if;
  new.decided_by:=auth.uid();new.decided_at:=now();
 end if;return new;
end; $$;

-- Several distinct LINE files may support one activity; one source still belongs to one record.
alter table public.line_messages drop constraint line_messages_activity_id_key;
create function public.attach_line_evidence(p_source_id uuid,p_activity_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare source public.line_messages;target public.activities;
begin
 if not private.is_staff() then raise exception 'Staff required' using errcode='42501';end if;
 select * into source from public.line_messages where id=p_source_id for update;
 if not found or source.withdrawn_at is not null or source.material_request_id is not null or (source.activity_id is not null and source.activity_id<>p_activity_id) then raise exception 'Invalid source';end if;
 select * into target from public.activities where id=p_activity_id for update;
 if not found or target.member_id<>source.member_id or target.status='verified' or not exists(select 1 from public.members where id=target.member_id and active) then raise exception 'Invalid target';end if;
 if not exists(select 1 from public.line_media where source_id=source.id and status='ready') then raise exception 'Media required';end if;
 update public.line_messages set activity_id=p_activity_id where id=p_source_id;
 perform set_config('app.change_reason','เชื่อมหลักฐานจาก LINE',true);
 update public.activities set status='pending',reviewed_by=null,reviewed_at=null,review_note=null where id=p_activity_id;
end; $$;
revoke all on function public.attach_line_evidence(uuid,uuid) from public,anon;
grant execute on function public.attach_line_evidence(uuid,uuid) to authenticated;
-- Restrict RPC entry points explicitly (PostgreSQL otherwise grants PUBLIC execute).
revoke all on function public.edit_member(uuid,integer,text,text,text,boolean,text),public.edit_plot(uuid,integer,text,text,numeric,text),public.save_activity(uuid,integer,uuid,uuid,uuid,date,text,text,uuid,text),public.review_activity(uuid,integer,public.activity_status,text),public.submit_material_request(uuid,uuid,text,text,date,uuid),public.decide_material_request(uuid,integer,public.request_status,text,text,date,date),public.configure_requirement(uuid,integer,uuid,text,date,text,boolean,boolean,text),public.match_requirement(uuid,integer,uuid,text),public.register_evidence(uuid,text,text,text),public.member_history(uuid),public.material_request_list(uuid),public.member_summary(uuid,date) from public,anon;
grant execute on function public.edit_member(uuid,integer,text,text,text,boolean,text),public.edit_plot(uuid,integer,text,text,numeric,text),public.save_activity(uuid,integer,uuid,uuid,uuid,date,text,text,uuid,text),public.review_activity(uuid,integer,public.activity_status,text),public.submit_material_request(uuid,uuid,text,text,date,uuid),public.decide_material_request(uuid,integer,public.request_status,text,text,date,date),public.configure_requirement(uuid,integer,uuid,text,date,text,boolean,boolean,text),public.match_requirement(uuid,integer,uuid,text),public.register_evidence(uuid,text,text,text),public.member_history(uuid),public.material_request_list(uuid),public.member_summary(uuid,date) to authenticated;
commit;
