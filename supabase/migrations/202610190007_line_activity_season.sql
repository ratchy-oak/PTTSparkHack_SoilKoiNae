-- Record the original LINE sources and selected production period atomically.
begin;
create or replace function public.record_line_activity_in_season(p_message_id uuid,p_plot_id uuid,p_occurred_on date,p_activity_type text,p_description text,p_season_id uuid default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare result uuid;activity public.activities;
begin
 if not private.is_staff() then raise exception 'Staff required' using errcode='42501';end if;
 if p_season_id is not null then
  perform 1 from public.seasons where id=p_season_id and plot_id=p_plot_id for share;
  if not found then raise exception 'Activity must match season and plot';end if;
 end if;
 result:=public.record_line_activity(p_message_id,p_plot_id,p_occurred_on,p_activity_type,p_description);
 if p_season_id is not null then
  select * into activity from public.activities where id=result;
  perform public.save_activity(result,activity.revision,activity.member_id,p_plot_id,p_season_id,p_occurred_on,p_activity_type,p_description,activity.material_request_id,'ระบุรอบการผลิตจากข้อมูล LINE');
 end if;
 return result;
end; $$;
revoke all on function public.record_line_activity_in_season(uuid,uuid,date,text,text,uuid) from public,anon;
grant execute on function public.record_line_activity_in_season(uuid,uuid,date,text,text,uuid) to authenticated;
commit;
