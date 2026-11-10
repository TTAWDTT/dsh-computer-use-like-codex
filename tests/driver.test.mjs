import test from 'node:test'
import assert from 'node:assert/strict'
import { NativeDriver } from '../lib/driver.js'
import { createToolSpecs } from '../lib/tools.js'
const supported=process.platform==='darwin'
test('real native protocol reports permissions and isolated background capabilities',{skip:!supported},async()=>{
  const driver=new NativeDriver()
  try {const r=await driver.call('status');assert.equal(r.ok,true);assert.equal(r.data.protocol,1);assert.equal(r.data.background_only,true);assert.equal(r.data.automatic_foreground_fallback,false)}finally{await driver.close()}
})
test('native malformed parameters get an immediate correlated error',{skip:!supported},async()=>{
  const driver=new NativeDriver({timeoutMs:2000})
  try {const r=await driver.call('observe',{pid:'not-an-integer'});assert.equal(r.ok,false);assert.equal(r.error.code,'INVALID_REQUEST');assert.ok(Number.isInteger(r.id))}finally{await driver.close()}
})
test('unknown methods and consumed/missing snapshots never dispatch input',{skip:!supported},async()=>{
  const driver=new NativeDriver()
  try {assert.equal((await driver.call('not_a_method')).error.code,'UNKNOWN_METHOD');const r=await driver.call('click',{snapshot_id:'missing',x:1,y:1});assert.equal(r.error.code,'STALE_SNAPSHOT');assert.equal(r.action_may_have_executed,false)}finally{await driver.close()}
})
test('queued requests remain correlated without a UI action',{skip:!supported},async()=>{
  const driver=new NativeDriver()
  try {const rs=await Promise.all(Array.from({length:8},()=>driver.call('status')));assert.equal(new Set(rs.map(r=>r.id)).size,8);assert.ok(rs.every(r=>r.ok))}finally{await driver.close()}
})
test('cancellation before dispatch does not start a native process',{skip:!supported},async()=>{
  const driver=new NativeDriver();const controller=new AbortController();controller.abort()
  try{await assert.rejects(driver.call('status',{}, {signal:controller.signal}));assert.equal(driver.child,null)}finally{await driver.close()}
})
test('adapter cannot use another agents observation or omit identity',{skip:!supported},async()=>{
  const driver=new NativeDriver(),tools=createToolSpecs({},driver,{includeImages:false}),click=tools.find(x=>x.name==='like_codex_click')
  try{const r=await click.execute({snapshot_id:'other-agent',x:1,y:1},{agent:{},signal:new AbortController().signal});assert.equal(r.ok,false);assert.equal(driver.child,null);assert.equal((await click.execute({},{})).ok,false)}finally{await driver.close()}
})

test('image coordinate mapping survives status and apps observations',async()=>{
  // Canned boundary DTOs isolate attachment normalization from UI and native permissions.
  // Native input and real attachment storage are exercised by the live and DSH profile tests.
  let received
  const external={call:async(method,args)=>{
    if(method==='observe')return{ok:true,data:{snapshot_id:'scaled',window:{bundle_id:'test',window_id:1,bounds:{width:900},pixel_scale:2},elements:[{frame:{x:200,y:100,width:100,height:40}}],image:{base64:'AA==',width:1800,height:1264,media_type:'image/png'}}}
    if(method==='click'){received=args;return{ok:false,error:{code:'TEST_BOUNDARY',message:'No UI input in this adapter test'}}}
    return{ok:true,data:{}}
  }}
  const attachments={saveImage:async()=>({attachmentId:'test',mediaType:'image/png',bytes:1,width:900,height:632})}
  const tools=createToolSpecs({attachments},external,{includeImages:true}),exec={agent:{},signal:new AbortController().signal}
  const run=(name,args={})=>tools.find(t=>t.name==='like_codex_'+name).execute(args,exec)
  const view=await run('observe',{pid:1,include_image:true});assert.equal(view.data.elements[0].frame.x,100)
  await run('status');await run('apps')
  await run('click',{snapshot_id:'scaled',x:100,y:200})
  assert.equal(received.x,200);assert.equal(received.y,400)
})
