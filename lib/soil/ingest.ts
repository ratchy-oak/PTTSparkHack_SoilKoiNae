import type {Reading} from './model.ts';
export type SoilPayload=Reading&{device_id:string};
export function validateSoilPayload(value:unknown,now=Date.now()):SoilPayload{
 if(!value||typeof value!=='object'||Array.isArray(value))throw new Error('Expected a JSON object');const o=value as Record<string,unknown>;
 if(typeof o.device_id!=='string'||!/^SQ-[A-Z0-9-]{1,40}$/.test(o.device_id))throw new Error('Invalid device_id');
 if(typeof o.at!=='string'||!/^\d{4}-\d{2}-\d{2}T.+(?:Z|[+-]\d{2}:\d{2})$/.test(o.at)||!Number.isFinite(Date.parse(o.at))||Date.parse(o.at)>now+300000||Date.parse(o.at)<now-7*86400000)throw new Error('Invalid timestamp: use ISO 8601 with timezone, within 7 days and no more than 5 minutes ahead');
 const bounds={ph:[0,14],ec:[0,30],moisture:[0,100],temperature:[-20,80],battery:[0,100],signal:[-150,0]} as const;const result:Record<string,number|null>={};
 for(const [key,[low,high]] of Object.entries(bounds)){const x=o[key];if(x===null){result[key]=null;continue;}if(typeof x!=='number'||!Number.isFinite(x)||x<low||x>high)throw new Error(`Invalid ${key}`);result[key]=x;}
 if(o.fault!==null&&(typeof o.fault!=='string'||o.fault.length>120||!o.fault.trim()))throw new Error('fault must be null or a short error code');
 return {device_id:o.device_id,at:new Date(o.at).toISOString(),...result,fault:o.fault as string|null} as SoilPayload;
}
