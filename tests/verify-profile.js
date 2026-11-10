import assert from 'node:assert/strict'
import { writeFile, readFile } from 'node:fs/promises'
export const name = 'dsh-like-codex-verification'
export const inject = ['tools', 'attachments']
export function apply(ctx) {
  queueMicrotask(async () => {
    try {
      const names=['status','apps','observe','screenshot','click','type','key','set_value','scroll','drag'].map(n=>'like_codex_'+n)
      for(const name of names) assert.ok(ctx.tools.get(name),'Missing registered tool '+name)
      const exec={agent:{},signal:new AbortController().signal}
      const status=await ctx.tools.get('like_codex_status').execute({},exec)
      assert.equal(status.ok,true,JSON.stringify(status))
      assert.equal(status.data.background_only,true)
      await assert.rejects(()=>ctx.tools.get('like_codex_type').execute({text:'missing snapshot'},exec))
      const data=await readFile(process.env.DSH_VERIFY_IMAGE)
      const image=await ctx.attachments.saveImage({data,mediaType:'image/png',name:'background-fixture.png'})
      assert.ok(image.attachmentId && image.width>0 && image.height>0)
      const rendered=ctx.tools.get('like_codex_screenshot').output.render({}, {ok:true,result:'fixture image',image})
      assert.equal(rendered[1].type,'image');assert.equal(rendered[1].attachment.attachmentId,image.attachmentId)
      await writeFile(process.env.DSH_VERIFY_OUTPUT,JSON.stringify({ok:true,tools:names,status:status.data,image},null,2))
      console.log('DSH_PLUGIN_VERIFICATION_PASS: '+names.length+' tools, real native status, schema rejection, real image attachment')
      process.exit(0)
    }catch(error){console.error(error);process.exit(1)}
  })
}
