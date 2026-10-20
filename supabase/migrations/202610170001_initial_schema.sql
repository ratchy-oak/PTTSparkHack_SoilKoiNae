-- NaKoom v0.1: single-community pilot. Run once in Supabase SQL Editor.
-- No real farmer data or user accounts are inserted by this migration.
begin;
create extension if not exists pgcrypto;
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create type public.app_role as enum ('farmer','extension','inspector','manager','admin');
create type public.activity_status as enum ('draft','pending','needs_info','verified');
create type public.request_status as enum ('pending','needs_info','approved','rejected');

create table public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 display_name text not null check (length(trim(display_name)) > 0),
 role public.app_role not null default 'farmer',
 active boolean not null default true,
 created_at timestamptz not null default now()
);
-- No client policy allows creation or role changes. Provision with trusted admin SQL only.
create function private.current_app_role() returns public.app_role
language sql stable security definer set search_path = ''
as $$ select role from public.profiles where id = auth.uid() and active; $$;
create function private.is_staff() returns boolean
language sql stable security definer set search_path = ''
as $$ select coalesce(private.current_app_role() in ('extension','inspector','manager','admin'),false); $$;
create function private.can_manage() returns boolean
language sql stable security definer set search_path = ''
as $$ select coalesce(private.current_app_role() in ('manager','admin'),false); $$;
grant usage on schema private to authenticated;
revoke all on function private.current_app_role(),private.is_staff(),private.can_manage() from public;
grant execute on function private.current_app_role(),private.is_staff(),private.can_manage() to authenticated;

create table public.members (
 id uuid primary key default gen_random_uuid(),
 code text not null unique,
 display_name text not null,
 village text,
 profile_id uuid unique references public.profiles(id),
 active boolean not null default true,
 created_at timestamptz not null default now()
);
create function private.owns_member(target uuid) returns boolean
language sql stable security definer set search_path = ''
as $$ select exists(select 1 from public.members m join public.profiles p on p.id=m.profile_id where m.id=target and p.id=auth.uid() and p.active and m.active); $$;
revoke all on function private.owns_member(uuid) from public;
grant execute on function private.owns_member(uuid) to authenticated;

create table public.plots (
 id uuid primary key default gen_random_uuid(), member_id uuid not null references public.members(id),
 code text not null unique, name text not null, area_rai numeric(10,2) check(area_rai>0),
 created_at timestamptz not null default now(), unique(id,member_id)
);
create table public.seasons (
 id uuid primary key default gen_random_uuid(), plot_id uuid not null references public.plots(id),
 crop text not null, starts_on date not null, ends_on date,
 check(ends_on is null or ends_on>=starts_on), unique(id,plot_id)
);
create table public.activities (
 id uuid primary key default gen_random_uuid(), member_id uuid not null references public.members(id),
 plot_id uuid not null, season_id uuid,
 activity_type text not null, occurred_on date,
 description text not null, status public.activity_status not null default 'draft',
 submitted_by uuid not null default auth.uid() references public.profiles(id),
 received_at timestamptz not null default now(),
 reviewed_by uuid references public.profiles(id), reviewed_at timestamptz, review_note text,
 revision integer not null default 1 check(revision>0), updated_at timestamptz not null default now(),
 foreign key(plot_id,member_id) references public.plots(id,member_id),
 foreign key(season_id,plot_id) references public.seasons(id,plot_id),
 check(status<>'verified' or (occurred_on is not null and reviewed_by is not null and reviewed_at is not null and review_note is not null and length(trim(review_note))>0))
);
create table public.evidence (
 id uuid primary key default gen_random_uuid(), activity_id uuid not null references public.activities(id),
 storage_path text not null unique check(split_part(storage_path,'/',1)=activity_id::text), media_type text not null check(media_type in ('image','audio','document')),
 original_filename text, uploaded_by uuid not null default auth.uid() references public.profiles(id),
 created_at timestamptz not null default now()
);
create table public.material_requests (
 id uuid primary key default gen_random_uuid(), member_id uuid not null references public.members(id),
 plot_id uuid not null, material_name text not null, ingredients text not null,
 intended_on date, status public.request_status not null default 'pending',
 created_by uuid not null default auth.uid() references public.profiles(id), created_at timestamptz not null default now(),
 decided_by uuid references public.profiles(id), decided_at timestamptz, decision_reason text,
 valid_from date, valid_until date,
 foreign key(plot_id,member_id) references public.plots(id,member_id),
 check(valid_until is null or valid_from is null or valid_until>=valid_from),
 check(status='pending' or (decided_by is not null and decided_at is not null and decision_reason is not null and length(trim(decision_reason))>0))
);
create table public.inspections (
 id uuid primary key default gen_random_uuid(), member_id uuid not null references public.members(id),
 scheduled_on date not null, inspector_id uuid references public.profiles(id),
 findings text, follow_up text, acknowledged_by uuid references public.profiles(id), acknowledged_at timestamptz,
 created_at timestamptz not null default now(),
 check ((acknowledged_by is null) = (acknowledged_at is null))
);
create table public.checklist_requirements (
 id uuid primary key default gen_random_uuid(), season_id uuid not null references public.seasons(id),
 title text not null, due_on date not null, rule_version text not null,
 verified_activity_id uuid references public.activities(id), created_at timestamptz not null default now()
);
-- A future server calculation must check verified status and member/season match; no client-written percentage.
create table public.lots (
 id uuid primary key default gen_random_uuid(), code text not null unique,
 certification_status text not null default 'unconfirmed' check(certification_status in ('unconfirmed','T1','T2','certified')),
 status_evidence_note text, created_at timestamptz not null default now()
);
create table public.lot_plots (
 lot_id uuid not null references public.lots(id), plot_id uuid not null references public.plots(id),
 primary key(lot_id,plot_id)
);
create table public.audit_log (
 id bigint generated always as identity primary key, actor_id uuid, table_name text not null,
 record_id uuid, operation text not null, old_data jsonb, new_data jsonb, created_at timestamptz not null default now()
);
-- Only backend service credentials can access LINE ingestion. Never grant client policies here.
create table public.webhook_events (
 event_id text primary key, received_at timestamptz not null default now(),
 event_type text not null, payload jsonb not null, processed_at timestamptz, last_error text
);

create function private.audit_change() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 insert into public.audit_log(actor_id,table_name,record_id,operation,old_data,new_data)
 values(auth.uid(),tg_table_name,case when tg_op='DELETE' then old.id else new.id end,tg_op,
 case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) else null end,
 case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) else null end);
 return coalesce(new,old);
end; $$;
revoke all on function private.audit_change() from public;

create function private.protect_activity_review() returns trigger
language plpgsql set search_path = '' as $$
begin
 if tg_op='UPDATE' then
   if new.member_id<>old.member_id or new.plot_id<>old.plot_id or new.submitted_by<>old.submitted_by or new.received_at<>old.received_at then
     raise exception 'Ownership and provenance cannot be changed';
   end if;
   new.revision := old.revision+1;
   -- Editing facts on verified records invalidates the earlier review.
   if old.status='verified' and (new.description is distinct from old.description or new.occurred_on is distinct from old.occurred_on or new.activity_type is distinct from old.activity_type or new.season_id is distinct from old.season_id) then
     new.status:='pending'; new.reviewed_by:=null; new.reviewed_at:=null; new.review_note:=null;
   end if;
 end if;
 if new.status='verified' and (tg_op='INSERT' or old.status is distinct from new.status) then
   if not private.is_staff() then raise exception 'Staff review required'; end if;
   new.reviewed_by:=auth.uid(); new.reviewed_at:=now();
 end if;
 new.updated_at:=now();
 return new;
end; $$;
create trigger protect_activity_review before insert or update on public.activities for each row execute function private.protect_activity_review();

create function private.protect_material_decision() returns trigger
language plpgsql set search_path = '' as $$
begin
 if tg_op='INSERT' and new.status<>'pending' then raise exception 'New requests must be pending'; end if;
 if tg_op='UPDATE' then
   if new.member_id<>old.member_id or new.plot_id<>old.plot_id or new.ingredients<>old.ingredients or new.material_name<>old.material_name or new.created_by<>old.created_by or new.created_at<>old.created_at then
     raise exception 'Submit a new request when the formula or ownership changes';
   end if;
   if not private.can_manage() then raise exception 'Manager decision required'; end if;
   new.decided_by:=auth.uid(); new.decided_at:=now();
 end if;
 return new;
end; $$;
create trigger protect_material_decision before insert or update on public.material_requests for each row execute function private.protect_material_decision();

alter table public.profiles enable row level security;
alter table public.members enable row level security;
alter table public.plots enable row level security;
alter table public.seasons enable row level security;
alter table public.activities enable row level security;
alter table public.evidence enable row level security;
alter table public.material_requests enable row level security;
alter table public.inspections enable row level security;
alter table public.checklist_requirements enable row level security;
alter table public.lots enable row level security;
alter table public.lot_plots enable row level security;
alter table public.audit_log enable row level security;
alter table public.webhook_events enable row level security;

-- Explicit grants: no anonymous access, no client hard deletes.
revoke all on public.profiles,public.members,public.plots,public.seasons,public.activities,public.evidence,public.material_requests,public.inspections,public.checklist_requirements,public.lots,public.lot_plots,public.audit_log,public.webhook_events from anon,authenticated;
grant select on public.profiles,public.members,public.plots,public.seasons,public.activities,public.evidence,public.material_requests,public.inspections,public.checklist_requirements,public.lots,public.lot_plots,public.audit_log to authenticated;
grant insert,update on public.members,public.plots,public.seasons,public.activities,public.material_requests,public.inspections,public.checklist_requirements,public.lots,public.lot_plots to authenticated;
grant insert on public.evidence to authenticated;

create policy profiles_read on public.profiles for select to authenticated using(id=auth.uid() or private.can_manage());
create policy members_read on public.members for select to authenticated using(private.is_staff() or private.owns_member(id));
create policy members_insert on public.members for insert to authenticated with check(private.can_manage());
create policy members_update on public.members for update to authenticated using(private.can_manage()) with check(private.can_manage());
create policy plots_read on public.plots for select to authenticated using(private.is_staff() or private.owns_member(member_id));
create policy plots_insert on public.plots for insert to authenticated with check(private.is_staff());
create policy plots_update on public.plots for update to authenticated using(private.is_staff()) with check(private.is_staff());
create policy seasons_read on public.seasons for select to authenticated using(exists(select 1 from public.plots p where p.id=plot_id));
create policy seasons_insert on public.seasons for insert to authenticated with check(private.is_staff());
create policy seasons_update on public.seasons for update to authenticated using(private.is_staff()) with check(private.is_staff());
create policy activities_read on public.activities for select to authenticated using(private.is_staff() or private.owns_member(member_id));
create policy activities_insert on public.activities for insert to authenticated with check((private.is_staff() or private.owns_member(member_id)) and submitted_by=auth.uid() and status in ('draft','pending') and reviewed_by is null and reviewed_at is null);
create policy activities_update on public.activities for update to authenticated using(private.is_staff() or (private.owns_member(member_id) and status in ('draft','needs_info'))) with check(private.is_staff() or (private.owns_member(member_id) and status in ('draft','pending') and reviewed_by is null and reviewed_at is null));
create policy evidence_read on public.evidence for select to authenticated using(exists(select 1 from public.activities a where a.id=activity_id));
create policy evidence_insert on public.evidence for insert to authenticated with check(uploaded_by=auth.uid() and exists(select 1 from public.activities a where a.id=activity_id and a.status<>'verified'));
create policy requests_read on public.material_requests for select to authenticated using(private.is_staff() or private.owns_member(member_id));
create policy requests_insert on public.material_requests for insert to authenticated with check((private.is_staff() or private.owns_member(member_id)) and created_by=auth.uid() and status='pending' and decided_by is null and decided_at is null);
create policy requests_update on public.material_requests for update to authenticated using(private.can_manage()) with check(private.can_manage());
create policy inspections_read on public.inspections for select to authenticated using(private.is_staff());
-- Initial pilot inspection writes restricted to managers; inspector workflow will use narrowly scoped RPC later.
create policy inspections_insert on public.inspections for insert to authenticated with check(private.can_manage());
create policy inspections_update on public.inspections for update to authenticated using(private.can_manage()) with check(private.can_manage());
create policy requirements_read on public.checklist_requirements for select to authenticated using(exists(select 1 from public.seasons s where s.id=season_id));
create policy requirements_insert on public.checklist_requirements for insert to authenticated with check(private.can_manage());
create policy requirements_update on public.checklist_requirements for update to authenticated using(private.can_manage()) with check(private.can_manage());
create policy lots_read on public.lots for select to authenticated using(private.is_staff());
create policy lots_insert on public.lots for insert to authenticated with check(private.can_manage());
create policy lots_update on public.lots for update to authenticated using(private.can_manage()) with check(private.can_manage());
create policy lot_plots_read on public.lot_plots for select to authenticated using(private.is_staff());
create policy lot_plots_insert on public.lot_plots for insert to authenticated with check(private.can_manage());
create policy lot_plots_update on public.lot_plots for update to authenticated using(private.can_manage()) with check(private.can_manage());
create policy audit_read on public.audit_log for select to authenticated using(private.can_manage());

create trigger audit_profiles after insert or update or delete on public.profiles for each row execute function private.audit_change();
create trigger audit_members after insert or update or delete on public.members for each row execute function private.audit_change();
create trigger audit_activities after insert or update or delete on public.activities for each row execute function private.audit_change();
create trigger audit_material_requests after insert or update or delete on public.material_requests for each row execute function private.audit_change();
create trigger audit_inspections after insert or update or delete on public.inspections for each row execute function private.audit_change();

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('evidence','evidence',false,10485760,array['image/jpeg','image/png','image/webp','audio/mpeg','audio/mp4','audio/ogg','audio/wav','application/pdf']);
-- Path: activity UUID / random object filename. No client overwrite or delete policy.
create policy evidence_object_read on storage.objects for select to authenticated using(bucket_id='evidence' and exists(select 1 from public.evidence e where e.storage_path=name));
create policy evidence_object_upload on storage.objects for insert to authenticated with check(bucket_id='evidence' and exists(select 1 from public.activities a where a.id::text=(storage.foldername(name))[1] and a.status<>'verified' and (private.is_staff() or private.owns_member(a.member_id))));

commit;
