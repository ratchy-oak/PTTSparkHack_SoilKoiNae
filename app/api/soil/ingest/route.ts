import {createHash,timingSafeEqual} from 'node:crypto';
import {createClient} from '@supabase/supabase-js';
import {validateSoilPayload} from '@/lib/soil/ingest';
export const runtime='nodejs';
export async function POST(request:Request){
 const token=process.env.SOIL_INGEST_TOKEN,url=process.env.NEXT_PUBLIC_SUPABASE_URL,key=process.env.SUPABASE_SECRET_KEY;
 if(!token||token.length<32||!url||!key)return Response.json({error:'Soil ingestion is not configured'},{status:503});
 const header=request.headers.get('authorization')??'';
 if(header.length>512||!header.startsWith('Bearer ')||!timingSafeEqual(createHash('sha256').update(header.slice(7)).digest(),createHash('sha256').update(token).digest()))return Response.json({error:'Unauthorized'},{status:401});
 if(!request.headers.get('content-type')?.toLowerCase().startsWith('application/json'))return Response.json({error:'Use application/json'},{status:415});
 if(Number(request.headers.get('content-length')??0)>8192)return Response.json({error:'Payload too large'},{status:413});
 const reader=request.body?.getReader();if(!reader)return Response.json({error:'Empty body'},{status:400});let body='',bytes=0;const decoder=new TextDecoder();
 try{while(true){const part=await reader.read();if(part.done)break;bytes+=part.value.byteLength;if(bytes>8192){await reader.cancel();return Response.json({error:'Payload too large'},{status:413});}body+=decoder.decode(part.value,{stream:true});}body+=decoder.decode();}catch{return Response.json({error:'Cannot read body'},{status:400});}
 let payload;try{payload=validateSoilPayload(JSON.parse(body));}catch(e){return Response.json({error:e instanceof Error?e.message:'Invalid payload'},{status:400});}
 const db=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});const r=await db.rpc('soil_ingest',{p:payload});
 if(r.error)return Response.json({error:r.error.code==='P0002'?'Unknown or inactive device':'Cannot store reading'},{status:r.error.code==='P0002'?404:503});
 return Response.json({accepted:true,inserted:r.data,device_id:payload.device_id},{status:r.data?201:200});
}
