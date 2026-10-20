'use client';
import {useEffect,useRef,useState} from 'react';
import type * as Leaflet from 'leaflet';
import {LocateFixed,MapPin,Minus,Plus} from 'lucide-react';
import {evaluateDevice,STATUS,type SoilDevice} from '@/lib/soil/model';
export default function SoilMap({devices,selected,onSelect,now}:{devices:SoilDevice[];selected:string|null;onSelect:(id:string)=>void;now:number}){
 const el=useRef<HTMLDivElement>(null),map=useRef<Leaflet.Map|null>(null),layer=useRef<Leaflet.LayerGroup|null>(null),api=useRef<typeof Leaflet|null>(null),select=useRef(onSelect);select.current=onSelect;
 const points=useRef(devices);points.current=devices;const selectedRef=useRef(selected);selectedRef.current=selected;const lastIds=useRef('');
 const [ready,setReady]=useState(false),[error,setError]=useState(false);const failures=useRef(0);
 useEffect(()=>{let active=true;let resize:ResizeObserver|undefined;
 void import('leaflet').then(L=>{if(!active||!el.current)return;api.current=L;const m=L.map(el.current,{zoomControl:false,scrollWheelZoom:false,attributionControl:true}).setView([15.044,104.056],13);map.current=m;
 L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png',{maxZoom:18,attribution:'&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'}).on('tileerror',()=>{failures.current++;if(active&&failures.current>2)setError(true);}).on('tileload',()=>{if(active)setError(false);}).addTo(m);
 layer.current=L.layerGroup().addTo(m);L.control.scale({position:'bottomleft',imperial:false}).addTo(m);resize=new ResizeObserver(()=>{m.invalidateSize();if(!selectedRef.current&&points.current.length)m.fitBounds(L.latLngBounds(points.current.map(d=>[d.lat,d.lng])),{padding:[60,70],maxZoom:14,animate:false});});resize.observe(el.current);setReady(true);
 }).catch(()=>{if(active)setError(true);});return()=>{active=false;resize?.disconnect();map.current?.remove();map.current=null;};},[]);
 useEffect(()=>{const L=api.current,m=map.current,g=layer.current;if(!ready||!L||!m||!g)return;g.clearLayers();
 const ids=devices.map(d=>d.id).join(',');if(ids!==lastIds.current&&devices.length){m.fitBounds(L.latLngBounds(devices.map(d=>[d.lat,d.lng])),{padding:[60,70],maxZoom:14,animate:false});lastIds.current=ids;}
 for(const d of devices){const s=evaluateDevice(d,now).status,meta=STATUS[s];const button=document.createElement('button');button.className=`soil-pin ${s}${selected===d.id?' selected':''}`;button.setAttribute('aria-label',`${d.name} ${d.id} ${meta.label}`);button.setAttribute('aria-pressed',String(selected===d.id));button.innerHTML=`<span>${meta.symbol}</span><small>${d.id.slice(-3)}</small>`;
 button.addEventListener('click',()=>select.current(d.id));L.marker([d.lat,d.lng],{icon:L.divIcon({className:'soil-marker',html:button,iconSize:[52,66],iconAnchor:[26,55]}),keyboard:false,zIndexOffset:selected===d.id?1000:0}).addTo(g);}
 },[devices,selected,ready,now]);
 useEffect(()=>{const d=devices.find(d=>d.id===selected);if(d&&ready)map.current?.panTo([d.lat,d.lng],{animate:!window.matchMedia('(prefers-reduced-motion: reduce)').matches});},[selected,devices,ready]);
 function fit(){if(!map.current||!api.current||!devices.length)return;map.current.fitBounds(api.current.latLngBounds(devices.map(d=>[d.lat,d.lng])),{padding:[65,65],maxZoom:14,animate:false});}
 return <div className="soil-map-wrap"><div className="soil-map" ref={el} role="region" aria-label="แผนที่จุดตรวจดิน"/><div className="soil-map-context"><MapPin size={16}/><span>ผักไหม · ศรีสะเกษ</span></div><div className="soil-map-tools"><button aria-label="แสดงจุดตรวจทั้งหมด" title="แสดงจุดตรวจทั้งหมด" onClick={fit}><LocateFixed size={20}/></button><span/><button aria-label="ขยายแผนที่" onClick={()=>map.current?.zoomIn()}><Plus size={20}/></button><button aria-label="ย่อแผนที่" onClick={()=>map.current?.zoomOut()}><Minus size={20}/></button></div>{error&&<p className="soil-map-error" role="status">โหลดพื้นแผนที่ไม่ได้ · เลือกจุดตรวจจากรายการด้านข้างได้</p>}<div className="soil-map-caption"><span className="soil-pulse"/>เลือกหมุดเพื่อดูข้อมูลดิน</div></div>;
}
