import {projectWater} from '@/lib/soil/water';
import {referenceForDate} from '@/lib/soil/reference';
export default function WaterForecast({dr,raw,etc,now}:{dr:number;raw:number;etc:number|null;now:number}){
 const ref=referenceForDate(now),next=etc===null?null:projectWater(dr,etc,ref.effectiveDaily,0);
 return <section className="water-forecast" aria-label="แนวโน้มน้ำในดิน">
 <div className="water-forecast-title"><h3>แนวโน้มน้ำในวันถัดไป</h3></div>
 <div className={`water-forecast-result ${next===null?'offline':next>=raw?'fail':next+ (etc??0)>=raw?'risk':'pass'}`}><span>น้ำพร่องโดยประมาณ</span><strong>{next?.toFixed(1)??'—'} <small>มม.</small></strong><p>{next===null?'ข้อมูลยังไม่พอคำนวณแนวโน้ม':next>=raw?'อาจถึงเกณฑ์ให้น้ำ · ตรวจแปลงและฝนจริงก่อนตัดสินใจ':next+(etc??0)>=raw?'ควรเตรียมน้ำ · แนวโน้มเข้าใกล้เกณฑ์ให้น้ำ':'ยังต่ำกว่าเกณฑ์ให้น้ำ · ติดตามค่าจริงต่อเนื่อง'}</p></div>
 
 </section>;
}
