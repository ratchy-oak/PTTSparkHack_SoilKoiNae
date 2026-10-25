import type {SoilDevice, SoilStatus} from './model.ts';
export type WaterProfile={fc:number;wp:number;rootDepth:number;p:number;layers:{theta:number;thickness:number}[];eto:number|null;kc:number|null;weatherDate:string;calibrated:boolean;source:string};
export const WATER_STATUS={pass:{label:'น้ำยังพอ',short:'น้ำยังพอ',color:'#227754',symbol:'✓'},risk:{label:'ควรเตรียมน้ำ',short:'ควรเตรียมน้ำ',color:'#A45C12',symbol:'!'},fail:{label:'ถึงเกณฑ์ให้น้ำ',short:'ถึงเกณฑ์ให้น้ำ',color:'#C34742',symbol:'!'},offline:{label:'ยังประเมินไม่ได้',short:'ยังประเมินไม่ได้',color:'#303943',symbol:'−'}};
export function assessWater(device:SoilDevice,now=Date.now()){
 const empty=(reason:string)=>({status:'offline' as SoilStatus,reason,next:'ตรวจข้อมูลหัววัดและข้อมูลดินประจำแปลง',dr:null as number|null,raw:null as number|null,taw:null as number|null,etc:null as number|null,days:null as number|null,theta:null as number|null});
 const r=device.reading,w=device.water;
 if(!r||!Number.isFinite(Date.parse(r.at))||now-Date.parse(r.at)>1800000||Date.parse(r.at)-now>300000||r.fault)return empty('ข้อมูลขาดช่วงหรือหัววัดมีปัญหา');
 if(!w||!w.calibrated)return empty('ยังขาดข้อมูลดินหรือการสอบเทียบความชื้น');
 if(![w.fc,w.wp,w.rootDepth,w.p].every(Number.isFinite)||w.wp<0||w.fc<=w.wp||w.fc>1||w.rootDepth<=0||w.p<=0||w.p>=1||!w.layers.length||w.layers.some(l=>!Number.isFinite(l.theta)||l.theta<0||l.theta>1||!Number.isFinite(l.thickness)||l.thickness<=0))return empty('ข้อมูลประเมินน้ำไม่ถูกต้อง');
 const depth=w.layers.reduce((s,l)=>s+l.thickness,0);
 if(Math.abs(depth-w.rootDepth)>0.001)return empty('ชั้นดินที่วัดยังไม่ครอบคลุมเขตราก');
 const theta=w.layers.reduce((s,l)=>s+l.theta*l.thickness,0)/depth,taw=1000*(w.fc-w.wp)*depth,raw=w.p*taw,dr=Math.max(0,1000*(w.fc-theta)*depth);
 const today=new Date(now).toLocaleDateString('en-CA',{timeZone:'Asia/Bangkok'});
 const etc=w.weatherDate===today&&w.eto!==null&&w.kc!==null&&Number.isFinite(w.eto)&&Number.isFinite(w.kc)&&w.eto>0&&w.kc>0?w.eto*w.kc:null;
 const days=etc===null?null:Math.max(0,(raw-dr)/etc);
 // Two days is an operational preparation window, not a FAO stress threshold.
 const status:SoilStatus=dr>=raw-1e-8?'fail':days!==null&&days<=2?'risk':'pass';
 return {status,dr,raw,taw,etc,days,theta,reason:status==='fail'?'น้ำพร่องถึงเกณฑ์พิจารณาให้น้ำ':status==='risk'?'คาดว่าเข้าใกล้เกณฑ์ภายใน 2 วัน':'น้ำพร่องยังต่ำกว่าเกณฑ์ให้น้ำ',next:theta>w.fc?'ความชื้นสูงกว่าความจุสนาม ตรวจการระบายน้ำก่อนให้น้ำเพิ่ม':status==='fail'?'ตรวจสภาพแปลงและฝนล่าสุด แล้ววางแผนให้น้ำ':status==='risk'?'เตรียมแหล่งน้ำและตรวจค่าซ้ำก่อนให้น้ำ':'ติดตามความชื้นต่อเนื่อง ยังไม่ต้องให้น้ำตามเกณฑ์นี้'};
}

/** Simplified one-day scenario; inputs are accumulated mm over the same next 24 h. */
export function projectWater(dr:number,etc:number,rainEffective:number,irrigationNet:number){
 if(![dr,etc,rainEffective,irrigationNet].every(v=>Number.isFinite(v)&&v>=0))return null;
 return Math.max(0,dr+etc-rainEffective-irrigationNet);
}
