import { spawn } from 'node:child_process'
import { createInterface } from 'node:readline'
import { fileURLToPath } from 'node:url'
import { isAbsolute } from 'node:path'

export class NativeDriver {
  constructor({ driverPath, timeoutMs = 30000 } = {}) {
    if (driverPath && !isAbsolute(driverPath)) throw new Error('driverPath must be an absolute path')
    if (!Number.isInteger(timeoutMs) || timeoutMs <= 0) throw new Error('timeoutMs must be a positive integer')
    this.path = driverPath || fileURLToPath(new URL(`../bin/darwin-${process.arch}/dsh-background-driver`, import.meta.url))
    this.timeoutMs = timeoutMs
    this.sequence = 0
    this.tail = Promise.resolve()
    this.child = null
    this.pending = null
    this.closed = false
  }

  call(method, params = {}, { signal } = {}) {
    const run = () => this.request(method, params, signal)
    const result = this.tail.then(run, run)
    this.tail = result.catch(() => {})
    return result
  }

  start() {
    if (this.child) return this.child
    if (this.closed) throw new Error('Native driver is closed')
    if (process.platform !== 'darwin') throw new Error('This plugin requires macOS 14.4 or later')
    const child = spawn(this.path, ['--stdio'], { stdio: ['pipe', 'pipe', 'pipe'], shell: false })
    this.child = child
    let stderr = ''
    child.stderr.on('data', data => { stderr = (stderr + data).slice(-4000) })
    const lines = createInterface({ input: child.stdout })
    lines.on('line', line => {
      let response
      try { response = JSON.parse(line) }
      catch { this.pending?.reject(new Error('Native driver returned invalid JSON')); return }
      if (this.pending?.id === response.id) this.pending.resolve(response)
    })
    child.on('error', error => this.pending?.reject(new Error(`Cannot start native driver: ${error.message}. Run npm run build on this Mac.`)))
    child.on('close', (code, signal) => {
      if (this.child === child) {
        this.child = null
        this.pending?.reject(new Error(`Native driver exited (${signal || code}). ${stderr}`))
      }
      lines.close()
    })
    return child
  }

  async request(method, params, signal) {
    if (this.stopping) await this.stopping
    signal?.throwIfAborted()
    const child = this.start()
    const id = ++this.sequence
    return new Promise((resolve, reject) => {
      let settled = false
      let stopping = false
      let cancellationError
      let cancellationTimer
      const finish = (callback, value) => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        clearTimeout(cancellationTimer)
        signal?.removeEventListener('abort', abort)
        if (this.pending?.id === id) this.pending = null
        callback(value)
      }
      const stop = message => {
        if (stopping) return
        stopping = true
        cancellationError = new Error(message)
        cancellationError.actionMayHaveExecuted = ['click', 'type', 'key', 'set_value', 'scroll', 'drag'].includes(method)
        child.kill('SIGUSR1')
        cancellationTimer = setTimeout(() => {
          this.stopping = new Promise(resolve => child.once('close', resolve))
          child.kill('SIGKILL')
          this.stopping.then(() => finish(reject, cancellationError))
        }, 3000)
        cancellationTimer.unref()
      }
      const abort = () => stop('Operation cancelled. Its result may be partial; observe before continuing.')
      const timer = setTimeout(() => stop('Native request timed out. Do not repeat an input action without observing its effect.'), this.timeoutMs)
      timer.unref()
      signal?.addEventListener('abort', abort, { once: true })
      this.pending = {
        id,
        resolve: value => { if (stopping) finish(reject, cancellationError); else finish(resolve, value) },
        reject: error => {
          if (stopping) { finish(reject, cancellationError); return }
          error.actionMayHaveExecuted = ['click', 'type', 'key', 'set_value', 'scroll', 'drag'].includes(method)
          finish(reject, error)
        },
      }
      child.stdin.write(JSON.stringify({ id, method, params }) + '\n', error => { if (error) finish(reject, error) })
    })
  }

  terminate(child) {
    this.stopping = new Promise(resolve => child.once('close', resolve))
    child.kill('SIGTERM')
    // Give the native driver time to balance mouse-up before a forced exit.
    const kill = setTimeout(() => { if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL') }, 3000)
    kill.unref()
    child.once('close', () => clearTimeout(kill))
  }

  close() {
    this.closed = true
    if (this.child) { this.child.stdin.end(); this.terminate(this.child) }
    return this.stopping ?? Promise.resolve()
  }
}
