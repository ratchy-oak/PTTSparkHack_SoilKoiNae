-- Run once AFTER 001, 002 and 003. Adds member-guided LINE drafts; never auto-verifies records.
begin;
create table public.line_drafts(
 id uuid primary key default gen_random_uuid(),member_id uuid not null references public.members(id),line_user_id text not null,
 kind text not null check(kind in ('activity','material','help')),step text not null,
 status text not null default 'editing' check(status in ('editing','submitted','cancelled','expired','withdrawn')),
 data jsonb not null default '{}',last_input_at timestamptz,revision integer not null default 1,
 anchor_id uuid references public.line_messages(id),created_at timestamptz not null default now(),updated_at timestamptz not null default now(),expires_at timestamptz not null default now()+interval '24 hours'
);
create unique index line_one_open_draft on public.line_drafts(line_user_id) where status='editing';
alter table public.line_messages add column guided_draft_id uuid references public.line_drafts(id);
alter table public.line_messages add column guided_visible boolean not null default true;
grant select(guided_draft_id,guided_visible) on public.line_messages to authenticated;
create table public.line_draft_sources(draft_id uuid not null references public.line_drafts(id),source_id uuid not null unique references public.line_messages(id),field_name text not null,removed boolean not null default false,primary key(draft_id,source_id));
create table public.line_help_requests(
 id uuid primary key default gen_random_uuid(),draft_id uuid not null unique references public.line_drafts(id),member_id uuid not null references public.members(id),details text,
 status text not null default 'open' check(status in ('open','closed','withdrawn')),staff_note text,handled_by uuid references public.profiles(id),handled_at timestamptz,created_at timestamptz not null default now()
);
create index line_help_open on public.line_help_requests(created_at desc) where status='open';
alter table public.line_drafts enable row level security;alter table public.line_draft_sources enable row level security;alter table public.line_help_requests enable row level security;
revoke all on public.line_drafts,public.line_draft_sources,public.line_help_requests from public,anon,authenticated;
grant all on public.line_drafts,public.line_draft_sources,public.line_help_requests to service_role;
grant select on public.line_help_requests to authenticated;
create policy line_help_staff_read on public.line_help_requests for select to authenticated using(private.is_staff());
create trigger audit_line_help after insert or update on public.line_help_requests for each row execute function private.audit_change();

create function private.line_draft_screen(p_id uuid,p_view text default null,p_notice text default null) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('view',coalesce(p_view,d.step),'notice',p_notice,'id',d.id,'revision',d.revision,'kind',d.kind,'step',d.step,'status',d.status,
 'data',case when d.status='withdrawn' then '{}'::jsonb else d.data end,
 'plots',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'code',p.code) order by p.code),'[]') from public.plots p where p.member_id=d.member_id),
 'media_count',(select count(*) from public.line_draft_sources s join public.line_media m on m.source_id=s.source_id join public.line_messages l on l.id=s.source_id where s.draft_id=d.id and not s.removed and l.withdrawn_at is null and m.status='ready'),
 'unready_count',(select count(*) from public.line_draft_sources s join public.line_media m on m.source_id=s.source_id where s.draft_id=d.id and not s.removed and m.status in ('failed','pending')))
 from public.line_drafts d where d.id=p_id;
$$;
revoke all on function private.line_draft_screen(uuid,text,text) from public;
create function public.line_chat_state(p_line_user_id text) returns jsonb
language sql stable security definer set search_path='' as $$
 select private.line_draft_screen(id) from public.line_drafts where line_user_id=p_line_user_id and status='editing' order by created_at desc limit 1;
$$;
revoke all on function public.line_chat_state(text) from public,anon,authenticated;
grant execute on function public.line_chat_state(text) to service_role;

create function private.line_member_records(p_member_id uuid,p_page integer) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('view','records','page',p_page,'rows',coalesce(jsonb_agg(x order by x.created_at desc,x.id),'[]')) from (
 select * from (
  select m.id,m.received_at created_at,case when m.withdrawn_at is not null then 'รายการที่ยกเลิก' else coalesce(r.material_name,a.activity_type,case when d.kind='material' then 'คำขอวัสดุ' else 'ข้อมูลที่ส่ง' end) end title,
  case when m.withdrawn_at is not null then 'withdrawn' else coalesce(r.status::text,case when a.status::text='pending' then 'activity_pending' else a.status::text end,'received') end status,
  case when m.withdrawn_at is null then r.conditions end conditions,case when m.withdrawn_at is null then r.decision_reason end reason,
  case when m.withdrawn_at is null then r.valid_from end valid_from,case when m.withdrawn_at is null then r.valid_until end valid_until
  from public.line_messages m left join public.activities a on a.id=m.activity_id left join public.material_requests r on r.id=m.material_request_id left join public.line_drafts d on d.id=m.guided_draft_id
  where m.member_id=p_member_id and m.guided_visible
  union all
  select h.id,h.created_at,'ขอความช่วยเหลือ',h.status,null,h.staff_note,null,null from public.line_help_requests h where h.member_id=p_member_id
 ) q order by created_at desc,id offset (p_page*5) limit 6
 ) x;
$$;
revoke all on function private.line_member_records(uuid,integer) from public;

create function public.ingest_line_event_v4(p_event_id text,p_kind text,p_line_user_id text,p_message_id text,p_text text,p_sent_at timestamptz,p_date text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare account public.line_accounts;d public.line_drafts;source public.line_messages;result jsonb;claimed text;parts text[];act text;value text;cmd text;date_value date;next_step text;steps text[];pos integer;field text;anchor uuid;other_id uuid;is_input boolean:=false;today date:=(now() at time zone 'Asia/Bangkok')::date;notice text;
begin
 if p_kind not in ('postback','text','image','audio','unsend','follow','unfollow','unsupported') or coalesce(p_event_id,'')='' or coalesce(p_line_user_id,'')='' then raise exception 'Invalid event';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_line_user_id,0));
 if p_kind in ('follow','unfollow','unsend') or (p_kind='text' and trim(coalesce(p_text,'')) ~ '^เชื่อม\s') then
  result:=public.ingest_line_event_v3(p_event_id,p_kind,p_line_user_id,p_message_id,p_text,p_sent_at);
  if p_kind='unsend' then
   select ds.draft_id into other_id from public.line_draft_sources ds join public.line_messages m on m.id=ds.source_id where m.message_id=p_message_id and m.line_user_id=p_line_user_id;
   if other_id is not null then
    update public.line_drafts set status='withdrawn',data='{}',revision=revision+1,updated_at=now() where id=other_id and status in ('editing','submitted');
    update public.line_messages set withdrawn_at=coalesce(withdrawn_at,now()) where id=(select anchor_id from public.line_drafts where id=other_id);
    update public.line_help_requests set details=null,status='withdrawn' where draft_id=other_id;
    update public.audit_log set old_data=old_data-'details',new_data=new_data-'details' where table_name='line_help_requests' and record_id in(select id from public.line_help_requests where draft_id=other_id);
   end if;
  end if;
  return result;
 end if;
 select * into account from public.line_accounts where line_user_id=p_line_user_id and active;
 select * into d from public.line_drafts where line_user_id=p_line_user_id and status='editing' for update;
 if d.id is not null and (d.expires_at<=now() or d.member_id is distinct from account.member_id) then update public.line_drafts set status='expired',revision=revision+1 where id=d.id;d:=null;end if;
 cmd:=case trim(coalesce(p_text,'')) when 'บอกงานที่ทำ' then 'activity' when 'ขอใช้วัสดุ' then 'material' when 'ดูรายการของฉัน' then 'records' when 'ขอความช่วยเหลือ' then 'help' when 'เมนู' then 'home' when 'เมนูนาคุ้ม' then 'home' when 'ยกเลิก' then 'cancel' when 'กลับ' then 'back' when 'ทำต่อ' then 'resume' else null end;
 if p_kind='postback' then
  parts:=string_to_array(coalesce(p_text,''),'|');
  if parts[1]='nk1' and parts[2]='menu' and parts[3] in ('activity','material','records','help','home') then cmd:=parts[3];
  elsif parts[1]='nk1' and parts[2]='records' and parts[3] ~ '^\d{1,5}$' then cmd:='records';
  elsif parts[1]='nk1' and array_length(parts,1)>=4 then act:=parts[4];value:=parts[5];
  else act:='invalid';end if;
 end if;
 -- Free messages keep the existing intake path. Draft fields are captured as original sources, not synthesized messages.
 is_input:=d.id is not null and cmd is null and p_kind in ('text','image','audio') and (d.step in ('name','formula','description','attachments'));
 if cmd is null and p_kind<>'postback' and not is_input then return public.ingest_line_event_v3(p_event_id,p_kind,p_line_user_id,p_message_id,p_text,p_sent_at);end if;
 if d.last_input_at is not null and p_sent_at<d.last_input_at and (is_input or act is not null or cmd in ('cancel','back','resume')) then is_input:=false;notice:='ข้อมูลมาถึงสลับลำดับครับ กรุณาใช้ปุ่มล่าสุดหรือส่งรายละเอียดอีกครั้ง';end if;
 if is_input and p_kind in ('image','audio') and (select count(*) from public.line_draft_sources s join public.line_media m on m.source_id=s.source_id where s.draft_id=d.id and not s.removed)>=10 then is_input:=false;notice:='แนบได้ไม่เกิน 10 ไฟล์ต่อรายการครับ';end if;
 if is_input then
  result:=public.ingest_line_event_v3(p_event_id,p_kind,p_line_user_id,p_message_id,p_text,p_sent_at);
  if coalesce((result->>'duplicate')::boolean,false) then return result;end if;
 else
  insert into public.webhook_events(event_id,event_type,payload,processed_at,last_error) values(p_event_id,p_kind,'{}',now(),'line_reply_unconfirmed') on conflict do nothing returning event_id into claimed;
  if claimed is null then return jsonb_build_object('duplicate',true);end if;
  result:=jsonb_build_object('duplicate',false);
 end if;
 if account.member_id is null then return result||jsonb_build_object('reply','กรุณาขอข้อความเชื่อมบัญชีจากเจ้าหน้าที่ก่อนครับ แล้วส่งข้อความนั้นในแชตนี้');end if;
 if not exists(select 1 from public.members where id=account.member_id and active) then return result||jsonb_build_object('reply','สมาชิกนี้พักใช้งานอยู่ กรุณาติดต่อเจ้าหน้าที่ครับ');end if;
 if cmd='home' then return result||jsonb_build_object('chat',jsonb_build_object('view','home','has_draft',d.id is not null));end if;
 if cmd='records' then
  pos:=0;if p_kind='postback' and parts[2]='records' then pos:=parts[3]::integer;end if;
  return result||jsonb_build_object('chat',private.line_member_records(account.member_id,pos));
 end if;
 if cmd='help' and d.id is not null then
  insert into public.line_help_requests(draft_id,member_id,details) values(d.id,d.member_id,'สมาชิกขอให้ช่วยทำรายการที่ค้างอยู่') on conflict(draft_id) do update set status='open',staff_note=null,handled_by=null,handled_at=null;
  return result||jsonb_build_object('chat',jsonb_build_object('view','home','has_draft',true,'notice','ส่งเรื่องให้เจ้าหน้าที่ช่วยแล้วครับ รายการเดิมยังอยู่ กดทำต่อเมื่อพร้อมได้เลย'));
 end if;
 if cmd in ('activity','material','help') then
  if d.id is not null then return result||jsonb_build_object('chat',private.line_draft_screen(d.id,'resume'));end if;
  insert into public.line_drafts(member_id,line_user_id,kind,step,last_input_at) values(account.member_id,p_line_user_id,cmd,case when cmd='help' then 'description' else 'plot' end,p_sent_at) returning * into d;
  return result||jsonb_build_object('chat',private.line_draft_screen(d.id));
 end if;
 if d.id is null then return result||jsonb_build_object('chat',jsonb_build_object('view','home','notice','รายการเดิมจบแล้วหรือหมดอายุครับ เลือกเมนูเพื่อเริ่มใหม่ได้เลย'));end if;
 if p_kind='postback' and cmd is null and (parts[2] is distinct from d.id::text or parts[3] is distinct from d.revision::text) then return result||jsonb_build_object('chat',private.line_draft_screen(d.id,null,'ปุ่มนี้เป็นของขั้นตอนเก่าครับ ใช้ปุ่มชุดล่าสุดด้านล่างได้เลย'));end if;
 if notice is not null then return result||jsonb_build_object('chat',private.line_draft_screen(d.id,null,notice));end if;
 if cmd='cancel' or act='cancel' then return result||jsonb_build_object('chat',private.line_draft_screen(d.id,'cancel_confirm'));end if;
 if act='cancel_yes' then update public.line_drafts set status='cancelled',revision=revision+1,last_input_at=p_sent_at,updated_at=now() where id=d.id;return result||jsonb_build_object('chat',jsonb_build_object('view','home','notice','ยกเลิกร่างแล้วครับ ยังไม่ได้ส่งให้เจ้าหน้าที่'));end if;
 if cmd='resume' or act='resume' then return result||jsonb_build_object('chat',private.line_draft_screen(d.id));end if;
 steps:=case d.kind when 'activity' then array['plot','type','date','description','attachments','confirm'] when 'material' then array['plot','name','formula','date','attachments','confirm'] else array['description','confirm'] end;
 pos:=array_position(steps,d.step);
 if cmd='back' or act='back' then
  if pos>1 then update public.line_drafts set step=steps[pos-1],revision=revision+1,last_input_at=p_sent_at,updated_at=now() where id=d.id;end if;
  return result||jsonb_build_object('chat',private.line_draft_screen(d.id));
 end if;
 if act='plot_page' and d.step='plot' and value ~ '^\d{1,4}$' then return result||jsonb_build_object('chat',private.line_draft_screen(d.id)||jsonb_build_object('plot_page',value::integer));end if;
 if act='drop_failed' then
  update public.line_draft_sources set removed=true where draft_id=d.id and source_id in (select source_id from public.line_media where status in ('failed','pending'));
  if d.data->>'description_kind'='audio' and not exists(select 1 from public.line_draft_sources where draft_id=d.id and source_id::text=d.data->>'description_source' and not removed) then d.data:=d.data-array['description','description_kind','description_source'];d.step:='description';end if;
  if d.data->>'formula_kind'='audio' and not exists(select 1 from public.line_draft_sources where draft_id=d.id and source_id::text=d.data->>'formula_source' and not removed) then d.data:=d.data-array['formula','formula_kind','formula_source'];d.step:='formula';end if;
  update public.line_drafts set data=d.data,step=d.step,revision=revision+1,last_input_at=p_sent_at,updated_at=now() where id=d.id;
  return result||jsonb_build_object('chat',private.line_draft_screen(d.id));
 end if;
 if is_input then
  select * into source from public.line_messages where message_id=p_message_id and line_user_id=p_line_user_id;
  if source.id is null or source.withdrawn_at is not null then return result||jsonb_build_object('reply','รับข้อมูลนี้ไม่ได้ครับ กรุณาส่งใหม่');end if;
  update public.line_messages set guided_draft_id=d.id,guided_visible=false where id=source.id;
  field:=case when d.step='attachments' or p_kind='image' then 'attachment' else d.step end;
  insert into public.line_draft_sources(draft_id,source_id,field_name) values(d.id,source.id,field);
  if d.step in ('name','formula','description') then
   if p_kind='text' and coalesce(trim(p_text),'')<>'' and (d.step<>'name' or length(trim(p_text))<=160) then
    d.data:=d.data||jsonb_build_object(d.step,trim(p_text),d.step||'_kind','text',d.step||'_source',source.id);d.step:=steps[pos+1];
   elsif p_kind='audio' and d.step in ('formula','description') then
    d.data:=d.data||jsonb_build_object(d.step,'รายละเอียดอยู่ในเสียงแนบ เจ้าหน้าที่ต้องฟังก่อนตรวจ',d.step||'_kind','audio',d.step||'_source',source.id);d.step:=steps[pos+1];
   else notice:=case when d.step='name' then 'พิมพ์ชื่อวัสดุสั้น ๆ ไม่เกิน 160 ตัวอักษรครับ' else 'แนบรูปไว้แล้วครับ ขั้นนี้กรุณาพิมพ์หรือพูดรายละเอียดเพิ่ม' end;end if;
  else notice:='รับข้อมูลเพิ่มแล้วครับ กดดูสรุปเมื่อแนบครบ';end if;
 elsif d.step='plot' and act='plot' then
  if not exists(select 1 from public.plots where id::text=value and member_id=account.member_id) then return result||jsonb_build_object('chat',private.line_draft_screen(d.id,null,'เลือกแปลงของคุณจากปุ่มด้านล่างครับ'));end if;
  d.data:=d.data||jsonb_build_object('plot_id',value);d.step:=steps[pos+1];
 elsif d.step='type' and act='type' and value in ('เตรียมแปลง','ปลูก','ดูแลแปลง','เก็บเกี่ยว','อื่น ๆ') then d.data:=d.data||jsonb_build_object('type',value);d.step:=steps[pos+1];
 elsif d.step='date' and act='date' then
  begin date_value:=case value when 'today' then today when 'yesterday' then today-1 when 'pick' then p_date::date else null end;exception when others then date_value:=null;end;
  if date_value is null or (d.kind='activity' and date_value>today) then return result||jsonb_build_object('chat',private.line_draft_screen(d.id,null,'เลือกวันที่จริง โดยวันทำกิจกรรมต้องไม่เกินวันนี้ครับ'));end if;
  d.data:=d.data||jsonb_build_object('date',date_value);d.step:=steps[pos+1];
 elsif act='reuse' and d.step in ('name','formula','description') and coalesce(d.data->>d.step,'')<>'' then d.step:=steps[pos+1];
 elsif d.step='attachments' and act='next' then d.step:='confirm';
 elsif d.step='confirm' and act='submit' then
  if exists(select 1 from public.line_draft_sources s join public.line_messages m on m.id=s.source_id where s.draft_id=d.id and not s.removed and m.withdrawn_at is not null) then return result||jsonb_build_object('reply','ข้อมูลต้นทางถูกยกเลิกแล้วครับ กรุณาเริ่มรายการใหม่');end if;
  if exists(select 1 from public.line_draft_sources s join public.line_media m on m.source_id=s.source_id where s.draft_id=d.id and not s.removed and m.status<>'ready') then return result||jsonb_build_object('chat',private.line_draft_screen(d.id,null,'มีไฟล์ที่ยังรับไม่สำเร็จครับ ลองส่งใหม่ หรือกดข้ามไฟล์ที่รับไม่ได้'));end if;
  if d.kind<>'help' and (not exists(select 1 from public.plots where id::text=d.data->>'plot_id' and member_id=account.member_id) or d.data->>'date' is null) then raise exception 'Incomplete draft';end if;
  if (d.kind='activity' and (d.data->>'type' is null or d.data->>'description' is null)) or (d.kind='material' and (d.data->>'name' is null or d.data->>'formula' is null)) or (d.kind='help' and d.data->>'description' is null) then raise exception 'Incomplete draft';end if;
  select s.source_id into anchor from public.line_draft_sources s join public.line_messages m on m.id=s.source_id where s.draft_id=d.id and not s.removed and m.withdrawn_at is null order by case when s.field_name in ('description','formula') then 0 else 1 end,m.received_at,m.id limit 1;
  if anchor is null then raise exception 'Source required';end if;
  update public.line_drafts set status='submitted',anchor_id=anchor,revision=revision+1,last_input_at=p_sent_at,updated_at=now() where id=d.id;
  if d.kind='help' then insert into public.line_help_requests(draft_id,member_id,details) values(d.id,d.member_id,d.data->>'description') on conflict(draft_id) do update set details=excluded.details,status='open',staff_note=null,handled_by=null,handled_at=null;else update public.line_messages set guided_visible=true where id=anchor;end if;
  return result||jsonb_build_object('chat',private.line_draft_screen(d.id,'submitted'));
 else return result||jsonb_build_object('chat',private.line_draft_screen(d.id,null,'กรุณาใช้ปุ่มของขั้นตอนนี้ หรือพิมพ์ “ทำต่อ” ครับ'));end if;
 update public.line_drafts set step=d.step,data=d.data,revision=revision+1,last_input_at=p_sent_at,updated_at=now(),expires_at=now()+interval '24 hours' where id=d.id;
 return result||jsonb_build_object('chat',private.line_draft_screen(d.id,null,notice));
end; $$;
revoke all on function public.ingest_line_event_v4(text,text,text,text,text,timestamptz,text) from public,anon,authenticated;
grant execute on function public.ingest_line_event_v4(text,text,text,text,text,timestamptz,text) to service_role;

-- Staff can read a submitted draft, but never another member's raw LINE identity.
create function public.line_draft_for_source(p_source_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare draft public.line_drafts;
begin
 if not private.is_staff() then raise exception 'Staff required' using errcode='42501';end if;
 select d.* into draft from public.line_drafts d join public.line_messages m on m.guided_draft_id=d.id where m.id=p_source_id and d.status in ('submitted','withdrawn');
 if not found then return null;end if;
 return jsonb_build_object('id',draft.id,'kind',draft.kind,'status',draft.status,'data',case when draft.status='withdrawn' then '{}'::jsonb else draft.data end,'sources',(select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'type',m.message_type,'withdrawn',m.withdrawn_at is not null,'text',case when m.withdrawn_at is null and m.message_type='text' then m.body_text else null end)),'[]') from public.line_draft_sources s join public.line_messages m on m.id=s.source_id where s.draft_id=draft.id and not s.removed));
end; $$;
revoke all on function public.line_draft_for_source(uuid) from public,anon;
grant execute on function public.line_draft_for_source(uuid) to authenticated;

-- Keep staff review as the only conversion into a formal record, preserving all source files.
alter function public.record_line_activity(uuid,uuid,date,text,text) set schema private;
alter function private.record_line_activity(uuid,uuid,date,text,text) rename to record_line_activity_base;
revoke all on function private.record_line_activity_base(uuid,uuid,date,text,text) from public,anon,authenticated;
create function public.record_line_activity(p_message_id uuid,p_plot_id uuid,p_occurred_on date,p_activity_type text,p_description text) returns uuid language plpgsql security definer set search_path='' as $$
declare draft public.line_drafts;result uuid;
begin
 if not private.is_staff() then raise exception 'Staff required' using errcode='42501';end if;
 select d.* into draft from public.line_drafts d join public.line_messages m on m.guided_draft_id=d.id where m.id=p_message_id;
 if found then
  if draft.kind<>'activity' or draft.status<>'submitted' then raise exception 'Invalid guided draft';end if;
  perform 1 from public.line_messages where id in(select source_id from public.line_draft_sources where draft_id=draft.id and not removed) order by id for update;
  if exists(select 1 from public.line_messages m join public.line_draft_sources s on s.source_id=m.id where s.draft_id=draft.id and not s.removed and (m.withdrawn_at is not null or m.material_request_id is not null)) then raise exception 'Source withdrawn or already used';end if;
 end if;
 result:=private.record_line_activity_base(p_message_id,p_plot_id,p_occurred_on,p_activity_type,p_description);
 if draft.id is not null then update public.line_messages set activity_id=result where id in(select source_id from public.line_draft_sources where draft_id=draft.id and not removed);end if;
 return result;
end; $$;
revoke all on function public.record_line_activity(uuid,uuid,date,text,text) from public,anon;
grant execute on function public.record_line_activity(uuid,uuid,date,text,text) to authenticated;

alter table public.line_messages drop constraint line_messages_material_request_id_key;
alter function public.submit_material_request(uuid,uuid,text,text,date,uuid) set schema private;
alter function private.submit_material_request(uuid,uuid,text,text,date,uuid) rename to submit_material_request_base;
revoke all on function private.submit_material_request_base(uuid,uuid,text,text,date,uuid) from public,anon,authenticated;
create function public.submit_material_request(p_member_id uuid,p_plot_id uuid,p_name text,p_ingredients text,p_intended_on date,p_source_id uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare draft public.line_drafts;result uuid;
begin
 if not private.is_staff() then raise exception 'Staff required' using errcode='42501';end if;
 select d.* into draft from public.line_drafts d join public.line_messages m on m.guided_draft_id=d.id where m.id=p_source_id;
 if found then
  if draft.kind<>'material' or draft.status<>'submitted' or draft.member_id<>p_member_id then raise exception 'Invalid guided draft';end if;
  perform 1 from public.line_messages where id in(select source_id from public.line_draft_sources where draft_id=draft.id and not removed) order by id for update;
  if exists(select 1 from public.line_messages m join public.line_draft_sources s on s.source_id=m.id where s.draft_id=draft.id and not s.removed and (m.withdrawn_at is not null or m.activity_id is not null)) then raise exception 'Source withdrawn or already used';end if;
 end if;
 result:=private.submit_material_request_base(p_member_id,p_plot_id,p_name,p_ingredients,p_intended_on,p_source_id);
 if draft.id is not null then update public.line_messages set material_request_id=result where id in(select source_id from public.line_draft_sources where draft_id=draft.id and not removed);end if;
 return result;
end; $$;
revoke all on function public.submit_material_request(uuid,uuid,text,text,date,uuid) from public,anon;
grant execute on function public.submit_material_request(uuid,uuid,text,text,date,uuid) to authenticated;

create function public.close_line_help(p_id uuid,p_note text) returns void language plpgsql security definer set search_path='' as $$
begin
 if not private.is_staff() then raise exception 'Staff required' using errcode='42501';end if;
 if coalesce(trim(p_note),'')='' then raise exception 'Staff note required';end if;
 perform set_config('app.change_reason',trim(p_note),true);
 update public.line_help_requests set status='closed',staff_note=trim(p_note),handled_by=auth.uid(),handled_at=now() where id=p_id and status='open';
 if not found then raise exception 'Request changed; reload';end if;
end; $$;
revoke all on function public.close_line_help(uuid,text) from public,anon;
grant execute on function public.close_line_help(uuid,text) to authenticated;
create function public.line_help_detail(p_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if not private.is_staff() then raise exception 'Staff required' using errcode='42501';end if;
 select jsonb_build_object('kind',d.kind,'data',case when d.status='withdrawn' then '{}'::jsonb else d.data end,'sources',(select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'type',m.message_type,'text',case when m.withdrawn_at is null then m.body_text end,'withdrawn',m.withdrawn_at is not null)),'[]') from public.line_draft_sources s join public.line_messages m on m.id=s.source_id where s.draft_id=d.id and not s.removed)) into result
 from public.line_help_requests h join public.line_drafts d on d.id=h.draft_id where h.id=p_id;
 return result;
end; $$;
revoke all on function public.line_help_detail(uuid) from public,anon;
grant execute on function public.line_help_detail(uuid) to authenticated;

commit;
