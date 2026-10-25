import {referenceForDate} from '@/lib/soil/reference';
import WaterForecast from './water-forecast';
import type {SoilDevice} from '@/lib/soil/model';
import {assessWater,WATER_STATUS} from '@/lib/soil/water';
export default function WaterDetail({device,now}:{device:SoilDevice;now:number}){
 const a=assessWater(device,now),w=device.water,ref=referenceForDate(now);
 return <section className={`water-detail ${a.status}`} aria-label="ผลประเมินน้ำในเขตราก">
 <div className="water-verdict"><span>น้ำในเขตราก · ประเมินจากค่าล่าสุด</span><h3>{WATER_STATUS[a.status].label}</h3><p>{a.next}</p></div>
 {a.dr===null?<p className="water-note">{a.reason} · ต้องมี FC, WP, ความลึกราก, p และความชื้นที่สอบเทียบครบเขตรากก่อนประเมิน</p>:<>
 <div className="water-numbers"><div><span>น้ำพร่องวันนี้</span><strong>{a.dr.toFixed(1)}<small> มม.</small></strong><abbr title="Root zone depletion">Dr</abbr></div><div><span>เกณฑ์ให้น้ำ</span><strong>{a.raw!.toFixed(1)}<small> มม.</small></strong><abbr title="Readily available water">RAW</abbr></div><div><span>สูญเสียต่อวัน</span><strong>{a.etc?.toFixed(1)??'—'}<small> มม./วัน</small></strong><abbr title="Crop evapotranspiration">ETc</abbr></div></div>
 <div className="water-progress" role="img" aria-label={`น้ำพร่อง ${a.dr.toFixed(1)} จากเกณฑ์ ${a.raw!.toFixed(1)} มิลลิเมตร`}><span style={{width:`${Math.min(100,a.dr/a.raw!*100)}%`}}/></div><div className="water-scale"><span>ยังไม่พร่อง</span><span>ถึงเกณฑ์ให้น้ำ</span></div>
 <WaterForecast key={device.id} dr={a.dr} raw={a.raw!} etc={a.etc} now={now}/><details className="water-method"><summary>ดูข้อมูลที่ใช้ประเมิน</summary><p>ความชื้นเฉลี่ยเขตราก {(a.theta!*100).toFixed(1)}% VWC · ราก {w!.rootDepth*100} ซม.</p>{w!.layers.map((l,i)=><p key={i}>ชั้นที่ {i+1} หนา {l.thickness*100} ซม. · {(l.theta*100).toFixed(1)}% VWC</p>)}<p>FC {w!.fc*100}% · WP {w!.wp*100}% · p {w!.p} · TAW {a.taw!.toFixed(1)} มม.</p><p>Kc {w!.kc??'—'} · {w!.weatherDate}</p><dl className="water-reference"><div><dt>ET₀ ที่ใช้ประเมิน</dt><dd>{w!.eto?.toFixed(2)??'—'} มม./วัน</dd></div><div><dt>ฝนเฉลี่ย P</dt><dd>{ref.rain} มม./เดือน</dd></div><div><dt>ฝนใช้ได้ Peff</dt><dd>{ref.effectiveMonthly.toFixed(2)} มม./เดือน</dd></div><div><dt>Peff เฉลี่ยต่อวัน</dt><dd>{ref.effectiveDaily.toFixed(2)} มม./วัน</dd></div></dl></details>
 </>}
 </section>;
}
