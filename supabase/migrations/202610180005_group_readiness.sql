-- Read-only staff dashboard. No sample data, new grants to farmers, or automatic decisions.
begin;
create function public.group_readiness(p_as_of date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if not private.is_staff() then raise exception 'Staff required' using errcode='42501';end if;
 if p_as_of is null or p_as_of>(now() at time zone 'Asia/Bangkok')::date then raise exception 'Invalid report date';end if;
 select jsonb_build_object('as_of',p_as_of,'generated_at',now(),'rows',coalesce(jsonb_agg(x order by x.code,x.id),'[]')) into result from (
 select m.id,m.code,m.display_name,m.village,
 jsonb_array_length(s.data->'plots') plot_count,jsonb_array_length(s.data->'seasons') season_count,
 (select count(*) from jsonb_array_elements(s.data->'requirements') r where (r->>'due')::boolean) due_count,
 (select count(*) from jsonb_array_elements(s.data->'requirements') r where (r->>'due')::boolean and (r->>'complete')::boolean) complete_count,
 (select coalesce(jsonb_agg(jsonb_build_object('id',r->>'id','title',r->>'title','due_on',r->>'due_on','plot_name',p.name,'days_overdue',greatest(0,p_as_of-(r->>'due_on')::date),
 'reason',case when r->>'activity_id' is null then 'ยังไม่ได้เลือกบันทึกประกอบ' when a.id is null then 'ไม่พบบันทึกประกอบที่ใช้งานได้' when a.status<>'verified' then 'บันทึกยังไม่ผ่านการตรวจยืนยัน' when a.plot_id is distinct from (r->>'plot_id')::uuid or a.season_id is distinct from (r->>'season_id')::uuid then 'บันทึกไม่ตรงแปลงหรือรอบการผลิต' else 'ตรวจสอบวันที่และหลักฐานประกอบที่กำหนด' end
 ) order by (r->>'due_on')::date,r->>'id'),'[]') from jsonb_array_elements(s.data->'requirements') r left join public.plots p on p.id=(r->>'plot_id')::uuid left join public.activities a on a.id=(r->>'activity_id')::uuid where (r->>'due')::boolean and not (r->>'complete')::boolean) missing,
 jsonb_array_length(s.data->'requirements') requirement_count,
 s.data->'material_risks' material_risks,
 (select count(*) from jsonb_array_elements(s.data->'activities') a where a->>'status'<>'verified') pending_activities,
 (select count(*) from public.material_requests r where r.member_id=m.id and r.status in ('pending','needs_info') and r.created_at<((p_as_of+1)::timestamp at time zone 'Asia/Bangkok')) pending_materials,
 (select count(*) from public.line_messages l where l.member_id=m.id and l.guided_visible and l.withdrawn_at is null and l.activity_id is null and l.material_request_id is null and l.received_at<((p_as_of+1)::timestamp at time zone 'Asia/Bangkok')) intake_count,
 (select count(*) from public.line_help_requests h where h.member_id=m.id and h.status='open' and h.created_at<((p_as_of+1)::timestamp at time zone 'Asia/Bangkok')) help_count,
 (select max(l.received_at) from public.line_messages l where l.member_id=m.id and l.guided_visible and l.withdrawn_at is null and l.received_at<((p_as_of+1)::timestamp at time zone 'Asia/Bangkok')) last_received_at
 from public.members m cross join lateral (select public.member_summary(m.id,p_as_of) data) s where m.active
 ) x;
 return result;
end; $$;
revoke all on function public.group_readiness(date) from public,anon;
grant execute on function public.group_readiness(date) to authenticated;
commit;
