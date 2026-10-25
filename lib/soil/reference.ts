// Transcribed from the user's pitch slides. Climate normals, not daily forecasts.
export const MONTHLY_REFERENCE=[
 {month:'มกราคม',eto:3.4,rain:6.6},{month:'กุมภาพันธ์',eto:3.92,rain:9.9},
 {month:'มีนาคม',eto:4.56,rain:47.2},{month:'เมษายน',eto:4.75,rain:85.9},
 {month:'พฤษภาคม',eto:4.42,rain:186.4},{month:'มิถุนายน',eto:4.43,rain:194.1},
 {month:'กรกฎาคม',eto:4.19,rain:219.9},{month:'สิงหาคม',eto:3.71,rain:270.7},
 {month:'กันยายน',eto:3.85,rain:266.5},{month:'ตุลาคม',eto:3.62,rain:113.5},
 {month:'พฤศจิกายน',eto:3.79,rain:29.7},{month:'ธันวาคม',eto:3.45,rain:3}
] as const;
export function referenceForDate(now:number){
 const date=new Date(now),parts=new Intl.DateTimeFormat('en-US',{timeZone:'Asia/Bangkok',year:'numeric',month:'numeric'}).formatToParts(date);
 const year=Number(parts.find(p=>p.type==='year')!.value),month=Number(parts.find(p=>p.type==='month')!.value),ref=MONTHLY_REFERENCE[month-1];
 const effectiveMonthly=Math.max(0,ref.rain>75?.8*ref.rain-25:.6*ref.rain-10);
 return {...ref,effectiveMonthly,effectiveDaily:effectiveMonthly/new Date(Date.UTC(year,month,0)).getUTCDate()};
}
export const SOYBEAN_REFERENCE={fc:.27,wp:.17,kcMid:1.15,kcEnd:.5};
