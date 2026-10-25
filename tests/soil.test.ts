import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
import {evaluateDevice,makeDemoDevices,metricStatus} from '../lib/soil/model.ts';
import {validateSoilPayload} from '../lib/soil/ingest.ts';
const now=Date.parse('2026-10-20T06:00:00Z');
test('soil screening includes boundaries and never assesses stale, partial or faulted readings',()=>{
 const d=makeDemoDevices(now)[0];d.reading!.moisture=30;assert.equal(evaluateDevice(d,now).status,'pass');
 assert.equal(metricStatus('ph',5.5),'pass');assert.equal(metricStatus('ph',5),'risk');assert.equal(metricStatus('ph',4.99),'fail');assert.equal(metricStatus('ph',7),'pass');assert.equal(metricStatus('ph',7.5),'risk');assert.equal(metricStatus('ph',7.51),'fail');
 assert.equal(evaluateDevice({...d,reading:{...d.reading!,ph:4}},now).status,'fail');
 for(const patch of [{at:new Date(now-31*60000).toISOString()},{at:'bad'},{fault:'probe_error'},{ph:null},{ph:NaN}])assert.equal(evaluateDevice({...d,reading:{...d.reading!,...patch}},now).status,'offline');
 assert.equal(evaluateDevice({...d,reading:null},now).status,'offline');
});
test('soil payload requires numeric values, valid units ranges, identifiers and timestamp timezone',()=>{
 const p={device_id:'SQ-001',...makeDemoDevices(now)[0].reading!};assert.equal(validateSoilPayload(p,now).device_id,'SQ-001');
 for(const patch of [{ph:'6'},{ph:Infinity},{ec:-1},{moisture:101},{temperature:81},{battery:101},{signal:10},{at:'2026-10-20T06:00:00'},{at:new Date(now+6*60000).toISOString()},{at:new Date(now-8*86400000).toISOString()},{device_id:'../bad'},{fault:''}])assert.throws(()=>validateSoilPayload({...p,...patch},now));
 assert.equal(validateSoilPayload({...p,ph:null,fault:'PH_DISCONNECTED'},now).ph,null);
});
test('soil SQL blocks anonymous reads and browser writes, deduplicates ingestion and keeps latest reading',async()=>{
 const db=new PGlite();try{
 await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;create schema auth;create function auth.uid() returns uuid language sql as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth to authenticated;grant execute on function auth.uid() to authenticated;create table public.profiles(id uuid primary key,role text,active boolean default true);grant select on profiles to authenticated;insert into profiles(id,role) values('00000000-0000-0000-0000-000000000001','manager');`);
 await db.exec(await readFile(new URL('../supabase/migrations/202610200009_soil_monitoring.sql',import.meta.url),'utf8'));
 await db.exec(`insert into soil_devices(id,name,plot,lat,lng) values('SQ-001','test','test',15,104);`);
 const p={device_id:'SQ-001',...makeDemoDevices(Date.now())[0].reading!};
 await db.exec('set role service_role');
 assert.equal((await db.query<{ok:boolean}>('select soil_ingest($1::jsonb) as ok',[JSON.stringify(p)])).rows[0].ok,true);
 assert.equal((await db.query<{ok:boolean}>('select soil_ingest($1::jsonb) as ok',[JSON.stringify(p)])).rows[0].ok,false);
 await db.exec('reset role;set role anon');await assert.rejects(db.query('select * from soil_devices'));await assert.rejects(db.query('select soil_dashboard()'));
 await db.exec('reset role;set role authenticated');assert.equal((await db.query('select * from soil_devices')).rows.length,0);await assert.rejects(db.query('select soil_ingest($1::jsonb)',[JSON.stringify(p)]));
 await db.exec(`select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false)`);
 assert.equal((await db.query('select * from soil_devices')).rows.length,1);
 const data=(await db.query<{data:{reading:{at:string};history:unknown[]}[]}>('select soil_dashboard() as data')).rows[0].data;
 assert.equal(data.length,1);assert.equal(data[0].history.length,1);assert.equal(Date.parse(data[0].reading.at),Date.parse(p.at));
 await assert.rejects(db.query(`insert into soil_devices(id,name,plot,lat,lng) values('SQ-X','x','x',15,104)`));
 }finally{await db.close();}
});
