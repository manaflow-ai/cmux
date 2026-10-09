// Finds or launches a Chromium browser with a CDP endpoint.
// Order: explicit --cdp URL / CMUX_NEXT_CDP, an endpoint already listening on
// 127.0.0.1:9222, an installed Chrome/Chromium (launched with our profile),
// a Chrome for Testing build under ~/.cmux-next-host/chrome.

import { spawn } from "node:child_process";
import { existsSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { childEnv, ensureDir, findExecutable, packageBin, stateDir, type Logger } from "../../util.ts";


export async function fetchVersion(httpBase: string, timeoutMs = 2_000): Promise<{ webSocketDebuggerUrl: string; Browser?: string } | null> {
  try {
    const res = await fetch(`${httpBase.replace(/\/+$/, "")}/json/version`, { signal: AbortSignal.timeout(timeoutMs) });
    if (!res.ok) return null;
    const body = (await res.json()) as { webSocketDebuggerUrl?: string; Browser?: string };
    return body.webSocketDebuggerUrl ? (body as { webSocketDebuggerUrl: string; Browser?: string }) : null;
  } catch {
    return null;
  }
}

export function chromeDownloadDir(): string {
  return join(stateDir(), "chrome");
}

/** Installed Chromium-family browser binaries, best first. */
export function findChromeBinaries(): string[] {
  const home = homedir();
  const apps = [
    ["Google Chrome.app", "Google Chrome"],
    ["Chromium.app", "Chromium"],
    ["Google Chrome Canary.app", "Google Chrome Canary"],
    ["Google Chrome for Testing.app", "Google Chrome for Testing"],
    ["Brave Browser.app", "Brave Browser"],
    ["Microsoft Edge.app", "Microsoft Edge"],
  ];
  const out: string[] = [];
  if (process.env.CHROME_PATH && existsSync(process.env.CHROME_PATH)) out.push(process.env.CHROME_PATH);
  for (const root of ["/Applications", join(home, "Applications")]) {
    for (const [app, bin] of apps) {
      const p = join(root, app!, "Contents", "MacOS", bin!);
      if (existsSync(p)) out.push(p);
    }
  }
  for (const name of ["google-chrome", "chromium", "chromium-browser"]) {
    const p = findExecutable(name);
    if (p) out.push(p);
  }
  const downloaded = findDownloadedChrome();
  if (downloaded) out.push(downloaded);
  return out;
}

/** Chrome for Testing installed by @puppeteer/browsers under our state dir. */
export function findDownloadedChrome(dir = chromeDownloadDir()): string | null {
  if (!existsSync(dir)) return null;
  const stack = [dir];
  let depth = 0;
  while (stack.length > 0 && depth < 2000) {
    depth++;
    const d = stack.pop()!;
    let entries: string[];
    try {
      entries = readdirSync(d);
    } catch {
      continue;
    }
    for (const e of entries) {
      const p = join(d, e);
      if (e === "Google Chrome for Testing.app") {
        const bin = join(p, "Contents", "MacOS", "Google Chrome for Testing");
        if (existsSync(bin)) return bin;
      }
      if ((e === "chrome" || e === "chrome.exe") && statSafe(p)?.isFile()) return p;
      if (statSafe(p)?.isDirectory() && !e.endsWith(".framework")) stack.push(p);
    }
  }
  return null;
}

function statSafe(p: string) {
  try {
    return statSync(p);
  } catch {
    return null;
  }
}

/** Downloads Chrome for Testing (stable) with @puppeteer/browsers. */
export function downloadChrome(log: Logger): Promise<string | null> {
  const dir = ensureDir(chromeDownloadDir());

  log(`downloading Chrome for Testing into ${dir} (one time)`);
  return new Promise((resolve) => {
    // Pinned dependency (package-lock), run from node_modules: no npx.
    const child = spawn(process.execPath, [packageBin("@puppeteer/browsers"), "install", "chrome@stable", "--path", dir], {
      env: childEnv(),
      stdio: ["ignore", "pipe", "pipe"],
    });
    let out = "";
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (out += d));
    child.on("error", () => resolve(null));
    child.on("exit", (code) => {
      if (code !== 0) {
        log(`chrome download failed (${code}): ${out.trim().split("\n").slice(-3).join(" ")}`);
        resolve(null);
        return;
      }
      const m = /chrome@\S+\s+(\/.+)$/m.exec(out.trim());
      resolve(m && existsSync(m[1]!) ? m[1]! : findDownloadedChrome(dir));
    });
  });
}

export interface LaunchOptions {
  binary: string;
  /** 0 (default) lets Chrome pick a free port, read from DevToolsActivePort. */
  port?: number;
  headless?: boolean;
  profileDir?: string;
}

export function defaultProfileDir(): string {
  return join(stateDir(), "chrome-profile");
}

/**
 * The CDP endpoint of a Chrome this host launched on its own profile, if it
 * is still running. Chrome writes `<profile>/DevToolsActivePort` (port, then
 * the browser target path) once remote debugging is listening.
 */
export async function ownEndpoint(profileDir = defaultProfileDir()): Promise<string | null> {
  const file = join(profileDir, "DevToolsActivePort");
  if (!existsSync(file)) return null;
  const [portLine] = readFileSync(file, "utf8").split("\n");
  const port = Number(portLine);
  if (!Number.isInteger(port) || port <= 0 || port > 65535) return null;
  const base = `http://127.0.0.1:${port}`;
  return (await fetchVersion(base, 1_000)) ? base : null;
}

/**
 * Launches the browser detached (it outlives the host) on a random port and
 * waits for CDP. No --remote-allow-origins: the host's CDP client sends no
 * Origin, so web pages cannot drive the browser.
 */
export async function launchChrome(opts: LaunchOptions, log: Logger): Promise<string | null> {
  const port = opts.port ?? 0;
  const profile = ensureDir(opts.profileDir ?? defaultProfileDir());
  try {
    rmSync(join(profile, "DevToolsActivePort"), { force: true });
  } catch {}
  const args = [
    `--remote-debugging-port=${port}`,
    `--user-data-dir=${profile}`,
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-background-timer-throttling",
    "--disable-backgrounding-occluded-windows",
    "--disable-renderer-backgrounding",
    ...(opts.headless ? ["--headless=new"] : []),
    "about:blank",
  ];
  log(`launching ${opts.binary} with remote debugging on ${port === 0 ? "a random port" : `port ${port}`}`);
  const child = spawn(opts.binary, args, { detached: true, stdio: "ignore", env: childEnv() });
  child.on("error", (err) => log(`browser launch failed: ${err.message}`));
  child.unref();
  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    const base = await ownEndpoint(profile);
    if (base) return base;
    await new Promise((r) => setTimeout(r, 250));
  }
  log("browser did not expose CDP in time");
  return null;
}

export interface EndpointOptions {
  cdp?: string;
  launch?: boolean;
  headless?: boolean;
  download?: boolean;
  log: Logger;
}

/**
 * Returns the HTTP base of a CDP endpoint, or null. Only an explicit --cdp /
 * CMUX_NEXT_CDP endpoint or a Chrome this host launched (on its own profile)
 * is ever adopted; a browser that merely listens on a well-known port is not.
 */
export async function resolveCdpEndpoint(opts: EndpointOptions): Promise<string | null> {
  const explicit = opts.cdp ?? process.env.CMUX_NEXT_CDP;
  if (explicit) return (await fetchVersion(explicit)) ? explicit.replace(/\/+$/, "") : null;
  const own = await ownEndpoint();
  if (own) return own;
  if (opts.launch === false) return null;
  let binary: string | null = findChromeBinaries()[0] ?? null;
  if (!binary && opts.download) binary = await downloadChrome(opts.log);
  if (!binary) return null;
  return launchChrome({ binary, headless: opts.headless }, opts.log);
}
