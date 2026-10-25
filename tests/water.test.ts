import test from 'node:test';
import assert from 'node:assert/strict';
import {makeDemoDevices} from '../lib/soil/model.ts';
import {assessWater} from '../lib/soil/water.ts';
const now=Date.parse('2026-10-23T09:00:00Z');
test('water assessment weights layers and separates current depletion from daily ET',()=>{const d=makeDemoDevices(now)[0];d.water!.fc=.3;d.water!.wp=.15;d.water!.eto=4;d.water!.layers=[{theta:.25,thickness:.2},{theta:.20,thickness:.4}];const a=assessWater(d,now);assert.ok(Math.abs(a.dr!-50)<1e-8);assert.ok(Math.abs(a.raw!-45)<1e-8);assert.equal(a.status,'fail');assert.equal(a.etc,4.6);});
test('threshold boundary, preparation horizon, missing weather and wet soil',()=>{const d=makeDemoDevices(now)[0];d.water!.fc=.3;d.water!.wp=.15;d.water!.eto=4;d.water!.layers=[{theta:.225,thickness:.6}];assert.equal(assessWater(d,now).status,'fail');d.water!.fc=.3;d.water!.wp=.15;d.water!.eto=4;d.water!.layers=[{theta:.235,thickness:.6}];assert.equal(assessWater(d,now).status,'risk');d.water!.weatherDate='2020-01-01';assert.equal(assessWater(d,now).days,null);assert.equal(assessWater(d,now).status,'pass');d.water!.fc=.3;d.water!.wp=.15;d.water!.eto=4;d.water!.layers=[{theta:.4,thickness:.6}];assert.equal(assessWater(d,now).dr,0);assert.match(assessWater(d,now).next,/ระบายน้ำ/);});
test('never evaluates absent calibration, incomplete root coverage or stale measurements',()=>{const d=makeDemoDevices(now)[0];assert.equal(assessWater({...d,water:undefined},now).status,'offline');for(const patch of [{calibrated:false},{fc:.1},{p:1},{layers:[{theta:NaN,thickness:.6}]},{layers:[{theta:.2,thickness:.3}]}])assert.equal(assessWater({...d,water:{...d.water!,...patch}},now).status,'offline');assert.equal(assessWater(d,now+31*60000).status,'offline');});

test('one-day projection subtracts effective rain and net irrigation without negative depletion',async()=>{
 const {projectWater}=await import('../lib/soil/water.ts');
 assert.equal(projectWater(40,5,0,0),45);
 assert.equal(projectWater(40,5,8,0),37);
 assert.equal(projectWater(40,5,8,10),27);
 assert.equal(projectWater(40,5,60,0),0);
 for(const args of [[40,5,-1,0],[NaN,5,0,0],[40,Infinity,0,0]])assert.equal(projectWater(...args as [number,number,number,number]),null);
});

test('slide reference converts percent and monthly climate with actual calendar days',async()=>{
 const {referenceForDate,SOYBEAN_REFERENCE}=await import('../lib/soil/reference.ts');
 const oct=referenceForDate(now);assert.equal(oct.eto,3.62);assert.ok(Math.abs(oct.effectiveMonthly-65.8)<1e-8);assert.ok(Math.abs(oct.effectiveDaily-65.8/31)<1e-8);
 assert.equal(referenceForDate(Date.parse('2026-01-15T00:00:00Z')).effectiveDaily,0);
 assert.equal(SOYBEAN_REFERENCE.fc,.27);assert.equal(SOYBEAN_REFERENCE.wp,.17);
});
