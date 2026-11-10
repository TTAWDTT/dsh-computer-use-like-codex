import z from '@deepseek-ai/schemastery'
import { defineTool } from '@deepseek-ai/dsh-tools'
import { NativeDriver } from './lib/driver.js'
import { createToolSpecs } from './lib/tools.js'

export const name = 'dsh-computer-use-like-codex'
export const inject = ['tools', 'attachments']
export const Config = z.object({
  driverPath: z.string().default(''),
  requestTimeoutMs: z.number().default(30000),
  includeImages: z.boolean().default(true),
  maxElements: z.number().default(250),
  allowedApps: z.array(z.string()).default([]),
})
export function apply(ctx, config) {
  const driver = new NativeDriver({ driverPath: config.driverPath, timeoutMs: config.requestTimeoutMs })
  for (const spec of createToolSpecs(ctx, driver, config)) ctx.tools.register(defineTool(spec))
  ctx.on('dispose', () => driver.close())
  ctx.logger?.info('dsh-computer-use-like-codex: registered 10 independent macOS background tools')
}
export default { name, inject, Config, apply }
