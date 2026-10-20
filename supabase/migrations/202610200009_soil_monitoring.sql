-- Soilข่อยแน: independent sensor domain. Does not modify or delete existing ICS data.
-- Apply only after owner reviews this migration. Thresholds in UI are demonstration values.
begin;
create table public.soil_devices(
 id text primary key check(id ~ '^SQ-[A-Z0-9-]{1,40}$'),
 name text not null check(length(name) between 1 and 100),
 plot text not null check(length(plot) between 1 and 200),
 village text not null default '',
 lat double precision not null check(lat between -90 and 90),
 lng double precision not null check(lng between -180 and 180),
 area numeric not null default 0 check(area>=0),
 installed_at date not null default current_date,
 active boolean not null default true
);
create table public.soil_readings(
 device_id text not null references public.soil_devices(id),
 at timestamptz not null,
 ph double precision check(ph between 0 and 14),
 ec double precision check(ec between 0 and 30),
 moisture double precision check(moisture between 0 and 100),
 temperature double precision check(temperature between -20 and 80),
 battery double precision check(battery between 0 and 100),
 signal double precision check(signal between -150 and 0),
 fault text check(fault is null or length(fault) between 1 and 120),
 received_at timestamptz not null default now(),
 primary key(device_id,at)
);
create index soil_readings_latest on public.soil_readings(device_id,at desc);
alter table public.soil_devices enable row level security;
alter table public.soil_readings enable row level security;
revoke all on public.soil_devices,public.soil_readings from anon,authenticated;
grant select on public.soil_devices,public.soil_readings to authenticated;
grant all on public.soil_devices,public.soil_readings to service_role;
create policy soil_devices_staff_read on public.soil_devices for select to authenticated using(exists(select 1 from public.profiles where id=auth.uid() and active and role in ('admin','manager','extension','inspector')));
create policy soil_readings_staff_read on public.soil_readings for select to authenticated using(exists(select 1 from public.profiles where id=auth.uid() and active and role in ('admin','manager','extension','inspector')));
create function public.soil_ingest(p jsonb) returns boolean language plpgsql security invoker set search_path=public as $$
declare inserted_count integer;
begin
 if not exists(select 1 from public.soil_devices where id=p->>'device_id' and active) then raise exception 'Unknown or inactive device' using errcode='P0002';end if;
 if (p->>'at')::timestamptz>now()+interval '5 minutes' or (p->>'at')::timestamptz<now()-interval '7 days' then raise exception 'Invalid observation time';end if;
 insert into public.soil_readings(device_id,at,ph,ec,moisture,temperature,battery,signal,fault)
 values(p->>'device_id',(p->>'at')::timestamptz,(p->>'ph')::double precision,(p->>'ec')::double precision,(p->>'moisture')::double precision,(p->>'temperature')::double precision,(p->>'battery')::double precision,(p->>'signal')::double precision,p->>'fault') on conflict(device_id,at) do nothing;
 get diagnostics inserted_count=row_count;
 return inserted_count=1;
end;$$;
create function public.soil_dashboard() returns jsonb language sql security invoker set search_path=public as $$
 select coalesce(jsonb_agg(to_jsonb(d)||jsonb_build_object('history',coalesce(h.rows,'[]'::jsonb),'reading',h.latest)),'[]'::jsonb)
 from public.soil_devices d left join lateral(
 select jsonb_agg(to_jsonb(r) order by r.at) as rows,(jsonb_agg(to_jsonb(r) order by r.at desc))->0 as latest
 from(select * from public.soil_readings where device_id=d.id order by at desc limit 300) r
 ) h on true where d.active;
$$;
revoke all on function public.soil_ingest(jsonb),public.soil_dashboard() from public,anon,authenticated;
grant execute on function public.soil_ingest(jsonb) to service_role;
grant execute on function public.soil_dashboard() to authenticated;
commit;
