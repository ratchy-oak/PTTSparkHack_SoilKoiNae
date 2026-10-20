-- Short LINE flow; retains original files, explicit submit and staff review.
begin;
create or replace function public.ingest_line_event_v5(p_event_id text,p_kind text,p_line_user_id text,p_message_id text,p_text text,p_sent_at timestamptz,p_date text default null) returns jsonb
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
 cmd:=case trim(coalesce(p_text,'')) when 'บอกงานวันนี้' then 'activity' when 'ขอใช้ปุ๋ย / วัสดุ' then 'material' when 'ให้เจ้าหน้าที่ช่วย' then 'help' when 'บอกงานที่ทำ' then 'activity' when 'ขอใช้วัสดุ' then 'material' when 'ดูรายการของฉัน' then 'records' when 'ขอความช่วยเหลือ' then 'help' when 'เมนู' then 'home' when 'เมนูนาคุ้ม' then 'home' when 'ยกเลิก' then 'cancel' when 'กลับ' then 'back' when 'ทำต่อ' then 'resume' else null end;
 if p_kind='postback' then
  parts:=string_to_array(coalesce(p_text,''),'|');
  if parts[1]='nk1' and parts[2]='menu' and parts[3] in ('activity','material','records','help','home') then cmd:=parts[3];
  elsif parts[1]='nk1' and parts[2]='records' and parts[3] ~ '^\d{1,5}$' then cmd:='records';
  elsif parts[1]='nk1' and array_length(parts,1)>=4 then act:=parts[4];value:=parts[5];
  else act:='invalid';end if;
 end if;
 -- Free messages keep the existing intake path. Draft fields are captured as original sources, not synthesized messages.
 is_input:=d.id is not null and cmd is null and p_kind in ('text','image','audio') and (d.step in ('name','formula','description','attachments') or (d.data->>'quick'='true' and d.step='confirm'));
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
  if cmd in ('activity','material') then
   update public.line_drafts set data=jsonb_build_object('quick','true','date',today,'type','อื่น ๆ','name','วัสดุที่สมาชิกแจ้ง') || case when (select count(*) from public.plots where member_id=account.member_id)=1 then jsonb_build_object('plot_id',(select id from public.plots where member_id=account.member_id limit 1)) else '{}'::jsonb end,
    step=case when cmd='activity' then 'description' else 'formula' end where id=d.id;
  end if;
  return result||jsonb_build_object('chat',private.line_draft_screen(d.id));
 end if;
 if d.id is null then return result||jsonb_build_object('chat',jsonb_build_object('view','home','notice','รายการเดิมจบแล้วหรือหมดอายุครับ เลือกเมนูเพื่อเริ่มใหม่ได้เลย'));end if;
 if p_kind='postback' and cmd is null and (parts[2] is distinct from d.id::text or parts[3] is distinct from d.revision::text) then return result||jsonb_build_object('chat',private.line_draft_screen(d.id,null,'ปุ่มนี้เป็นของขั้นตอนเก่าครับ ใช้ปุ่มชุดล่าสุดด้านล่างได้เลย'));end if;
 if notice is not null then return result||jsonb_build_object('chat',private.line_draft_screen(d.id,null,notice));end if;
 if cmd='cancel' or act='cancel' then return result||jsonb_build_object('chat',private.line_draft_screen(d.id,'cancel_confirm'));end if;
 if act='cancel_yes' then update public.line_drafts set status='cancelled',revision=revision+1,last_input_at=p_sent_at,updated_at=now() where id=d.id;return result||jsonb_build_object('chat',jsonb_build_object('view','home','notice','ยกเลิกร่างแล้วครับ ยังไม่ได้ส่งให้เจ้าหน้าที่'));end if;
 if cmd='resume' or act='resume' then return result||jsonb_build_object('chat',private.line_draft_screen(d.id));end if;
 steps:=case when d.data->>'quick'='true' then case when d.kind='activity' then array['description','plot','confirm'] else array['formula','plot','confirm'] end else case d.kind when 'activity' then array['plot','type','date','description','attachments','confirm'] when 'material' then array['plot','name','formula','date','attachments','confirm'] else array['description','confirm'] end end;
 pos:=array_position(steps,d.step);
 if cmd='back' or act='back' then
  if pos>1 then update public.line_drafts set step=steps[pos-1],revision=revision+1,last_input_at=p_sent_at,updated_at=now() where id=d.id;end if;
  return result||jsonb_build_object('chat',private.line_draft_screen(d.id));
 end if;
 if d.data->>'quick'='true' and act='edit_options' then return result||jsonb_build_object('chat',private.line_draft_screen(d.id,'edit'));end if;
 if d.data->>'quick'='true' and act in ('edit_details','edit_plot','edit_date') then
  update public.line_drafts set step=case act when 'edit_details' then case d.kind when 'activity' then 'description' else 'formula' end when 'edit_plot' then 'plot' else 'date' end,revision=revision+1,last_input_at=p_sent_at,updated_at=now() where id=d.id;
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
  d.data:=d.data||jsonb_build_object('date',date_value);d.step:=case when d.data->>'quick'='true' then 'confirm' else steps[pos+1] end;
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
 if d.data->>'quick'='true' and d.step='plot' and d.data->>'plot_id' is not null and is_input then d.step:='confirm';end if;
 update public.line_drafts set step=d.step,data=d.data,revision=revision+1,last_input_at=p_sent_at,updated_at=now(),expires_at=now()+interval '24 hours' where id=d.id;
 return result||jsonb_build_object('chat',private.line_draft_screen(d.id,null,notice));
end; $$;

revoke all on function public.ingest_line_event_v5(text,text,text,text,text,timestamptz,text) from public,anon,authenticated;
grant execute on function public.ingest_line_event_v5(text,text,text,text,text,timestamptz,text) to service_role;
commit;
