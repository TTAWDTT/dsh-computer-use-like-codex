import { spawnSync } from 'node:child_process'
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { join } from 'node:path'
import { createHash } from 'node:crypto'
const root=fileURLToPath(new URL('../',import.meta.url))
if(process.platform!=='darwin')throw new Error('Native driver requires macOS')
const target=join(root,'bin',`darwin-${process.arch}`)
mkdirSync(target,{recursive:true})
function run(command,args){const r=spawnSync(command,args,{stdio:'inherit',cwd:root});if(r.status!==0)process.exit(r.status??1)}
run('xcrun',['clang','-target',`${process.arch==='arm64'?'arm64':'x86_64'}-apple-macosx14.4`,'-fblocks','-Wno-deprecated-declarations','-c','native/Bridge.c','-o',join(target,'Bridge.o')])
run('xcrun',['swiftc','-swift-version','5','-O','-target',`${process.arch==='arm64'?'arm64':'x86_64'}-apple-macosx14.4`,'-import-objc-header','native/Bridge.h',...readdirSync(join(root,'native')).filter(n=>n.endsWith('.swift')).map(n=>join('native',n)),join(target,'Bridge.o'),'-framework','AppKit','-framework','ApplicationServices','-framework','ScreenCaptureKit','-o',join(target,'dsh-background-driver')])
console.log(`Built ${target}/dsh-background-driver`)

const sha=p=>createHash('sha256').update(readFileSync(p)).digest('hex')
const sourceFiles=readdirSync(join(root,'native')).filter(n=>/\.(swift|c|h)$/.test(n)).sort()
writeFileSync(join(target,'build-info.json'),JSON.stringify({version:JSON.parse(readFileSync(join(root,'package.json'))).version,architecture:process.arch,min_macos:'14.4',binary_sha256:sha(join(target,'dsh-background-driver')),native_sources:Object.fromEntries(sourceFiles.map(n=>['native/'+n,sha(join(root,'native',n))]))},null,2)+'\n')
