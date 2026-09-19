import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { createServer } from 'node:http'
import { createInterface } from 'node:readline'
import { chromium } from 'playwright'
import { build } from 'esbuild'

const bundle = await build({ entryPoints: ['browser.js'], bundle: true, write: false, platform: 'browser' })
const server = createServer((req, res) => {
  res.setHeader('Content-Type', req.url === '/client.js' ? 'text/javascript' : 'text/html')
  res.end(req.url === '/client.js' ? bundle.outputFiles[0].text : '<!doctype html><script src="/client.js"></script>')
})
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
let browser, fixture
try {
  browser = await chromium.launch({ headless: true })
  const page = await browser.newPage()
  page.on('pageerror', error => console.error(error))
  await page.goto(`http://127.0.0.1:${server.address().port}`)
  const peer = await page.evaluate(() => window.prepare())
  fixture = spawn(process.env.CMUX_V3_FIXTURE ?? '../target/debug/examples/browser_fixture', [peer], { stdio: ['ignore', 'pipe', 'inherit'] })
  const config = await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('Rust fixture readiness timed out')), 20000)
    const lines = createInterface({ input: fixture.stdout })
    lines.once('line', line => { clearTimeout(timeout); lines.close(); try { resolve(JSON.parse(line)) } catch (error) { reject(error) } })
    fixture.once('error', error => { clearTimeout(timeout); reject(error) })
    fixture.once('exit', code => { clearTimeout(timeout); reject(new Error(`Rust fixture exited ${code}`)) })
  })
  const result = await page.evaluate(config => window.verify(config), config)
  assert.deepEqual(result, { allowed: { status: 'accepted', message: 'browser to Rust' }, denied: { status: 'denied' } })
  console.log('PASS: Chromium -> WebSocket -> Rust relay -> Noise -> Rust host; invalid grant rejected')
} finally {
  fixture?.kill('SIGTERM')
  await browser?.close()
  await new Promise(resolve => server.close(resolve))
}
