// Finds or launches a Chromium browser with a CDP endpoint.
// Order: explicit --cdp URL / CMUX_NEXT_CDP, an endpoint already listening on
// 127.0.0.1:9222, an installed Chrome/Chromium (launched with our profile),
// a Chrome for Testing build under ~/.cmux-next-host/chrome.

import { spawn } from "node:child_process";
import { existsSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { childEnv, ensureDir, findExecutable, stateDir, type Logger } from "../../util.ts";

export const DEFAULT_CDP_PORT = 9222;

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
  const npx = findExecutable("npx") ?? "npx";
  log(`downloading Chrome for Testing into ${dir} (one time)`);
  return new Promise((resolve) => {
    const child = spawn(npx, ["-y", "@puppeteer/browsers", "install", "chrome@stable", "--path", dir], {
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
  port?: number;
  headless?: boolean;
  profileDir?: string;
}

/** Launches the browser detached (it outlives the host) and waits for CDP. */
export async function launchChrome(opts: LaunchOptions, log: Logger): Promise<string | null> {
  const port = opts.port ?? DEFAULT_CDP_PORT;
  const profile = ensureDir(opts.profileDir ?? join(stateDir(), "chrome-profile"));
  const args = [
    `--remote-debugging-port=${port}`,
    "--remote-allow-origins=*",
    `--user-data-dir=${profile}`,
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-background-timer-throttling",
    "--disable-backgrounding-occluded-windows",
    "--disable-renderer-backgrounding",
    ...(opts.headless ? ["--headless=new"] : []),
    "about:blank",
  ];
  log(`launching ${opts.binary} on CDP port ${port}`);
  const child = spawn(opts.binary, args, { detached: true, stdio: "ignore", env: childEnv() });
  child.on("error", (err) => log(`browser launch failed: ${err.message}`));
  child.unref();
  const base = `http://127.0.0.1:${port}`;
  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    if (await fetchVersion(base, 1_000)) return base;
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

/** Returns the HTTP base of a working CDP endpoint, or null. */
export async function resolveCdpEndpoint(opts: EndpointOptions): Promise<string | null> {
  const explicit = opts.cdp ?? process.env.CMUX_NEXT_CDP;
  if (explicit) return (await fetchVersion(explicit)) ? explicit.replace(/\/+$/, "") : null;
  const local = `http://127.0.0.1:${DEFAULT_CDP_PORT}`;
  if (await fetchVersion(local)) return local;
  if (opts.launch === false) return null;
  let binary: string | null = findChromeBinaries()[0] ?? null;
  if (!binary && opts.download) binary = await downloadChrome(opts.log);
  if (!binary) return null;
  return launchChrome({ binary, headless: opts.headless }, opts.log);
}
