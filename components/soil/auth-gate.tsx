'use client';

import {useEffect,useState,type ReactNode} from 'react';
import {browserDatabase} from '@/lib/supabase';
import {canUseOffice} from '@/lib/registry';

/** Mount the dashboard only after Supabase verifies the user and staff access. */
export default function SoilAuthGate({children}:{children:ReactNode}){
 const [allowed,setAllowed]=useState(false);
 useEffect(()=>{
  let active=true;
  const db=browserDatabase();
  function deny(){if(!active)return;setAllowed(false);window.location.replace('/login');}
  async function verify(){
   try{
    const {data,error}=await db.auth.getUser();
    if(!active)return;
    if(error||!data.user){deny();return;}
    const result=await db.from('profiles').select('display_name,role,active').eq('id',data.user.id).single();
    if(!active)return;
    if(result.error||!canUseOffice(result.data)){deny();return;}
    setAllowed(true);
   }catch{deny();}
  }
  const {data}=db.auth.onAuthStateChange((event,session)=>{
   if(event==='SIGNED_OUT'||!session)deny();
  });
  function recheck(){if(document.visibilityState==='visible')void verify();}
  function restored(event:PageTransitionEvent){if(event.persisted){setAllowed(false);void verify();}}
  document.addEventListener('visibilitychange',recheck);
  window.addEventListener('pageshow',restored);
  void verify();
  return()=>{active=false;data.subscription.unsubscribe();document.removeEventListener('visibilitychange',recheck);window.removeEventListener('pageshow',restored);};
 },[]);
 return allowed?children:<main className="login-page soil-login" aria-busy="true"><p role="status">กำลังตรวจสอบการเข้าสู่ระบบ…</p></main>;
}
