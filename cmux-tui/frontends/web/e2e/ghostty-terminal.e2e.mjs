// The ghostty-web terminal (?terminal=ghostty, RFD 0083 step 4) against a real
// daemon: it attaches, renders the shell, and a command typed into it echoes.
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "@playwright/test";

const bin = process.env.CMUX_TUI_BIN;
const pages = process.env.CMUX_TUI_PAGES_DIR;

function freePort() {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

let daemon;
let dir;
let origin;
let token;

test.beforeAll(async () => {
  test.skip(!bin || !pages, "set CMUX_TUI_BIN and CMUX_TUI_PAGES_DIR");
  expect(existsSync(join(pages, "web", "index.html")), "the page bundle is built").toBe(true);
  dir = mkdtempSync(join(tmpdir(), "cmux-ghostty-e2e-"));
  const sock = join(dir, "e2e.sock");
  const port = await freePort();
  daemon = spawn(bin, ["--session", "ghostty-e2e", "--socket", sock, "--headless", "--ws", `127.0.0.1:${port}`], {
    env: { ...process.env, CMUX_TUI_PAGES_DIR: pages, HOME: dir, XDG_STATE_HOME: join(dir, "state"), SHELL: "/bin/sh" },
    stdio: ["ignore", "inherit", "inherit"],
  });
  const credential = `${sock}.websocket.json`;
  for (let i = 0; i < 200 && !token; i++) {
    if (daemon.exitCode !== null) throw new Error(`daemon exited ${daemon.exitCode}`);
    try {
      token = JSON.parse(readFileSync(credential, "utf8")).token;
    } catch {
      await new Promise((r) => setTimeout(r, 100));
    }
  }
  expect(token, "the daemon minted its page credential").toBeTruthy();
  origin = `http://127.0.0.1:${port}`;
});

test.afterAll(async () => {
  if (daemon && daemon.exitCode === null) {
    daemon.kill("SIGTERM");
    await new Promise((r) => daemon.once("exit", r));
  }
  if (dir) rmSync(dir, { recursive: true, force: true });
});

const screen = (page) =>
  page.evaluate(() => document.querySelector(".ghostty-terminal-host")?.cmuxScreenText?.() ?? "");

test("a ghostty-web terminal renders the shell and echoes typed input", async ({ page }) => {
  const errors = [];
  page.on("pageerror", (error) => errors.push(String(error)));
  await page.goto(`${origin}/pages/web/?terminal=ghostty#token=${token}`);

  // An empty headless session: make its first workspace from the page.
  const host = page.locator(".ghostty-terminal-host[data-ready]");
  const newWorkspace = page.getByRole("button", { name: /new workspace/i }).first();
  await expect(host.or(newWorkspace).first()).toBeVisible({ timeout: 20_000 });
  if (!(await host.isVisible())) await newWorkspace.click();
  await expect(host).toBeVisible({ timeout: 20_000 });
  await expect(host.locator("canvas")).toBeVisible();
  await expect(page.locator(".render-grid")).toHaveCount(0);
  await expect.poll(() => screen(page), { timeout: 15_000 }).toMatch(/[$#%>]\s*$/m);

  await host.locator("canvas").click();
  await page.keyboard.type("echo hello-$((40+2))-ghostty");
  await page.keyboard.press("Enter");
  // The shell expands the arithmetic: the line can only come back from the PTY.
  await expect.poll(() => screen(page), { timeout: 15_000 }).toContain("hello-42-ghostty");
  await page.screenshot({ path: test.info().outputPath("ghostty-terminal.png") });
  expect(errors.filter((e) => !/favicon/i.test(e))).toEqual([]);
});
