import { test, expect, type Page, type WebSocket as PWSocket } from "@playwright/test"

// ─── Helpers ───────────────────────────────────────────────────────────────

function surfaces(page: Page) {
  return page.locator("[data-testid^='surface-']")
}

function focusedSurface(page: Page) {
  return page.locator("[data-testid^='surface-'][data-focused='true']")
}

function groups(page: Page) {
  return page.locator("[data-testid^='group-s']")
}

function focusedGroup(page: Page) {
  return page.locator("[data-group-focused='true']")
}

function allTabs(page: Page) {
  return page.locator("[data-testid^='tab-s']")
}

function tabsInFocusedGroup(page: Page) {
  return focusedGroup(page).locator("[data-testid^='tab-s']")
}

function addTabBtn(page: Page) {
  return focusedGroup(page).locator("[data-testid^='add-tab-button-']")
}

function splitRight(page: Page) {
  return page.getByTestId("btn-split-right")
}

function splitDown(page: Page) {
  return page.getByTestId("btn-split-down")
}

function closeBtn(page: Page) {
  return page.getByTestId("btn-close-pane")
}

/** Track PTY WebSocket connections on the page. Call before navigation. */
function trackPtyWebSockets(page: Page) {
  const connections: PWSocket[] = []
  page.on("websocket", (ws) => {
    if (ws.url().includes("localhost:3778")) connections.push(ws)
  })
  return connections
}

/** Wait for the Nth PTY connection (1-indexed) to appear. */
async function waitForPtyConnection(connections: PWSocket[], n: number, timeout = 10000) {
  await expect.poll(() => connections.length, { timeout }).toBeGreaterThanOrEqual(n)
  return connections[n - 1]
}

/** Wait for PTY to be ready (shell prompt received). */
async function waitForPtyReady(ws: PWSocket, timeout = 5000) {
  let received = 0
  ws.on("framereceived", () => { received++ })
  await expect.poll(() => received, { timeout }).toBeGreaterThan(0)
}

/** Focus the terminal textarea in the focused surface so keyboard events reach it. */
async function focusTerminal(page: Page) {
  await focusedSurface(page).locator("textarea").focus()
}

/** Get the active tab ID in the focused group from the DOM. */
async function getActiveTabId(page: Page): Promise<string> {
  const testId = await focusedGroup(page)
    .locator("[data-testid^='tab-s'][data-active='true']")
    .getAttribute("data-testid")
  return testId!.replace("tab-", "")
}

/** Read the visible screen text of a terminal by its tab ID. */
async function getScreenText(page: Page, tabId: string): Promise<string> {
  return page.evaluate((id: string) => {
    const registry = (window as any).__surfaceRegistry
    if (!registry) return ""
    return registry.getScreenText(id)
  }, tabId)
}

/** Type a command, press Enter, and wait for the output marker to appear in the terminal. */
async function typeAndWaitForOutput(page: Page, tabId: string, command: string, marker: string, timeout = 5000) {
  await page.keyboard.type(command)
  await page.keyboard.press("Enter")
  await expect.poll(() => getScreenText(page, tabId), { timeout }).toContain(marker)
}

/**
 * Collect browser console warnings and errors. Call before navigation.
 *
 * ghostty-vt WASM routes ALL log output through console.log() regardless
 * of severity — the level is embedded in the text like "warning(osc): ...".
 * So we check both the message type AND the text content.
 */
function trackConsoleIssues(page: Page) {
  const issues: { type: string; text: string }[] = []
  page.on("console", (msg) => {
    const type = msg.type()
    const text = msg.text()
    // Native console.warn / console.error
    if (type === "warning" || type === "error") {
      issues.push({ type, text })
      return
    }
    // ghostty-vt WASM logs: console.log("[ghostty-vt] warning(...): ...")
    if (type === "log" && text.includes("[ghostty-vt]")) {
      if (/\bwarning\b/.test(text) || /\berror\b/.test(text)) {
        issues.push({ type: "wasm-" + (text.includes("warning") ? "warning" : "error"), text })
      }
    }
  })
  return issues
}

// ─── Tests ─────────────────────────────────────────────────────────────────

test.describe("Console health", () => {
  test("no warnings or errors after terminal loads", async ({ page }) => {
    const issues = trackConsoleIssues(page)
    const connections = trackPtyWebSockets(page)
    await page.goto("/terminal")
    await expect(surfaces(page).first()).toBeVisible()
    const ws = await waitForPtyConnection(connections, 1)
    await waitForPtyReady(ws)
    // Give time for shell startup sequences to be processed
    await page.waitForTimeout(2000)
    const real = issues.filter((i) => {
      if (i.text.includes("[HMR]")) return false
      if (i.text.includes("[Fast Refresh]")) return false
      return true
    })
    expect(real, `Unexpected console issues:\n${real.map((i) => `  [${i.type}] ${i.text}`).join("\n")}`).toHaveLength(0)
  })

  test("no warnings or errors after typing a command", async ({ page }) => {
    const issues = trackConsoleIssues(page)
    const connections = trackPtyWebSockets(page)
    await page.goto("/terminal")
    await expect(surfaces(page).first()).toBeVisible()
    const ws = await waitForPtyConnection(connections, 1)
    await waitForPtyReady(ws)
    const tabId = await getActiveTabId(page)
    await focusTerminal(page)
    await typeAndWaitForOutput(page, tabId, "echo CONSOLE_CHECK", "CONSOLE_CHECK")
    await page.waitForTimeout(1000)
    const real = issues.filter((i) => {
      if (i.text.includes("[HMR]")) return false
      if (i.text.includes("[Fast Refresh]")) return false
      return true
    })
    expect(real, `Unexpected console issues:\n${real.map((i) => `  [${i.type}] ${i.text}`).join("\n")}`).toHaveLength(0)
  })
})

test.describe("PTY server integration", () => {
  test("initial terminal connects to PTY server via WebSocket", async ({ page }) => {
    const connections = trackPtyWebSockets(page)
    await page.goto("/terminal")
    await expect(surfaces(page).first()).toBeVisible()
    const ws = await waitForPtyConnection(connections, 1)
    expect(ws.url()).toContain("/ws?cols=")
  })

  test("terminal surface renders canvas element", async ({ page }) => {
    await page.goto("/terminal")
    await expect(surfaces(page).first()).toBeVisible()
    await expect(surfaces(page).first().locator("canvas")).toBeVisible()
  })

  test("PTY server sends shell output through WebSocket", async ({ page }) => {
    const connections = trackPtyWebSockets(page)
    await page.goto("/terminal")
    await expect(surfaces(page).first()).toBeVisible()
    const ws = await waitForPtyConnection(connections, 1)
    await waitForPtyReady(ws)
  })

  test("split creates additional PTY connection", async ({ page }) => {
    const connections = trackPtyWebSockets(page)
    await page.goto("/terminal")
    await expect(surfaces(page).first()).toBeVisible()
    await waitForPtyConnection(connections, 1)

    await splitRight(page).click()
    await expect(groups(page)).toHaveCount(2)
    const ws = await waitForPtyConnection(connections, 2)
    expect(ws.url()).toContain("/ws?cols=")
  })

  test("keyboard input sends data through WebSocket to PTY", async ({ page }) => {
    const connections = trackPtyWebSockets(page)
    await page.goto("/terminal")
    await expect(surfaces(page).first()).toBeVisible()
    const ws = await waitForPtyConnection(connections, 1)
    await waitForPtyReady(ws)

    const sentFrames: string[] = []
    ws.on("framesent", (frame) => {
      sentFrames.push(String(frame.payload))
    })

    await focusTerminal(page)
    await page.keyboard.type("echo hello")
    await expect.poll(() => sentFrames.length).toBeGreaterThan(0)
  })

  test("new tab gets its own PTY session", async ({ page }) => {
    const connections = trackPtyWebSockets(page)
    await page.goto("/terminal")
    await expect(surfaces(page).first()).toBeVisible()
    await waitForPtyConnection(connections, 1)

    await addTabBtn(page).click()
    await expect(tabsInFocusedGroup(page)).toHaveCount(2)
    const ws = await waitForPtyConnection(connections, 2)
    expect(ws.url()).toContain("/ws?cols=")
  })

  test("closing pane does not affect other PTY sessions", async ({ page }) => {
    const connections = trackPtyWebSockets(page)
    await page.goto("/terminal")
    await expect(surfaces(page).first()).toBeVisible()
    await waitForPtyConnection(connections, 1)

    await splitRight(page).click()
    await expect(groups(page)).toHaveCount(2)
    await waitForPtyConnection(connections, 2)

    await closeBtn(page).click()
    await expect(groups(page)).toHaveCount(1)
    await expect(surfaces(page).first().locator("canvas")).toBeVisible()
  })
})

// ─── Terminal Content Tests ──────────────────────────────────────────────

test.describe("Terminal typing and output", () => {
  test("typing a command and pressing Enter shows output", async ({ page }) => {
    const connections = trackPtyWebSockets(page)
    await page.goto("/terminal")
    await expect(surfaces(page).first()).toBeVisible()
    const ws = await waitForPtyConnection(connections, 1)
    await waitForPtyReady(ws)

    const tabId = await getActiveTabId(page)
    await focusTerminal(page)
    await typeAndWaitForOutput(page, tabId, "echo HELLO_MARKER_42", "HELLO_MARKER_42")
  })

  test("command output appears in terminal buffer", async ({ page }) => {
    const connections = trackPtyWebSockets(page)
    await page.goto("/terminal")
    await expect(surfaces(page).first()).toBeVisible()
    const ws = await waitForPtyConnection(connections, 1)
    await waitForPtyReady(ws)

    const tabId = await getActiveTabId(page)
    await focusTerminal(page)

    // Run multiple commands and verify each output
    await typeAndWaitForOutput(page, tabId, "echo AAA_111", "AAA_111")
    await typeAndWaitForOutput(page, tabId, "echo BBB_222", "BBB_222")

    // Both should be in the screen
    const text = await getScreenText(page, tabId)
    expect(text).toContain("AAA_111")
    expect(text).toContain("BBB_222")
  })

  test("split panes have independent terminal sessions", async ({ page }) => {
    const connections = trackPtyWebSockets(page)
    await page.goto("/terminal")
    await expect(surfaces(page).first()).toBeVisible()
    const ws1 = await waitForPtyConnection(connections, 1)
    await waitForPtyReady(ws1)

    // Type in the first (left) pane
    const tab1Id = await getActiveTabId(page)
    await focusTerminal(page)
    await typeAndWaitForOutput(page, tab1Id, "echo LEFT_PANE_X1", "LEFT_PANE_X1")

    // Split right to create a second pane
    await splitRight(page).click()
    await expect(groups(page)).toHaveCount(2)
    const ws2 = await waitForPtyConnection(connections, 2)
    await waitForPtyReady(ws2)

    // Type in the second (right) pane — it has focus after split
    const tab2Id = await getActiveTabId(page)
    expect(tab2Id).not.toBe(tab1Id)
    await focusTerminal(page)
    await typeAndWaitForOutput(page, tab2Id, "echo RIGHT_PANE_Y2", "RIGHT_PANE_Y2")

    // Verify each pane has only its own output
    const leftText = await getScreenText(page, tab1Id)
    const rightText = await getScreenText(page, tab2Id)
    expect(leftText).toContain("LEFT_PANE_X1")
    expect(leftText).not.toContain("RIGHT_PANE_Y2")
    expect(rightText).toContain("RIGHT_PANE_Y2")
    expect(rightText).not.toContain("LEFT_PANE_X1")
  })

  test("split down panes have independent sessions", async ({ page }) => {
    const connections = trackPtyWebSockets(page)
    await page.goto("/terminal")
    await expect(surfaces(page).first()).toBeVisible()
    const ws1 = await waitForPtyConnection(connections, 1)
    await waitForPtyReady(ws1)

    const tab1Id = await getActiveTabId(page)
    await focusTerminal(page)
    await typeAndWaitForOutput(page, tab1Id, "echo TOP_PANE_A", "TOP_PANE_A")

    // Split down
    await splitDown(page).click()
    await expect(groups(page)).toHaveCount(2)
    const ws2 = await waitForPtyConnection(connections, 2)
    await waitForPtyReady(ws2)

    const tab2Id = await getActiveTabId(page)
    await focusTerminal(page)
    await typeAndWaitForOutput(page, tab2Id, "echo BOTTOM_PANE_B", "BOTTOM_PANE_B")

    const topText = await getScreenText(page, tab1Id)
    const bottomText = await getScreenText(page, tab2Id)
    expect(topText).toContain("TOP_PANE_A")
    expect(topText).not.toContain("BOTTOM_PANE_B")
    expect(bottomText).toContain("BOTTOM_PANE_B")
    expect(bottomText).not.toContain("TOP_PANE_A")
  })

  test("tab switching preserves terminal content", async ({ page }) => {
    const connections = trackPtyWebSockets(page)
    await page.goto("/terminal")
    await expect(surfaces(page).first()).toBeVisible()
    const ws1 = await waitForPtyConnection(connections, 1)
    await waitForPtyReady(ws1)

    // Type in tab 1
    const tab1Id = await getActiveTabId(page)
    await focusTerminal(page)
    await typeAndWaitForOutput(page, tab1Id, "echo TAB1_CONTENT_Z", "TAB1_CONTENT_Z")

    // Create a new tab (tab 2 becomes active)
    await addTabBtn(page).click()
    await expect(tabsInFocusedGroup(page)).toHaveCount(2)
    const ws2 = await waitForPtyConnection(connections, 2)
    await waitForPtyReady(ws2)

    const tab2Id = await getActiveTabId(page)
    expect(tab2Id).not.toBe(tab1Id)
    await focusTerminal(page)
    await typeAndWaitForOutput(page, tab2Id, "echo TAB2_CONTENT_W", "TAB2_CONTENT_W")

    // Switch back to tab 1 by clicking its tab
    const tab1El = focusedGroup(page).locator(`[data-testid="tab-${tab1Id}"]`)
    await tab1El.click()

    // Verify tab 1 still has its content preserved
    const tab1Text = await getScreenText(page, tab1Id)
    expect(tab1Text).toContain("TAB1_CONTENT_Z")
  })

  test("typing in a 3-pane split layout", async ({ page }) => {
    const connections = trackPtyWebSockets(page)
    await page.goto("/terminal")
    await expect(surfaces(page).first()).toBeVisible()
    const ws1 = await waitForPtyConnection(connections, 1)
    await waitForPtyReady(ws1)

    // Pane 1 (left)
    const pane1TabId = await getActiveTabId(page)
    await focusTerminal(page)
    await typeAndWaitForOutput(page, pane1TabId, "echo P1_MARK", "P1_MARK")

    // Split right → Pane 2 (right, focused)
    await splitRight(page).click()
    await expect(groups(page)).toHaveCount(2)
    const ws2 = await waitForPtyConnection(connections, 2)
    await waitForPtyReady(ws2)
    const pane2TabId = await getActiveTabId(page)
    await focusTerminal(page)
    await typeAndWaitForOutput(page, pane2TabId, "echo P2_MARK", "P2_MARK")

    // Split down on Pane 2 → Pane 3 (bottom-right, focused)
    await splitDown(page).click()
    await expect(groups(page)).toHaveCount(3)
    const ws3 = await waitForPtyConnection(connections, 3)
    await waitForPtyReady(ws3)
    const pane3TabId = await getActiveTabId(page)
    await focusTerminal(page)
    await typeAndWaitForOutput(page, pane3TabId, "echo P3_MARK", "P3_MARK")

    // Verify all 3 panes have independent content
    const p1 = await getScreenText(page, pane1TabId)
    const p2 = await getScreenText(page, pane2TabId)
    const p3 = await getScreenText(page, pane3TabId)
    expect(p1).toContain("P1_MARK")
    expect(p1).not.toContain("P2_MARK")
    expect(p2).toContain("P2_MARK")
    expect(p2).not.toContain("P3_MARK")
    expect(p3).toContain("P3_MARK")
    expect(p3).not.toContain("P1_MARK")
  })
})

// ─── Terminal Mouse Input Tests ─────────────────────────────────────────

test.describe("Terminal mouse input", () => {
  test("mouse click reaches TUI via SGR escape sequence", async ({ page }) => {
    const connections = trackPtyWebSockets(page)
    await page.goto("/terminal")
    await expect(surfaces(page).first()).toBeVisible()
    const ws = await waitForPtyConnection(connections, 1)
    await waitForPtyReady(ws)

    const tabId = await getActiveTabId(page)
    await focusTerminal(page)
    // Launch the mouse test fixture
    await typeAndWaitForOutput(page, tabId, "python3 e2e/fixtures/mouse-test.py", "MOUSE_READY")

    // Click on the terminal canvas
    const canvas = focusedSurface(page).locator("canvas")
    await canvas.click({ position: { x: 50, y: 50 } })

    // Verify the TUI received the mouse press event
    await expect.poll(() => getScreenText(page, tabId), { timeout: 5000 })
      .toMatch(/MOUSE_PRESS_btn0_col\d+_row\d+/)
  })

  test("mouse click position maps to correct cell coordinates", async ({ page }) => {
    const connections = trackPtyWebSockets(page)
    await page.goto("/terminal")
    await expect(surfaces(page).first()).toBeVisible()
    const ws = await waitForPtyConnection(connections, 1)
    await waitForPtyReady(ws)

    const tabId = await getActiveTabId(page)
    await focusTerminal(page)
    await typeAndWaitForOutput(page, tabId, "python3 e2e/fixtures/mouse-test.py", "MOUSE_READY")

    // Get cell dimensions from the renderer
    const cellDims = await page.evaluate((id: string) => {
      const reg = (window as any).__surfaceRegistry
      const entry = reg.get(id)
      const term = (entry?.adapter as any)?.terminal ?? entry?.terminal
      if (!term?.renderer) return { cw: 8, ch: 16 }
      return { cw: term.renderer.charWidth, ch: term.renderer.charHeight }
    }, tabId)

    // Click at cell (5, 3) — 0-indexed pixel target, SGR is 1-indexed so expect col=6, row=4
    const canvas = focusedSurface(page).locator("canvas")
    await canvas.click({
      position: {
        x: cellDims.cw * 5 + cellDims.cw / 2,
        y: cellDims.ch * 3 + cellDims.ch / 2,
      },
    })

    await expect.poll(() => getScreenText(page, tabId), { timeout: 5000 })
      .toContain("MOUSE_PRESS_btn0_col6_row4")
  })

  test("right-click sends button 2", async ({ page }) => {
    const connections = trackPtyWebSockets(page)
    await page.goto("/terminal")
    await expect(surfaces(page).first()).toBeVisible()
    const ws = await waitForPtyConnection(connections, 1)
    await waitForPtyReady(ws)

    const tabId = await getActiveTabId(page)
    await focusTerminal(page)
    await typeAndWaitForOutput(page, tabId, "python3 e2e/fixtures/mouse-test.py", "MOUSE_READY")

    const canvas = focusedSurface(page).locator("canvas")
    await canvas.click({ position: { x: 50, y: 50 }, button: "right" })

    await expect.poll(() => getScreenText(page, tabId), { timeout: 5000 })
      .toMatch(/MOUSE_PRESS_btn2_col\d+_row\d+/)
  })
})

// ─── Multiplexed Mode (mode=mux) Tests ────────────────────────────────

test.describe("Multiplexed cmuxd mode", () => {
  test("connects via single multiplexed WebSocket", async ({ page }) => {
    const connections = trackPtyWebSockets(page)
    await page.goto("/terminal?mode=mux")
    await expect(surfaces(page).first()).toBeVisible()
    // Should have exactly one WS connection (the mux connection)
    await expect.poll(() => connections.length, { timeout: 10000 }).toBe(1)
    expect(connections[0].url()).toContain("mode=mux")
  })

  test("typing a command shows output in mux mode", async ({ page }) => {
    const connections = trackPtyWebSockets(page)
    await page.goto("/terminal?mode=mux")
    await expect(surfaces(page).first()).toBeVisible()
    await waitForPtyConnection(connections, 1)

    // Wait for PTY output (shell prompt)
    const ws = connections[0]
    await waitForPtyReady(ws)

    const tabId = await getActiveTabId(page)
    await focusTerminal(page)
    await typeAndWaitForOutput(page, tabId, "echo MUX_HELLO_42", "MUX_HELLO_42")
  })

  test("split panes share one WebSocket in mux mode", async ({ page }) => {
    const connections = trackPtyWebSockets(page)
    await page.goto("/terminal?mode=mux")
    await expect(surfaces(page).first()).toBeVisible()
    await waitForPtyConnection(connections, 1)
    const ws = connections[0]
    await waitForPtyReady(ws)

    // Type in the first pane
    const tab1Id = await getActiveTabId(page)
    await focusTerminal(page)
    await typeAndWaitForOutput(page, tab1Id, "echo MUX_LEFT_99", "MUX_LEFT_99")

    // Split right — should NOT create a new WS connection
    await splitRight(page).click()
    await expect(groups(page)).toHaveCount(2)

    // Wait a bit to make sure no extra WS opens
    await page.waitForTimeout(500)
    expect(connections.length).toBe(1) // Still just the one mux connection

    // Type in the second pane
    const tab2Id = await getActiveTabId(page)
    expect(tab2Id).not.toBe(tab1Id)
    await focusTerminal(page)
    await typeAndWaitForOutput(page, tab2Id, "echo MUX_RIGHT_77", "MUX_RIGHT_77")

    // Verify panes have independent sessions
    const leftText = await getScreenText(page, tab1Id)
    const rightText = await getScreenText(page, tab2Id)
    expect(leftText).toContain("MUX_LEFT_99")
    expect(leftText).not.toContain("MUX_RIGHT_77")
    expect(rightText).toContain("MUX_RIGHT_77")
    expect(rightText).not.toContain("MUX_LEFT_99")
  })

  test("new tab reuses mux connection", async ({ page }) => {
    const connections = trackPtyWebSockets(page)
    await page.goto("/terminal?mode=mux")
    await expect(surfaces(page).first()).toBeVisible()
    await waitForPtyConnection(connections, 1)
    await waitForPtyReady(connections[0])

    // Create a new tab
    await addTabBtn(page).click()
    await expect(tabsInFocusedGroup(page)).toHaveCount(2)

    // Still just one WS connection
    await page.waitForTimeout(500)
    expect(connections.length).toBe(1)

    // Type in the new tab
    const tabId = await getActiveTabId(page)
    await focusTerminal(page)
    await typeAndWaitForOutput(page, tabId, "echo MUX_TAB2_55", "MUX_TAB2_55")
  })

  test("closing pane in mux mode keeps connection alive", async ({ page }) => {
    const connections = trackPtyWebSockets(page)
    await page.goto("/terminal?mode=mux")
    await expect(surfaces(page).first()).toBeVisible()
    await waitForPtyConnection(connections, 1)
    await waitForPtyReady(connections[0])

    // Type in the first pane so we know it works
    const tab1Id = await getActiveTabId(page)
    await focusTerminal(page)
    await typeAndWaitForOutput(page, tab1Id, "echo MUX_BEFORE_SPLIT", "MUX_BEFORE_SPLIT")

    // Verify the first pane's content before splitting
    const beforeSplit = await getScreenText(page, tab1Id)
    expect(beforeSplit).toContain("MUX_BEFORE_SPLIT")

    // Split, then close the new pane
    await splitRight(page).click()
    await expect(groups(page)).toHaveCount(2)
    // Wait for second session to be ready
    await page.waitForTimeout(800)

    await closeBtn(page).click()
    await expect(groups(page)).toHaveCount(1)

    // The mux connection should still be alive
    expect(connections.length).toBe(1)

    // The first pane should still have its content
    await expect.poll(() => getScreenText(page, tab1Id), { timeout: 3000 })
      .toContain("MUX_BEFORE_SPLIT")
  })

  test("workspace_snapshot includes terminalConfig from ghostty config", async ({ page }) => {
    await page.goto("/terminal?mode=mux")
    await expect(surfaces(page).first()).toBeVisible()

    const snapshot = await page.evaluate(() => {
      const conn = (window as any).__surfaceRegistry.getMuxConnection()
      return conn?._messages?.find((m: any) => m.type === "workspace_snapshot")
    })
    expect(snapshot).toBeTruthy()
    expect(snapshot.terminalConfig).toBeDefined()
    expect(snapshot.terminalConfig.fontSize).toBeGreaterThan(0)
    expect(snapshot.terminalConfig.theme).toBeDefined()
    expect(snapshot.terminalConfig.theme.background).toMatch(/^#[0-9a-fA-F]{6}$/)
  })
})

// ─── Multiplayer Tests ────────────────────────────────────────────────

test.describe("Multiplayer", () => {
  /** Create a raw second mux WS client and wait for it to be ready. */
  async function createRawClient(page: Page): Promise<void> {
    await page.evaluate(() => {
      return new Promise<void>((resolve) => {
        const ws = new WebSocket("ws://localhost:3778/ws?mode=mux&cols=80&rows=24")
        ws.binaryType = "arraybuffer"
        const c2: any = { ws, ready: false, attached: false, messages: [], clientId: null, binaryData: new Map() }
        ;(window as any).__client2 = c2
        ws.onmessage = (e: MessageEvent) => {
          if (typeof e.data === "string") {
            const msg = JSON.parse(e.data)
            c2.messages.push(msg)
            if (msg.type === "workspace_snapshot") {
              c2.ready = true
              c2.clientId = msg.clientId
              resolve()
            }
          } else {
            const buf = new Uint8Array(e.data as ArrayBuffer)
            if (buf.length >= 4) {
              const sid = buf[0] | (buf[1] << 8) | (buf[2] << 16) | (buf[3] << 24)
              const text = new TextDecoder().decode(buf.subarray(4))
              const existing = c2.binaryData.get(sid) || ""
              c2.binaryData.set(sid, existing + text)
            }
          }
        }
        setTimeout(() => resolve(), 5000)
      })
    })
  }

  /** Attach client 2 to a specific session. */
  async function client2Attach(page: Page, sessionId: number): Promise<void> {
    await page.evaluate(({ sid }) => {
      return new Promise<void>((resolve) => {
        const c2 = (window as any).__client2
        if (!c2?.ws || c2.ws.readyState !== WebSocket.OPEN) { resolve(); return }
        const orig = c2.ws.onmessage
        c2.ws.onmessage = (e: MessageEvent) => {
          orig(e)
          if (typeof e.data === "string") {
            const msg = JSON.parse(e.data)
            if (msg.type === "session_attached" && msg.sessionId === sid) {
              c2.attached = true
              resolve()
            }
          }
        }
        c2.ws.send(JSON.stringify({ type: "attach_session", sessionId: sid, cols: 80, rows: 24 }))
        setTimeout(() => resolve(), 5000)
      })
    }, { sid: sessionId })
  }

  /** Send binary input from client 2. */
  async function client2SendInput(page: Page, sessionId: number, text: string) {
    await page.evaluate(({ sid, text }) => {
      const c2 = (window as any).__client2
      if (!c2?.ws || c2.ws.readyState !== WebSocket.OPEN) return
      const encoded = new TextEncoder().encode(text)
      const buf = new Uint8Array(4 + encoded.length)
      buf[0] = sid & 0xFF; buf[1] = (sid >> 8) & 0xFF
      buf[2] = (sid >> 16) & 0xFF; buf[3] = (sid >> 24) & 0xFF
      buf.set(encoded, 4)
      c2.ws.send(buf)
    }, { sid: sessionId, text })
  }

  /** Read accumulated binary data that client 2 received for a session. */
  async function client2GetSessionData(page: Page, sessionId: number): Promise<string> {
    return page.evaluate(({ sid }) => {
      const c2 = (window as any).__client2
      return c2?.binaryData?.get(sid) || ""
    }, { sid: sessionId })
  }

  /** Close client 2. */
  async function closeRawClient(page: Page) {
    await page.evaluate(() => {
      const c2 = (window as any).__client2
      if (c2?.ws) c2.ws.close()
      delete (window as any).__client2
    })
  }

  /** Get session ID for the active tab in the focused group. */
  async function getMuxSessionId(page: Page, tabId: string): Promise<number> {
    return page.evaluate((id: string) => {
      return (window as any).__surfaceRegistry.getMuxSessionId(id)
    }, tabId)
  }

  test("second mux client triggers client_joined event", async ({ page }) => {
    const connections = trackPtyWebSockets(page)
    await page.goto("/terminal?mode=mux")
    await expect(surfaces(page).first()).toBeVisible()
    await waitForPtyConnection(connections, 1)
    await waitForPtyReady(connections[0])

    // Create second client
    await createRawClient(page)

    // Check client 1 received client_joined
    const hasJoined = await page.evaluate(() => {
      const conn = (window as any).__surfaceRegistry.getMuxConnection()
      return conn?._messages?.some((m: any) => m.type === "client_joined") ?? false
    })
    expect(hasJoined).toBe(true)

    await closeRawClient(page)
  })

  test("client_left fires when second client disconnects", async ({ page }) => {
    const connections = trackPtyWebSockets(page)
    await page.goto("/terminal?mode=mux")
    await expect(surfaces(page).first()).toBeVisible()
    await waitForPtyConnection(connections, 1)
    await waitForPtyReady(connections[0])

    await createRawClient(page)
    // Wait for client_joined to arrive first
    await expect.poll(async () => {
      return page.evaluate(() => {
        const conn = (window as any).__surfaceRegistry.getMuxConnection()
        return conn?._messages?.some((m: any) => m.type === "client_joined") ?? false
      })
    }).toBe(true)

    // Close client 2 and verify client_left arrives
    await closeRawClient(page)

    await expect.poll(async () => {
      return page.evaluate(() => {
        const conn = (window as any).__surfaceRegistry.getMuxConnection()
        return conn?._messages?.some((m: any) => m.type === "client_left") ?? false
      })
    }, { timeout: 3000 }).toBe(true)
  })

  test("second client attaches to session and receives live output", async ({ page }) => {
    const connections = trackPtyWebSockets(page)
    await page.goto("/terminal?mode=mux")
    await expect(surfaces(page).first()).toBeVisible()
    const ws = await waitForPtyConnection(connections, 1)
    await waitForPtyReady(ws)

    const tabId = await getActiveTabId(page)
    await focusTerminal(page)

    // Type something in session from client 1
    await typeAndWaitForOutput(page, tabId, "echo SHARED_MARKER_42", "SHARED_MARKER_42")

    // Get session ID
    const sessionId = await getMuxSessionId(page, tabId)
    expect(sessionId).toBeGreaterThan(0)

    // Create second client and attach to the same session
    await createRawClient(page)
    await client2Attach(page, sessionId)

    // Client 2 should have received VT snapshot with existing content
    await expect.poll(() => client2GetSessionData(page, sessionId), { timeout: 3000 })
      .toContain("SHARED_MARKER_42")

    // Now type from client 1 — client 2 should receive the new output
    await page.evaluate(({ sid }) => {
      const conn = (window as any).__surfaceRegistry.getMuxConnection()
      conn.sendInput(sid, "echo LIVE_OUTPUT_77\r")
    }, { sid: sessionId })

    await expect.poll(() => client2GetSessionData(page, sessionId), { timeout: 3000 })
      .toContain("LIVE_OUTPUT_77")

    await closeRawClient(page)
  })

  test("new client receives workspace layout and scrollback on connect", async ({ page }) => {
    const connections = trackPtyWebSockets(page)
    await page.goto("/terminal?mode=mux")
    await expect(surfaces(page).first()).toBeVisible()
    const ws = await waitForPtyConnection(connections, 1)
    await waitForPtyReady(ws)

    const tabId = await getActiveTabId(page)
    await focusTerminal(page)

    // Type unique markers in the first pane
    await typeAndWaitForOutput(page, tabId, "echo PANE1_SCROLLBACK", "PANE1_SCROLLBACK")

    // Split to create a second pane with its own session (shares same WS in mux mode)
    await splitRight(page).click()
    await expect(groups(page)).toHaveCount(2)
    // Wait for the second surface to be ready (mux mode reuses the same WS)
    await expect(surfaces(page)).toHaveCount(2)
    await page.waitForTimeout(1000) // let shell start in second pane

    const tabId2 = await getActiveTabId(page)
    await focusTerminal(page)
    await typeAndWaitForOutput(page, tabId2, "echo PANE2_SCROLLBACK", "PANE2_SCROLLBACK")

    // Get both session IDs
    const sessionId1 = await getMuxSessionId(page, tabId)
    const sessionId2 = await getMuxSessionId(page, tabId2)
    expect(sessionId1).toBeGreaterThan(0)
    expect(sessionId2).toBeGreaterThan(0)
    expect(sessionId1).not.toEqual(sessionId2)

    // Create a second client
    await createRawClient(page)

    // Client 2's initial workspace_snapshot should list both sessions
    const snapshot = await page.evaluate(() => {
      const c2 = (window as any).__client2
      return c2?.messages?.find((m: any) => m.type === "workspace_snapshot")
    })
    expect(snapshot).toBeTruthy()
    expect(snapshot.workspace).toBeTruthy()

    // Attach client 2 to session 1 and verify scrollback
    await client2Attach(page, sessionId1)
    await expect.poll(() => client2GetSessionData(page, sessionId1), { timeout: 3000 })
      .toContain("PANE1_SCROLLBACK")

    // Attach client 2 to session 2 and verify scrollback
    await page.evaluate(({ sid }) => {
      const c2 = (window as any).__client2
      c2.ws.send(JSON.stringify({ type: "attach_session", sessionId: sid, cols: 80, rows: 24 }))
    }, { sid: sessionId2 })
    await expect.poll(() => client2GetSessionData(page, sessionId2), { timeout: 3000 })
      .toContain("PANE2_SCROLLBACK")

    await closeRawClient(page)
  })

  test("single_driver mode blocks non-driver input", async ({ page }) => {
    const connections = trackPtyWebSockets(page)
    await page.goto("/terminal?mode=mux")
    await expect(surfaces(page).first()).toBeVisible()
    const ws = await waitForPtyConnection(connections, 1)
    await waitForPtyReady(ws)

    const tabId = await getActiveTabId(page)
    await focusTerminal(page)
    await typeAndWaitForOutput(page, tabId, "echo BEFORE_DRIVER_MODE", "BEFORE_DRIVER_MODE")

    const sessionId = await getMuxSessionId(page, tabId)

    // Create second client and attach
    await createRawClient(page)
    await client2Attach(page, sessionId)

    // Client 1 sets single_driver mode (client 1 becomes driver)
    await page.evaluate(({ sid }) => {
      const conn = (window as any).__surfaceRegistry.getMuxConnection()
      conn.setSessionMode(sid, "single_driver")
    }, { sid: sessionId })
    await page.waitForTimeout(300) // let server process

    // Client 2 tries to type (should be blocked since client 1 is driver)
    await client2SendInput(page, sessionId, "echo BLOCKED_INPUT\r")
    await page.waitForTimeout(1000) // give time for output if it were to appear

    // Client 1 types (should work as driver)
    await page.evaluate(({ sid }) => {
      const conn = (window as any).__surfaceRegistry.getMuxConnection()
      conn.sendInput(sid, "echo DRIVER_WORKS_OK\r")
    }, { sid: sessionId })
    await expect.poll(() => getScreenText(page, tabId), { timeout: 3000 })
      .toContain("DRIVER_WORKS_OK")

    // Verify non-driver input was blocked
    const screenText = await getScreenText(page, tabId)
    expect(screenText).not.toContain("BLOCKED_INPUT")

    await closeRawClient(page)
  })

  test("driver handoff via release and request", async ({ page }) => {
    const connections = trackPtyWebSockets(page)
    await page.goto("/terminal?mode=mux")
    await expect(surfaces(page).first()).toBeVisible()
    const ws = await waitForPtyConnection(connections, 1)
    await waitForPtyReady(ws)

    const tabId = await getActiveTabId(page)
    await focusTerminal(page)
    await typeAndWaitForOutput(page, tabId, "echo HANDOFF_START", "HANDOFF_START")

    const sessionId = await getMuxSessionId(page, tabId)

    // Create second client and attach
    await createRawClient(page)
    await client2Attach(page, sessionId)

    // Client 1 sets single_driver (becomes driver)
    await page.evaluate(({ sid }) => {
      const conn = (window as any).__surfaceRegistry.getMuxConnection()
      conn.setSessionMode(sid, "single_driver")
    }, { sid: sessionId })
    await page.waitForTimeout(300)

    // Client 1 releases driver
    await page.evaluate(({ sid }) => {
      const conn = (window as any).__surfaceRegistry.getMuxConnection()
      conn.releaseDriver(sid)
    }, { sid: sessionId })
    await page.waitForTimeout(300)

    // Client 2 requests driver
    await page.evaluate(({ sid }) => {
      const c2 = (window as any).__client2
      c2.ws.send(JSON.stringify({ type: "request_driver", sessionId: sid }))
    }, { sid: sessionId })
    await page.waitForTimeout(300)

    // Now client 2 should be able to type
    await client2SendInput(page, sessionId, "echo CLIENT2_IS_DRIVER\r")
    await expect.poll(() => getScreenText(page, tabId), { timeout: 3000 })
      .toContain("CLIENT2_IS_DRIVER")

    // Client 1 should now be blocked
    await page.evaluate(({ sid }) => {
      const conn = (window as any).__surfaceRegistry.getMuxConnection()
      conn.sendInput(sid, "echo CLIENT1_BLOCKED\r")
    }, { sid: sessionId })
    await page.waitForTimeout(1000)
    const text = await getScreenText(page, tabId)
    expect(text).not.toContain("CLIENT1_BLOCKED")

    await closeRawClient(page)
  })
})

// ─── Cmd+K Clear Screen Tests ─────────────────────────────────────────

test.describe("Cmd+K clear screen", () => {
  test("Cmd+K clears terminal content and redraws prompt", async ({ page }) => {
    const connections = trackPtyWebSockets(page)
    await page.goto("/terminal")
    await expect(surfaces(page).first()).toBeVisible()
    const ws = await waitForPtyConnection(connections, 1)
    await waitForPtyReady(ws)

    const tabId = await getActiveTabId(page)
    await focusTerminal(page)

    // Type a command with a unique marker so we can verify it's on screen
    await typeAndWaitForOutput(page, tabId, "echo BEFORE_CLEAR_MARKER_99", "BEFORE_CLEAR_MARKER_99")

    // Take screenshot before clear
    await page.screenshot({ path: "test-results/before-clear.png" })

    // Verify the marker is on screen
    const beforeText = await getScreenText(page, tabId)
    expect(beforeText).toContain("BEFORE_CLEAR_MARKER_99")

    // Press Cmd+K to clear (calls surfaceRegistry.clearTerminal via handleClear)
    await page.keyboard.press("Meta+k")
    await page.waitForTimeout(2000)

    // Take screenshot after clear
    await page.screenshot({ path: "test-results/after-clear.png" })

    // Verify the marker text is gone from the visible screen using screenshot pixel check:
    // After Cmd+K, the shell redraws the prompt via Ctrl+L sent to PTY.
    // The screen should show only the prompt (no BEFORE_CLEAR_MARKER_99).
    // We verify by checking getScreenText — after clear+redraw, the old content is gone.
    await expect.poll(() => getScreenText(page, tabId), { timeout: 3000 })
      .not.toContain("BEFORE_CLEAR_MARKER_99")
  })
})
