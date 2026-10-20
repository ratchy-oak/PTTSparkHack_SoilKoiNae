'use client';
import { useRef, useState, type FormEvent } from 'react';
import { useRouter } from 'next/navigation';
import { Sprout, LogIn } from 'lucide-react';
import { browserDatabase } from '@/lib/supabase';
import { canUseOffice } from '@/lib/registry';
import '../soil.css';

export default function Login(){
 const router=useRouter();
 const [email,setEmail]=useState(''),[password,setPassword]=useState(''),[showPassword,setShowPassword]=useState(false),[busy,setBusy]=useState(false),[message,setMessage]=useState('');
 const saving=useRef(false);
 async function submit(event:FormEvent){
  event.preventDefault();if(saving.current)return;saving.current=true;setBusy(true);setMessage('');
  try{
   const db=browserDatabase();
   const {data,error}=await db.auth.signInWithPassword({email:email.trim(),password});
   if(error){setMessage('เข้าสู่ระบบไม่ได้ กรุณาตรวจอีเมลและรหัสผ่าน แล้วลองอีกครั้ง');return;}
   const result=await db.from('profiles').select('display_name,role,active').eq('id',data.user.id).single();
   if(result.error||!canUseOffice(result.data)){await db.auth.signOut();setMessage('บัญชีนี้ยังไม่มีสิทธิ์ใช้งาน กรุณาติดต่อผู้ดูแล');return;}
   setPassword('');router.replace('/office?source=live');
  }catch{setMessage('เชื่อมต่อไม่ได้ กรุณาลองอีกครั้ง ข้อมูลที่กรอกยังอยู่');}
  finally{saving.current=false;setBusy(false);}
 }
 return <main className="login-page soil-login"><div className="login-brand brand"><span className="brand-mark"><Sprout aria-hidden="true"/></span><span>Soilข่อยแน</span></div><section className="login-card" aria-labelledby="login-title"><h1 id="login-title">เข้าสู่ระบบทีมดูแล</h1><p className="muted">ติดตามสภาพดินจากอุปกรณ์จริง</p><form onSubmit={submit} aria-busy={busy}><fieldset disabled={busy}><label className="field-label">อีเมล<input type="email" name="email" inputMode="email" autoCapitalize="none" spellCheck={false} autoComplete="username" required value={email} onChange={e=>setEmail(e.target.value)}/></label><label className="field-label">รหัสผ่าน<input type={showPassword?'text':'password'} name="password" autoComplete="current-password" required value={password} onChange={e=>setPassword(e.target.value)}/></label><label className="password-toggle"><input type="checkbox" checked={showPassword} onChange={e=>setShowPassword(e.target.checked)}/>แสดงรหัสผ่าน</label>{message&&<p role="alert" className="error">{message}</p>}<button className="button primary login-submit"><LogIn aria-hidden="true" size={22}/>{busy?'กำลังเข้าสู่ระบบ…':'เข้าสู่ระบบ'}</button></fieldset></form><p className="login-help">หากเข้าไม่ได้ ให้ติดต่อผู้ดูแลของกลุ่ม</p></section></main>;
}
