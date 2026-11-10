const snapshot = { snapshot_id: { type: 'string', required: true, description: 'The latest snapshot_id returned to this agent by observe or a successful action.' } }
const element = { type: 'integer', description: 'Element number in that snapshot.' }
const coordinate = { type: 'number', description: 'Returned screenshot pixels, top-left origin.' }
const specs = [
  ['status', 'Read native permissions and background capabilities. Does not request permissions.', {}],
  ['apps', 'List running application windows, exact PIDs and window IDs without activating them.', {}],
  ['observe', 'Observe a running app in the background. Specify exact app bundle ID/name or PID, and window_id when needed. Returns a new snapshot and AX tree, optionally an image. Never raises or restores a window.', {
    app: { type: 'string' }, pid: { type: 'integer' }, window_id: { type: 'integer' }, include_image: { type: 'boolean' }, max_elements: { type: 'integer' },
  }],
  ['screenshot', 'Capture the observed window in the background and refresh its snapshot. Minimized/offscreen windows are refused without restoring them.', { ...snapshot }],
  ['click', 'Click a snapshot element, or x/y in its returned screenshot. Simple semantic AX actions are preferred; other clicks use window-targeted mouse events. Recheck the returned observation.', {
    ...snapshot, element, x: coordinate, y: coordinate, button: { type: 'string', enum: ['left', 'right'] }, count: { type: 'integer' },
  }],
  ['type', 'Send Unicode keyboard events to the target app, optionally focusing a text field element. Maximum 2000 UTF-16 units. Tool acceptance does not prove text insertion; inspect the returned AX value. Does not use the clipboard.', {
    ...snapshot, element, text: { type: 'string', required: true },
  }],
  ['key', 'Send a macOS shortcut to the observed app, such as super+a, Return, Left or ctrl+shift+z. No global keyboard posting.', {
    ...snapshot, key: { type: 'string', required: true },
  }],
  ['set_value', 'Set the complete AX value of an editable element. An alternative to keystrokes, with different application semantics; no clipboard. Secure fields are refused.', {
    ...snapshot, element: { ...element, required: true }, text: { type: 'string', required: true },
  }],
  ['scroll', 'Send pixel scrolling to a point or element in the observed window. Positive delta_y scrolls up and negative scrolls down.', {
    ...snapshot, element, x: coordinate, y: coordinate, delta_x: { type: 'integer' }, delta_y: { type: 'integer' },
  }],
  ['drag', 'Drag within the observed window. Coordinates use its returned screenshot pixels. Duration 50...5000 ms, default 350. Pointer movement is synthetic and directed to the app.', {
    ...snapshot, x: { ...coordinate, required: true }, y: { ...coordinate, required: true }, to_x: { ...coordinate, required: true }, to_y: { ...coordinate, required: true }, duration_ms: { type: 'integer' },
  }],
]
const inputs = new Set(['click', 'type', 'key', 'set_value', 'scroll', 'drag'])

export function createToolSpecs(ctx, driver, config = {}) {
  const states = new WeakMap()
  let tail = Promise.resolve()
  return specs.map(([method, description, parameters]) => ({
    name: `like_codex_${method}`,
    description,
    parameters,
    isConcurrencySafe: () => false,
    output: {
      schema: { type: 'object', additionalProperties: false, properties: {
        ok: { type: 'boolean', required: true }, result: { type: 'string', required: true },
        data: { type: 'json' }, image: { type: 'json' }, action_may_have_executed: { type: 'boolean' },
      } },
      render(_args, value) {
        const blocks = [{ type: 'text', text: value.result }]
        if (value.image) blocks.push({ type: 'image', attachment: value.image })
        return blocks
      },
    },
    execute(args, exec) {
      const run = async () => {
        const owner = exec?.agent
        if (!owner || (typeof owner !== 'object' && typeof owner !== 'function')) return { ok: false, result: 'Missing DSH agent identity.' }
        let state = states.get(owner)
        if (!state) { state = { snapshot: null, includeImage: config.includeImages ?? true, sx: 1, sy: 1 }; states.set(owner, state) }
        const isInput = inputs.has(method)
        let native
        try {
          exec.signal?.throwIfAborted()
          if (method !== 'observe' && method !== 'status' && method !== 'apps' && args.snapshot_id !== state.snapshot) {
            return { ok: false, result: 'Snapshot is not the latest observation for this agent. Call like_codex_observe.' }
          }
          const params = { ...args }
          if (method === 'observe') {
            params.include_image = args.include_image ?? config.includeImages ?? true
            params.max_elements = args.max_elements ?? config.maxElements ?? 250
            state.snapshot = null
          }
          if (isInput) {
            state.snapshot = null
            params.include_image = state.includeImage
            for (const key of ['x', 'to_x']) if (params[key] !== undefined) params[key] *= state.sx
            for (const key of ['y', 'to_y']) if (params[key] !== undefined) params[key] *= state.sy
          }
          native = await driver.call(method, params, { signal: exec.signal })
          if (!native.ok) return { ok: false, result: `${native.error.code}: ${native.error.message}\nRe-observe before any further input.`, data: native.focus ? { focus: native.focus } : {}, action_may_have_executed: native.action_may_have_executed ?? false }
          const data = native.data
          if (data.window && config.allowedApps?.length && !config.allowedApps.includes(data.window.bundle_id)) {
            state.snapshot = null
            return { ok: false, result: 'Target bundle ID is outside allowedApps.' }
          }
          const sourceImage = data.image
          delete data.image
          let image
          if (data.snapshot_id) { state.sx = 1; state.sy = 1 }
          if (sourceImage) {
            const ref = await ctx.attachments.saveImage({ data: Buffer.from(sourceImage.base64, 'base64'), mediaType: sourceImage.media_type, name: `background-${data.window.window_id}.png` })
            image = { ...ref, width: ref.width ?? sourceImage.width, height: ref.height ?? sourceImage.height }
            state.sx = sourceImage.width / image.width
            state.sy = sourceImage.height / image.height
            data.image_width = image.width; data.image_height = image.height
            data.window.source_pixel_scale = data.window.pixel_scale
            data.window.pixel_scale = image.width / data.window.bounds.width
            if (state.sx !== 1 || state.sy !== 1) {
              for (const e of data.elements) if (e.frame) for (const key of ['x', 'width']) e.frame[key] /= state.sx
              for (const e of data.elements) if (e.frame) for (const key of ['y', 'height']) e.frame[key] /= state.sy
            }
          }
          if (data.snapshot_id) {
            state.snapshot = data.snapshot_id
            state.includeImage = method === 'observe' ? params.include_image : sourceImage !== undefined
          }
          return { ok: true, result: JSON.stringify(data), data, ...(image ? { image } : {}) }
        } catch (error) {
          if (isInput || method === 'observe' || method === 'screenshot') state.snapshot = null
          return { ok: false, result: error.message, action_may_have_executed: error.actionMayHaveExecuted ?? (isInput && native?.ok === true) }
        }
      }
      const result = tail.then(run, run)
      tail = result.catch(() => {})
      return result
    },
  }))
}
