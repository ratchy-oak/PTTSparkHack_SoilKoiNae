import {referenceForDate,SOYBEAN_REFERENCE} from './reference.ts';
import type {WaterProfile} from './water.ts';
export type SoilStatus='pass'|'risk'|'fail'|'offline';
export type MetricKey='ph'|'ec'|'moisture'|'temperature';
export type Reading={at:string;ph:number|null;ec:number|null;moisture:number|null;temperature:number|null;battery:number|null;signal:number|null;fault:string|null};
export type SoilDevice={id:string;name:string;plot:string;village:string;lat:number;lng:number;area:number;installed_at:string;water?:WaterProfile;reading:Reading|null;history:Reading[]};
export const STATUS:Record<SoilStatus,{label:string;short:string;color:string;symbol:string}>={pass:{label:'อยู่ในเกณฑ์',short:'อยู่ในเกณฑ์',color:'#227754',symbol:'✓'},risk:{label:'มีความเสี่ยง',short:'มีความเสี่ยง',color:'#A45C12',symbol:'!'},fail:{label:'นอกเกณฑ์',short:'นอกเกณฑ์',color:'#C34742',symbol:'×'},offline:{label:'อุปกรณ์มีปัญหา',short:'อุปกรณ์มีปัญหา',color:'#303943',symbol:'−'}};
// Prototype screening profile only. Not an ICS certification standard or a prescription.
export const METRICS:Record<MetricKey,{label:string;unit:string;min:number;max:number;warnMin:number;warnMax:number;precision:number;description:string}>={
 ph:{label:'ความเป็นกรด–ด่าง',unit:'pH',min:5.5,max:7,warnMin:5,warnMax:7.5,precision:1,description:'ตรวจสภาพดินและยืนยันด้วยการเก็บตัวอย่างก่อนปรับปรุงดิน'},
 ec:{label:'การนำไฟฟ้าดิน',unit:'mS/cm',min:0,max:2,warnMin:0,warnMax:4,precision:2,description:'ตรวจความชื้นและวิธีวัด แล้วเก็บตัวอย่างยืนยันค่าการนำไฟฟ้า'},
 moisture:{label:'ความชื้นดิน',unit:'% VWC',min:25,max:60,warnMin:15,warnMax:75,precision:0,description:'สำรวจน้ำในแปลงร่วมกับระยะการปลูกและชนิดดิน'},
 temperature:{label:'อุณหภูมิดิน',unit:'°C',min:20,max:35,warnMin:15,warnMax:40,precision:1,description:'ตรวจเวลา ความลึก และตำแหน่งหัววัดก่อนสรุปความผิดปกติ'}
};
export const KEYS=Object.keys(METRICS) as MetricKey[];
export function metricStatus(key:MetricKey,value:number|null):SoilStatus{
 if(value===null||!Number.isFinite(value))return 'offline';const m=METRICS[key];return value<m.warnMin||value>m.warnMax?'fail':value<m.min||value>m.max?'risk':'pass';
}
export function evaluateDevice(device:SoilDevice,now:number=Date.now()):{status:SoilStatus;reason:string;next:string}{
 const r=device.reading;
 if(!r)return {status:'offline',reason:'ยังไม่ได้รับข้อมูลจากอุปกรณ์',next:'ตรวจแหล่งจ่ายไฟและการเชื่อมต่อของอุปกรณ์'};
 const age=now-Date.parse(r.at);
 if(!Number.isFinite(age)||age< -300000||age>30*60000)return {status:'offline',reason:'ไม่ได้รับข้อมูลภายใน 30 นาที',next:'ตรวจแบตเตอรี่ สัญญาณ และ Gateway ก่อนอ่านผลดิน'};
 if(r.fault)return {status:'offline',reason:'หัววัดหรืออุปกรณ์รายงานข้อผิดพลาด',next:'ตรวจสายและหัววัด แล้วสอบเทียบก่อนใช้งานต่อ'};
 if(KEYS.some(k=>metricStatus(k,r[k])==='offline'))return {status:'offline',reason:'ข้อมูลหัววัดไม่ครบ',next:'ตรวจหัววัดที่ไม่มีค่าและรอข้อมูลชุดใหม่'};
 const bad=KEYS.find(k=>metricStatus(k,r[k])==='fail')??KEYS.find(k=>metricStatus(k,r[k])==='risk');
 if(bad)return {status:metricStatus(bad,r[bad]),reason:`${METRICS[bad].label}${r[bad]!<METRICS[bad].min?'ต่ำ':'สูง'}กว่าช่วงทดลอง`,next:METRICS[bad].description};
 return {status:'pass',reason:'ค่าดินทั้ง 4 รายการอยู่ในช่วงทดลอง',next:'ติดตามแนวโน้มและดูแลหัววัดตามรอบสอบเทียบ'};
}
export function relativeTime(at:string|null,now:number){if(!at)return 'ยังไม่มีข้อมูล';const minutes=Math.max(0,Math.floor((now-Date.parse(at))/60000));return minutes<1?'เมื่อสักครู่':minutes<60?`${minutes} นาทีที่แล้ว`:minutes<1440?`${Math.floor(minutes/60)} ชม. ที่แล้ว`:`${Math.floor(minutes/1440)} วันที่แล้ว`;}
export function formatMetric(key:MetricKey,value:number|null){return value===null||!Number.isFinite(value)?'—':value.toFixed(METRICS[key].precision);}
export function makeDemoDevices(now:number):SoilDevice[]{
 const climate=referenceForDate(now);
 const values:[number,number,number,number][]=[[6.3,.82,20,28.4]];
 // Location supplied by the user via Google Maps; sensor readings remain simulated.
 const coords=[[16.4695956,102.8133145]];
 return values.map((v,i)=>{const age=i===3?128:2+i;const at=new Date(now-age*60000).toISOString();const reading:Reading={at,ph:v[0],ec:v[1],moisture:20,temperature:v[3],battery:i===3?12:91-i*6,signal:-73-i*3,fault:null};const history:Reading[]=Array.from({length:25},(_,h)=>({...reading,at:new Date(Date.parse(at)-(24-h)*3600000).toISOString(),ph:Math.round((v[0]+Math.sin(h*.5)*.14)*100)/100,ec:Math.round((v[1]+Math.sin(h*.6)*.06)*100)/100,moisture:Math.round((reading.moisture!+Math.sin(h*.4)*1)*10)/10,temperature:Math.round((v[3]+Math.sin(h*.3)*1.8)*10)/10}));history[24]=reading;return {id:`SQ-${String(i+1).padStart(3,'0')}`,name:`จุดตรวจ ${String(i+1).padStart(2,'0')}`,plot:'แปลงเกษตรกรรม มข.',village:'มหาวิทยาลัยขอนแก่น · จุดสาธิต',lat:coords[i][0],lng:coords[i][1],area:4+i*.5,installed_at:'2026-10-01',water:{fc:SOYBEAN_REFERENCE.fc,wp:SOYBEAN_REFERENCE.wp,rootDepth:.6,p:.5,layers:[{theta:reading.moisture!/100,thickness:.3},{theta:reading.moisture!/100+.01,thickness:.3}],eto:climate.eto,kc:SOYBEAN_REFERENCE.kcMid,weatherDate:new Date(now).toLocaleDateString('en-CA',{timeZone:'Asia/Bangkok'}),calibrated:true,source:'ค่าดินและภูมิอากาศจากสไลด์ · สมมติระยะกลางฤดูและราก 60 ซม. · ความชื้นจำลอง'},reading,history};});
}
