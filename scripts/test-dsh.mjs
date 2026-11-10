import { spawnSync } from 'node:child_process'
import { mkdtemp, readFile, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import assert from 'node:assert/strict'
const root=fileURLToPath(new URL('../',import.meta.url))
const scratch=await mkdtemp(join(tmpdir(),'dsh-plugin-profile-'))
const env={...process.env,DSH_HOME:join(scratch,'home'),DSH_VERIFY_IMAGE:join(root,'tests/fixture.png'),DSH_VERIFY_OUTPUT:join(scratch,'verification.json')}
function run(command,args,cwd=root){const r=spawnSync(command,args,{cwd,env,encoding:'utf8',timeout:120000});if(r.status!==0)throw new Error(`${command} failed: ${r.stderr}\n${r.stdout}\n${r.error||''}`);return r.stdout}
run('dsh',['--profile','verify','--from-default-profile','headless','--dump-config'])
const archive=run('npm',['pack','--ignore-scripts','--pack-destination',scratch]).trim().split('\n').at(-1)
run('dsh',['plugin','--profile','verify','add',`file:${join(scratch,archive)}`,'--ignore-scripts',...(process.env.DSH_TEST_OFFLINE?['--offline']:[])])
const patch=[{id:'headless-runner',disabled:true},{id:'dsh-computer-use-like-codex',config:{includeImages:false}},{insert:[{id:'verify-background-plugin',name:join(root,'tests/verify-profile.js')}]}]
await writeFile(join(scratch,'verify.patch.json'),JSON.stringify(patch))
const output=run('dsh',['--profile','verify','--patch',join(scratch,'verify.patch.json'),'plugin verification only'])
assert.match(output,/DSH_PLUGIN_VERIFICATION_PASS/,'A zero exit without the verification marker is not a pass')
const result=JSON.parse(await readFile(env.DSH_VERIFY_OUTPUT,'utf8'))
assert.equal(result.ok,true);assert.equal(result.tools.length,10)
console.log(output.trim())
console.log('Isolated DSH profile evidence:',scratch)
