import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import { mkdtemp, mkdir, readFile, writeFile, copyFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { NativeDriver } from '../lib/driver.js'
import { createToolSpecs } from '../lib/tools.js'
const root=process.env.DSH_LIKE_CODEX_TEST_DIR || await mkdtemp(join(tmpdir(),'dsh-background-test-'))
await mkdir(root,{recursive:true})
const packageRoot=fileURLToPath(new URL('../',import.meta.url))
const compile=spawnSync('xcrun',['swiftc',join(packageRoot,'tests/Fixture.swift'),'-o',join(root,'Fixture'),'-framework','AppKit'],{encoding:'utf8'})
assert.equal(compile.status,0,compile.stderr)
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms))
async function records(role='target'){try{return(await readFile(join(root,role+'.jsonl'),'utf8')).trim().split('\n').filter(Boolean).map(JSON.parse)}catch{return[]}}
async function until(predicate,description){for(let i=0;i<100;i++){if(await predicate())return;await pause(50)}throw new Error('Timed out: '+description)}
const apps={}
const fixturePids=[]
let observer
let measuredEnd
let controlStart
let controlEnd
let visualSummary
const driver=new NativeDriver()
const phases=[]
const failures=[]
async function call(method,params,options){const start=Date.now();const result=await driver.call(method,params,options);phases.push({method,start_ms:start,end_ms:Date.now(),ok:result.ok,route:result.data?.action?.route,error:result.error,focus:result.data?.focus || result.focus});return result}
function ok(result){assert.equal(result.ok,true,JSON.stringify(result));return result.data}
function find(s,role,label=''){const e=s.elements.find(x=>x.role===role && (!label || x.label.includes(label)));assert.ok(e,`Missing ${role} ${label}`);return e.element}
let state
try{
    const bridgeBuild=spawnSync('xcrun',['clang','-fblocks','-Wno-deprecated-declarations','-c',join(packageRoot,'native/Bridge.c'),'-o',join(root,'Bridge.o')],{encoding:'utf8'})
    assert.equal(bridgeBuild.status,0,bridgeBuild.stderr)
    const observerBuild=spawnSync('xcrun',['swiftc' ,join(packageRoot,'tests/Observer.swift'),'-import-objc-header',join(packageRoot,'native/Bridge.h'),join(root,'Bridge.o'),'-o',join(root,'Observer'),'-framework','AppKit','-framework','ScreenCaptureKit','-framework','ApplicationServices'],{encoding:'utf8'})
    assert.equal(observerBuild.status,0,observerBuild.stderr)
    const status=ok(await call('status',{}));assert.ok(status.accessibility && status.screen_recording,'Native permissions are required for this live test')
    for(const role of ['target','foreground','other']){
        const app=join(root,`DSH ${role} Fixture.app`),contents=join(app,'Contents')
        await mkdir(join(contents,'MacOS'),{recursive:true});await copyFile(join(root,'Fixture'),join(contents,'MacOS/Fixture'))
        await writeFile(join(contents,'Info.plist'),`<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Fixture</string><key>CFBundleIdentifier</key><string>local.dsh.likecodex.test.${role==='other'?'otherforeground':role}</string><key>CFBundleName</key><string>DSH ${role} Fixture</string></dict></plist>`)
        const launched=spawnSync('/usr/bin/open',[...(role!=='foreground'?['-g']:[]),'--env',`DSH_FIXTURE_DIR=${root}`,'--env',`DSH_FIXTURE_ROLE=${role}`,app],{env:{...process.env,DSH_FIXTURE_DIR:root},encoding:'utf8'})
        assert.equal(launched.status,0,launched.stderr)
        await until(async()=> (await records(role)).some(x=>x.event==='ready'),role+' ready')
        apps[role]=(await records(role)).find(x=>x.event==='ready');fixturePids.push(apps[role].pid)
    }
    observer=spawn(join(root,'Observer'),[join(root,'observer.jsonl')],{stdio:'ignore'})
    const observerRows=async()=>{try{return(await readFile(join(root,'observer.jsonl'),'utf8')).trim().split('\n').filter(Boolean).map(JSON.parse)}catch{return[]}}
    await until(async()=>(await observerRows()).some(x=>x.kind==='ready'),'observer ready')
    controlStart=Date.now();spawnSync('/usr/bin/open',[join(root,'DSH target Fixture.app')])
    await until(async()=>(await observerRows()).some(x=>x.kind==='frame'&&x.wall_ms>=controlStart&&x.red>x.samples/2),'red positive control')
    spawnSync('/usr/bin/open',[join(root,'DSH foreground Fixture.app')])
    const restoreStart=Date.now()
    await until(async()=>(await observerRows()).some(x=>x.kind==='frame'&&x.wall_ms>=restoreStart&&x.green>x.samples/2),'green witness restored')
    controlEnd=Date.now()
    state=ok(await call('observe' ,{pid:apps.target.pid,window_id:apps.target.window_id,include_image:true}))
    assert.ok(state.image.base64.length>1000)
    await writeFile(join(root,'background-initial.png'),Buffer.from(state.image.base64,'base64'))
    for(let i=0;i<3;i++){state=ok(await call('click',{snapshot_id:state.snapshot_id,element:find(state,'AXButton','Increment'),include_image:false}));assert.equal(state.action.route,'ax_AXPress')}
    let log=await records();assert.equal(log.filter(x=>x.event==='ax_press').length,3);assert.equal(log.filter(x=>x.event==='button').length,3)
    const adapter=createToolSpecs({}, {call:(...args)=>call(...args)}, {includeImages:false})
    const ownerA={agent:{},signal:new AbortController().signal},ownerB={agent:{},signal:new AbortController().signal}
    const adapterObserve=adapter.find(t=>t.name==='like_codex_observe'),adapterClick=adapter.find(t=>t.name==='like_codex_click')
    const observed=await adapterObserve.execute({pid:apps.target.pid,window_id:apps.target.window_id,include_image:false},ownerA)
    assert.equal(observed.ok,true)
    assert.equal((await adapterClick.execute({snapshot_id:observed.data.snapshot_id,element:find(observed.data,'AXButton','Increment')},ownerB)).ok,false)
    assert.equal((await records()).filter(x=>x.event==='button').length,3,'Another agent must not consume the snapshot')
    const ownClick=await adapterClick.execute({snapshot_id:observed.data.snapshot_id,element:find(observed.data,'AXButton','Increment')},ownerA)
    assert.equal(ownClick.ok,true);state=ownClick.data
    assert.equal((await records()).filter(x=>x.event==='button').length,4)
    const buttonFrame=state.elements.find(x=>x.role==='AXButton'&&x.label.includes('Increment')).frame
    const buttonX=buttonFrame.x+buttonFrame.width/2,buttonY=buttonFrame.y+buttonFrame.height/2
    const expectedPoint={x:buttonX/state.window.pixel_scale,y:state.window.bounds.height-buttonY/state.window.pixel_scale}
    state=ok(await call('click',{snapshot_id:state.snapshot_id,x:buttonX,y:buttonY,include_image:false}))
    log=await records();assert.equal(log.filter(x=>x.event==='button').length,5,'Screenshot-coordinate click must activate the actual button')
    const receivedPoint=log.filter(x=>x.event==='input'&&x.type===1).at(-1)
    assert.ok(Math.abs(receivedPoint.window_x-expectedPoint.x)<1&&Math.abs(receivedPoint.window_y-expectedPoint.y)<1,'Target must receive the requested window-local point')
    for(let i=0;i<3;i++) state=ok(await call('click',{snapshot_id:state.snapshot_id,x:900,y:1000,include_image:false}))
    log=await records();assert.equal(log.filter(x=>x.event==='surface_down').length,3)
    const text='Hello 你好🙂 e\u0301'
    state=ok(await call('type',{snapshot_id:state.snapshot_id,element:find(state,'AXTextField'),text,include_image:false}))
    log=await records();assert.equal(log.filter(x=>x.event==='text').at(-1)?.value,text,'Unicode insertion must reach the real editable control')
    state=ok(await call('key',{snapshot_id:state.snapshot_id,key:'super+a',include_image:false}))
    state=ok(await call('type',{snapshot_id:state.snapshot_id,text:'Replaced ✓',include_image:false}))
    log=await records();assert.equal(log.filter(x=>x.event==='text').at(-1)?.value,'Replaced ✓')
    state=ok(await call('set_value',{snapshot_id:state.snapshot_id,element:find(state,'AXTextField'),text:'AX 中文',include_image:false}))
    assert.equal(state.elements.find(x=>x.role==='AXTextField').value,'AX 中文')
    state=ok(await call('scroll',{snapshot_id:state.snapshot_id,x:900,y:1000,delta_y:-120,include_image:false}))
    assert.ok((await records()).some(x=>x.event==='input'&&x.type===22),'Target must receive a scroll event')
    state=ok(await call('drag',{snapshot_id:state.snapshot_id,x:900,y:1000,to_x:1100,to_y:1000,duration_ms:200,include_image:false}))
    assert.ok((await records()).some(x=>x.event==='surface_drag'),'Target must receive dragged events')
    const current=ok(await call('status',{})).frontmost_pid
    const other=current===apps.other.pid?'foreground':'other'
    const uninterruptedDrag=call('drag',{snapshot_id:state.snapshot_id,x:900,y:1000,to_x:1100,to_y:1000,duration_ms:800,include_image:false})
    setTimeout(()=>spawnSync('/usr/bin/open',[join(root,`DSH ${other} Fixture.app`)]),100)
    state=ok(await uninterruptedDrag)
    assert.equal(state.focus.changed,true,'Positive control must switch a third foreground application during input')
    assert.equal(state.focus.target_took_focus,false)
    const downsBefore=(await records()).filter(x=>x.event==='surface_down').length
    const upsBefore=(await records()).filter(x=>x.event==='surface_up').length
    const cancellation=new AbortController()
    const driverBeforeCancel=driver.child.pid
    const cancelledDrag=call('drag',{snapshot_id:state.snapshot_id,x:900,y:1000,to_x:1100,to_y:1000,duration_ms:3000}, {signal:cancellation.signal})
    setTimeout(()=>cancellation.abort(),150)
    await assert.rejects(cancelledDrag,/cancelled/i)
    state=ok(await call('observe',{pid:apps.target.pid,window_id:apps.target.window_id,include_image:false}))
    const afterCancel=await records()
    assert.equal(afterCancel.filter(x=>x.event==='surface_down').length,downsBefore+1)
    assert.equal(afterCancel.filter(x=>x.event==='surface_up').length,upsBefore+1,'Cancelled drag must release its mouse-down')
    assert.equal(driver.child.pid,driverBeforeCancel,'Cooperative cancellation must preserve virtual-focus state in the same driver process')
    state=ok(await call('screenshot',{snapshot_id:state.snapshot_id}));assert.ok(state.image.base64.length>1000)
    await writeFile(join(root,'background-final.png'),Buffer.from(state.image.base64,'base64'))
    measuredEnd=Date.now()
    const forcedTakeover=call('drag',{snapshot_id:state.snapshot_id,x:900,y:1000,to_x:1100,to_y:1000,duration_ms:800,include_image:false})
    setTimeout(()=>spawnSync('/usr/bin/open',[join(root,'DSH target Fixture.app')]),100)
    const interrupted=await forcedTakeover
    phases.at(-1).expected_focus_takeover=true
    assert.equal(interrupted.ok,false,'A deliberate target focus takeover must not be reported as input success')
    assert.equal(interrupted.error.code,'FOCUS_CHANGED')
    assert.equal(interrupted.focus.target_took_focus,true)
    await until(async()=>(await driver.call('status')).data.key_focus_pid!==apps.target.pid,'target focus returned after the controlled takeover')
    await writeFile(join(root,'target.command'),'second_window')
    await until(async()=>(await records()).some(x=>x.event==='second_ready'),'second window')
    spawnSync('/usr/bin/open',[join(root,'DSH target Fixture.app')])
    await until(async()=>(await driver.call('status')).data.frontmost_pid===apps.target.pid,'target app foreground positive control')
    state=ok(await call('observe',{pid:apps.target.pid,window_id:apps.target.window_id,include_image:false}))
    const otherWindow=await call('click',{snapshot_id:state.snapshot_id,element:find(state,'AXButton','Increment')})
    assert.equal(otherWindow.error.code,'UNSUPPORTED_BACKGROUND','Do not replace another focused window in the same foreground app')
    await writeFile(join(root,'target.command'),'close_second')
    spawnSync('/usr/bin/open',[join(root,'DSH foreground Fixture.app')])
    const secondRestore=Date.now()
    await until(async()=>(await observerRows()).some(x=>x.kind==='frame'&&x.wall_ms>=secondRestore&&x.green>x.samples/2),'green witness restored after real activation')
    state=ok(await call('observe',{pid:apps.target.pid,window_id:apps.target.window_id,include_image:false}))
    state=ok(await call('type',{snapshot_id:state.snapshot_id,element:find(state,'AXTextField'),text:' after reactivation',include_image:false}))
    state=ok(await call('key',{snapshot_id:state.snapshot_id,key:'super+a',include_image:false}))
    state=ok(await call('type',{snapshot_id:state.snapshot_id,text:'Reactivated ✓',include_image:false}))
    assert.equal((await records()).filter(x=>x.event==='text').at(-1).value,'Reactivated ✓')
    const secure=state.elements.find(x=>x.secure);assert.ok(secure)
    const refused=await call('type',{snapshot_id:state.snapshot_id,element:secure.element,text:'not-a-secret'});assert.equal(refused.error.code,'SECURE_INPUT');assert.equal(refused.action_may_have_executed,false)
    const stale=await call('click',{snapshot_id:state.snapshot_id,element:0});assert.equal(stale.error.code,'STALE_SNAPSHOT')
    state=ok(await call('observe',{pid:apps.target.pid,window_id:apps.target.window_id,include_image:false}))
    await writeFile(join(root,'target.command'),'move');await pause(150)
    const moved=await call('click',{snapshot_id:state.snapshot_id,x:100,y:100});assert.equal(moved.error.code,'STALE_SNAPSHOT')
    state=ok(await call('observe',{pid:apps.target.pid,window_id:apps.target.window_id,include_image:false}))
    await writeFile(join(root,'target.command'),'hide')
    await until(async()=>(await records()).some(x=>x.event==='hidden'),'offscreen window')
    const hiddenInput=await call('click',{snapshot_id:state.snapshot_id,x:100,y:100})
    assert.ok(['WINDOW_OFFSCREEN','STALE_SNAPSHOT'].includes(hiddenInput.error.code),'Image-free input must refuse hidden windows, including windows whose AX identity disappears')
    assert.equal(hiddenInput.action_may_have_executed,false)
    assert.equal((await call('observe',{pid:apps.target.pid,window_id:apps.target.window_id,include_image:false})).ok,false)
    await writeFile(join(root,'target.command'),'restore')
    await until(async()=>(await records()).some(x=>x.event==='shown'),'window shown for final minimization test')
    apps.target.window_id=(await records()).find(x=>x.event==='shown').window_id
    await writeFile(join(root,'target.command'),'minimize')
    await until(async()=>(await records()).some(x=>x.event==='notification'&&x.name==='NSWindowDidMiniaturizeNotification'),'minimization')
    const minimizedAt=(await records()).filter(x=>x.event==='notification'&&x.name==='NSWindowDidMiniaturizeNotification').at(-1).wall_ms
    const minimized=await call('observe',{pid:apps.target.pid,window_id:apps.target.window_id,include_image:true});assert.equal(minimized.error.code,'WINDOW_MINIMIZED')
    await pause(100)
    assert.ok(!(await records()).some(x=>x.event==='notification'&&x.name==='NSWindowDidDeminiaturizeNotification'&&x.wall_ms>=minimizedAt),'Observation must not restore minimized target')
    for(const phase of phases)if(phase.focus && !phase.expected_focus_takeover) assert.equal(phase.focus.target_took_focus,false,'Target acquired focus: '+JSON.stringify(phase))
}catch(error){failures.push(error.stack);throw error}
finally{
    await writeFile(join(root,'report.json'),JSON.stringify({phases,failures,apps},null,2))
    if(failures.length && apps.target)spawnSync('/usr/bin/sample',[String(apps.target.pid),'1','1','-file',join(root,'fixture-failure-sample.txt')],{stdio:'ignore'})
    if(observer){observer.kill('SIGTERM');await new Promise(resolve=>observer.once('close',resolve))}
    const rows=await (async()=>{try{return(await readFile(join(root,'observer.jsonl'),'utf8')).trim().split('\n').filter(Boolean).map(JSON.parse)}catch{return[]}})()
    const frames=rows.filter(x=>x.kind==='frame'&&x.wall_ms>=controlEnd&&x.wall_ms<=measuredEnd)
    const focus=rows.filter(x=>x.kind==='focus'&&x.wall_ms>=controlEnd&&x.wall_ms<=measuredEnd)
    const summary={control_target_focus_samples:rows.filter(x=>x.kind==='focus'&&x.key_focus_pid===apps.target?.pid&&x.wall_ms>=controlStart&&x.wall_ms<=controlEnd).length,controlStart,controlEnd,measuredEnd,frames:frames.length,red_frames:frames.filter(x=>x.red>x.samples/2).length,green_frames:frames.filter(x=>x.green>x.samples/2).length,focus_samples:focus.length,focus_errors:focus.filter(x=>x.status!==0).length,target_focus_samples:focus.filter(x=>x.key_focus_pid===apps.target?.pid).length,max_frame_pts_gap_ms:frames.length>1?Math.max(...frames.slice(1).map((x,i)=>(x.pts-frames[i].pts)*1000)):null,max_focus_sample_gap_ms:focus.length>1?Math.max(...focus.slice(1).map((x,i)=>x.wall_ms-focus[i].wall_ms)):null}
    visualSummary=summary
    await writeFile(join(root,'observer-summary.json'),JSON.stringify(summary,null,2))
    await driver.close()
    for(const pid of fixturePids)try{process.kill(pid,'SIGTERM')}catch{}
    console.log('Live evidence:',root)
}
assert.ok(visualSummary.frames>0 && visualSummary.focus_samples>0 && visualSummary.control_target_focus_samples>0,'Independent observers must collect data and detect the positive control')
assert.equal(visualSummary.red_frames,0,'Background target appeared in screen frames')
assert.equal(visualSummary.target_focus_samples,0,'Target acquired WindowServer key focus')
assert.equal(visualSummary.focus_errors,0,'WindowServer focus queries failed')
console.log(`PASS: ${phases.length} native requests, real AX/mouse/Unicode/shortcut/scroll/drag/screenshots, stale/secure/minimized refusals`)
