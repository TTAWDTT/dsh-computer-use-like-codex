import assert from 'node:assert/strict'
import {mkdtemp,readFile,writeFile}from 'node:fs/promises'
import {tmpdir}from 'node:os'
import {join}from 'node:path'
import {spawnSync}from 'node:child_process'
import {NativeDriver}from '../lib/driver.js'
const root=await mkdtemp(join(tmpdir(),'dsh-textedit-test-')),file=join(root,'DSH-background-verification.txt'),driver=new NativeDriver(),results=[]
let state
async function call(method,p){const r=await driver.call(method,p);results.push({method,ok:r.ok,error:r.error,route:r.data?.action?.route,focus:r.data?.focus||r.focus});return r}
function ok(r){assert.equal(r.ok,true,JSON.stringify(r));return r.data}
try{
 const rows=ok(await call('apps',{})).windows
 if(rows.some(w=>w.bundle_id==='com.apple.TextEdit')){console.log('SKIP: TextEdit already has windows; keeping them untouched');process.exitCode=2}
 else{
  await writeFile(file,'seed')
  assert.equal(spawnSync('/usr/bin/open',['-g','-a','/System/Applications/TextEdit.app',file]).status,0)
  let window
  for(let i=0;i<100;i++){window=ok(await driver.call('apps',{})).windows.find(w=>w.bundle_id==='com.apple.TextEdit'&&w.title.includes('DSH-background-verification'));if(window)break;await new Promise(r=>setTimeout(r,50))}
  assert.ok(window,'Missing unique temporary document window')
  const packageRoot=new URL('../',import.meta.url).pathname
  const build=spawnSync('xcrun',['swiftc',join(packageRoot,'tests/Fixture.swift'),'-o',join(root,'Fixture'),'-framework','AppKit'],{encoding:'utf8'});assert.equal(build.status,0,build.stderr)
  const {mkdir,copyFile}=await import('node:fs/promises')
  const contents=join(root,'TextEdit Witness.app','Contents');await mkdir(join(contents,'MacOS'),{recursive:true});await copyFile(join(root,'Fixture'),join(contents,'MacOS/Fixture'))
  await writeFile(join(contents,'Info.plist'),'<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Fixture</string><key>CFBundleIdentifier</key><string>local.dsh.textedit.witness.foreground</string><key>CFBundleName</key><string>TextEdit Witness</string></dict></plist>')
  assert.equal(spawnSync('/usr/bin/open',['--env',`DSH_FIXTURE_DIR=${root}`,join(root,'TextEdit Witness.app')]).status,0)
  let witness
  for(let i=0;i<100;i++){try{witness=JSON.parse((await readFile(join(root,'foreground.jsonl'),'utf8')).split('\n').find(x=>x.includes('"ready"')))}catch{}if(witness)break;await new Promise(r=>setTimeout(r,50))}
  assert.ok(witness);results.push({witness_pid:witness.pid})
  const baseline=ok(await call('status',{}));assert.notEqual(baseline.frontmost_pid,window.pid,'TextEdit must actually be in the background before testing')
  state=ok(await call('observe',{pid:window.pid,window_id:window.window_id,include_image:false}))
  state=ok(await call('key',{snapshot_id:state.snapshot_id,key:'super+a',include_image:false}));assert.equal(state.focus.target_took_focus,false)
  state=ok(await call('type',{snapshot_id:state.snapshot_id,text:'Independent 你好🙂\n',include_image:false}));assert.equal(state.focus.target_took_focus,false)
  state=ok(await call('key',{snapshot_id:state.snapshot_id,key:'super+s',include_image:false}))
  assert.equal(await readFile(file,'utf8'),'Independent 你好🙂\n')
  await call('key',{snapshot_id:state.snapshot_id,key:'super+w',include_image:false})
  console.log('PASS: TextEdit background Unicode input and Command-S saved exact temporary file content')
 }
}finally{for(const r of results)if(r.witness_pid)try{process.kill(r.witness_pid,'SIGTERM')}catch{};await writeFile(join(root,'report.json'),JSON.stringify({results,file},null,2));await driver.close();console.log('TextEdit evidence:',root)}
