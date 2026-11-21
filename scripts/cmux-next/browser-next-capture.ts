#!/usr/bin/env bun
// A recording of the served browser shell, ordinary device auth and a live agent.
// Prior art: #45114 web-device-demo.ts. No route fulfillment, socket gate or fixture.
import { readFileSync, mkdirSync, writeFileSync, statSync } from "node:fs"
import { resolve, join } from "node:path"
import { fileURLToPath, pathToFileURL } from "node:url"
import { randomBytes, createHash } from "node:crypto"
import { CaptureOracle } from "./browser-next-capture-oracle.ts"

export interface CaptureConfig {
  url: string
  websocketOrigin: string
  target: string
  shellSelector: string
  openSelectors: string[]
  paneFrame?: string
  composerSelector: string
  replySelector: string
  storageState?: string
  sourceHead: string
  daemonHead: string
  agent: "codex" | "claude"
}

export function validateConfig(c: CaptureConfig): void {
  if (!["http:", "https:"].includes(new URL(c.url).protocol)) throw new Error("url")
  const ws = new URL(c.websocketOrigin)
  if (!["ws:", "wss:"].includes(ws.protocol) || ws.username || ws.password || ws.search || ws.hash || ws.pathname !== "/") throw new Error("websocketOrigin")
  if (!/^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/.test(c.target)) throw new Error("target")
  for (const head of [c.sourceHead, c.daemonHead]) if (!/^[a-f0-9]{40}$/.test(head)) throw new Error("head")
  for (const selector of [c.shellSelector, c.composerSelector, c.replySelector]) if (typeof selector !== "string" || !selector.trim()) throw new Error("selector")
  if (!Array.isArray(c.openSelectors) || c.openSelectors.length > 8 || c.openSelectors.some(s => typeof s !== "string" || !s.trim())) throw new Error("openSelectors")
  if (!["claude", "codex"].includes(c.agent)) throw new Error("agent")
}

export async function boundedCleanup(operation: () => Promise<void>, timeoutMs: number): Promise<boolean> {
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([
      operation().then(() => true, () => false),
      new Promise<boolean>(resolve => { timer = setTimeout(() => resolve(false), timeoutMs) }),
    ])
  } catch { return false } finally { clearTimeout(timer) }
}

export async function capture(c: CaptureConfig, output: string) {
  validateConfig(c)
  // Fresh directory: a failed attempt cannot leave a prior passing result/video beside it.
  mkdirSync(output, { mode: 0o700 })
  const nonce = `browser-${randomBytes(8).toString("hex")}`
  const oracle = new CaptureOracle(c.target, nonce)
  const root = resolve(fileURLToPath(new URL("../..", import.meta.url)))
  const started = Date.now()
  const result: any = {
    schema: "cmux.browser-capture.v1", status: "pending", stage: "launch", sourceHead: c.sourceHead,
    daemonHead: c.daemonHead, agent: c.agent, target: c.target, nonce, helloBy: "browser",
    // Heads and harness are supplied by the operator's artifact receipt; wire evidence is separate.
    identitySource: "operator-artifact-receipt", pageErrors: 0, consoleErrors: 0, steps: [],
  }
  let browser: any, context: any, page: any, video: any
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    const { chromium } = await import(pathToFileURL(join(root, "webviews/node_modules/playwright/index.mjs")).href)
    const { useSystemChrome, refusePlaywrightOnMacs } = await import(pathToFileURL(join(root, "webviews/test/support/systemChrome.ts")).href)
    useSystemChrome(chromium)
    refusePlaywrightOnMacs([chromium])
    browser = await chromium.launch({ headless: true, timeout: 30_000 })
    context = await browser.newContext({
      viewport: { width: 1280, height: 800 }, colorScheme: "dark",
      recordVideo: { dir: output, size: { width: 1280, height: 800 } },
      ...(c.storageState ? { storageState: c.storageState } : {}),
    })
    page = await context.newPage()
    video = page.video()
    page.setDefaultTimeout(30_000)
    page.on("pageerror", () => result.pageErrors++)
    page.on("console", (event: any) => { if (event.type() === "error") result.consoleErrors++ })
    let socketId = 0
    page.on("websocket", (socket: any) => {
      if (new URL(socket.url()).origin !== new URL(c.websocketOrigin).origin) return
      const id = ++socketId
      socket.on("framesent", ({ payload }: any) => oracle.observe(id, "sent", payload))
      socket.on("framereceived", ({ payload }: any) => oracle.observe(id, "received", payload))
    })
    const shot = async (name: string) => {
      await page.screenshot({ path: join(output, `${name}.png`) })
      result.steps.push({ name, elapsedMs: Date.now() - started })
    }
    const flow = async () => {
      result.stage = "shell"
      await page.goto(c.url, { waitUntil: "domcontentloaded" })
      await page.locator(c.shellSelector).waitFor({ state: "visible" })
      await shot("01-shell")
      result.stage = "open-chat"
      for (const selector of c.openSelectors) await page.locator(selector).click()
      await oracle.wait(() => oracle.attachCount > 0, 60_000, "device-attach")
      const pane = () => c.paneFrame ? page.frameLocator(c.paneFrame) : page
      await shot("02-attached")
      result.stage = "prompt-reply"
      const composer = pane().locator(c.composerSelector)
      await composer.fill(`Reply with exactly this code: ${nonce}`)
      await composer.press("Enter")
      await oracle.wait(() => oracle.replySeen && oracle.completed, 90_000, "agent-reply")
      await pane().locator(c.replySelector).filter({ hasText: nonce }).last().waitFor({ state: "visible" })
      await shot("03-reply")
      result.stage = "reload"
      const attached = oracle.attachCount
      await page.reload({ waitUntil: "domcontentloaded" })
      await page.locator(c.shellSelector).waitFor({ state: "visible" })
      await oracle.wait(() => oracle.attachCount > attached, 60_000, "reload-attach")
      await pane().locator(c.replySelector).filter({ hasText: nonce }).last().waitFor({ state: "visible" })
      await shot("04-reloaded")
      if (result.pageErrors || result.consoleErrors) throw new Error("browser-errors")
    }
    await Promise.race([flow(), new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error("deadline")), 5 * 60_000)
    })])
    result.status = "pass"
    result.stage = "complete"
  } catch {
    // URLs, console strings and exceptions can carry credentials. Only report our named stage.
    result.status = "fail"
    if (page) await page.screenshot({ path: join(output, "failure.png"), timeout: 5_000 }).catch(() => {})
  } finally {
    clearTimeout(timer)
    const finalized = await boundedCleanup(async () => {
      await context?.close()
      if (video) {
        const destination = join(output, "demo.webm")
        await video.saveAs(destination)
        await video.delete()
        if (statSync(destination).size === 0) throw new Error("empty-video")
        result.videoSha256 = createHash("sha256").update(readFileSync(destination)).digest("hex")
      } else if (result.status === "pass") throw new Error("missing-video")
    }, 20_000)
    if (!finalized) { result.status = "fail"; result.stage = "finalize-video" }
    if (!await boundedCleanup(async () => { await browser?.close() }, 10_000)) {
      result.status = "fail"; result.stage = "close-browser"
    }
    Object.assign(result, oracle.summary(), { elapsedMs: Date.now() - started })
    writeFileSync(join(output, "result.json"), JSON.stringify(result, null, 2) + "\n", { mode: 0o600 })
  }
  return result
}

if (import.meta.main) {
  if (process.argv.length !== 4) {
    console.error("usage: bun scripts/cmux-next/browser-next-capture.ts PRIVATE_CONFIG_JSON NEW_OUTPUT_DIR")
    process.exit(2)
  }
  try {
    const result = await capture(JSON.parse(readFileSync(process.argv[2]!, "utf8")), resolve(process.argv[3]!))
    console.log(JSON.stringify(result))
    process.exit(result.status === "pass" ? 0 : 1)
  } catch {
    console.error("browser-next-capture: invalid config or output; next: follow docs/cmux-next/browser-capture.md")
    process.exit(2)
  }
}
