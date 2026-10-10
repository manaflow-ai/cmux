// The cmux-next app's opt-in "Allow cmux on iPhone to view browser tabs"
// setting. When on, the app opens CEF's DevTools on a random loopback port and
// writes `~/Library/Application Support/cmux-next/devtools.json` (mode 0600):
//   {port, pid, startedAt}      the setting is on
//   {enabled:false}             the setting is off
//   (no file)                   an app build without the setting
// The host adopts the endpoint only when the file is the user's own and not
// readable by others, the pid is a running cmux-next app, and the endpoint
// answers /json/version on 127.0.0.1.

import { execFile } from "node:child_process";
import { EventEmitter } from "node:events";
import { existsSync, readFileSync, statSync, watch, type FSWatcher } from "node:fs";
import { homedir, userInfo } from "node:os";
import { dirname, join } from "node:path";
import type { Logger } from "../util.ts";
import { fetchVersion } from "../providers/browser/chrome.ts";

export type MacBrowserState = "on" | "off" | "unsupported" | "unavailable";

export interface MacBrowserStatus {
  state: MacBrowserState;
  reason?: string;
  /** The app must be restarted for a setting change to take effect. */
  restartRequired?: boolean;
  /** Mac name for the phone's banner. */
  hostName: string;
}

export function defaultDevtoolsFile(): string {
  return process.env.CMUX_NEXT_DEVTOOLS_FILE || join(homedir(), "Library", "Application Support", "cmux-next", "devtools.json");
}

export interface DevtoolsFile {
  port?: number;
  pid?: number;
  startedAt?: number | string;
  enabled?: boolean;
  restartRequired?: boolean;
}

/** Is `pid` a running cmux-next app (an .app whose bundle ships the cmux-tui daemon)? */
export function isCmuxNextPid(pid: number): Promise<boolean> {
  return new Promise((resolve) => {
    execFile("/bin/ps", ["-p", String(pid), "-o", "command="], { timeout: 10_000 }, (err, stdout) => {
      if (err) return resolve(false);
      const cmd = String(stdout).trim();
      const m = /^(.*?\.app)\/Contents\/MacOS\//.exec(cmd);
      resolve(Boolean(m && existsSync(join(m[1]!, "Contents", "Resources", "bin", "cmux-tui"))));
    });
  });
}

export interface MacBrowserOptions {
  file?: string;
  hostName: string;
  log?: Logger;
  /** Overridable for tests. */
  pidCheck?: (pid: number) => Promise<boolean>;
  pollMs?: number;
}

export class MacBrowser extends EventEmitter<{ status: [status: MacBrowserStatus] }> {
  private status: MacBrowserStatus;
  private endpointUrl: string | null = null;
  private watcher: FSWatcher | null = null;
  private timer: NodeJS.Timeout | null = null;
  private checking: Promise<void> | null = null;
  private readonly file: string;
  private readonly log: Logger;

  constructor(private readonly opts: MacBrowserOptions) {
    super();
    this.file = opts.file ?? defaultDevtoolsFile();
    this.log = opts.log ?? (() => {});
    this.status = { state: "unsupported", hostName: opts.hostName };
  }

  get current(): MacBrowserStatus {
    return { ...this.status };
  }

  /** The validated CDP base URL while the setting is on. */
  get endpoint(): string | null {
    return this.status.state === "on" ? this.endpointUrl : null;
  }

  start(): Promise<void> {
    this.watchDir();
    this.timer = setInterval(() => void this.check(), this.opts.pollMs ?? 5_000);
    this.timer.unref?.();
    return this.check();
  }

  stop(): void {
    this.watcher?.close();
    this.watcher = null;
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  private watchDir(): void {
    const dir = dirname(this.file);
    try {
      if (existsSync(dir)) {
        this.watcher = watch(dir, () => void this.check());
        this.watcher.on("error", () => {
          this.watcher?.close();
          this.watcher = null;
        });
      }
    } catch {
      this.watcher = null; // polling still covers it
    }
  }

  /** Re-reads the file and validates the endpoint; emits on change. */
  check(): Promise<void> {
    if (!this.checking) {
      this.checking = this.evaluate()
        .then(([status, endpoint]) => {
          if (!this.watcher) this.watchDir();
          const changed = JSON.stringify(status) !== JSON.stringify(this.status) || endpoint !== this.endpointUrl;
          this.status = status;
          this.endpointUrl = endpoint;
          if (changed) {
            this.log(`Mac browser tabs: ${status.state}${status.reason ? ` (${status.reason})` : ""}`);
            this.emit("status", this.current);
          }
        })
        .finally(() => {
          this.checking = null;
        });
    }
    return this.checking;
  }

  private async evaluate(): Promise<[MacBrowserStatus, string | null]> {
    const hostName = this.opts.hostName;
    const unavailable = (reason: string): [MacBrowserStatus, null] => [{ state: "unavailable", reason, hostName }, null];
    if (!existsSync(this.file)) return [{ state: "unsupported", reason: "this cmux-next build has no browser-tab sharing setting", hostName }, null];
    let st;
    try {
      st = statSync(this.file);
    } catch {
      return [{ state: "unsupported", hostName }, null];
    }
    if (st.uid !== userInfo().uid) return unavailable("devtools.json is not owned by this user");
    if ((st.mode & 0o077) !== 0) return unavailable("devtools.json is readable by other users");
    let data: DevtoolsFile;
    try {
      data = JSON.parse(readFileSync(this.file, "utf8")) as DevtoolsFile;
    } catch {
      return unavailable("devtools.json is not valid JSON");
    }
    const restartRequired = data.restartRequired === true ? { restartRequired: true } : {};
    if (data.enabled === false) return [{ state: "off", hostName, ...restartRequired }, null];
    const port = data.port;
    const pid = data.pid;
    if (!Number.isInteger(port) || port! <= 0 || port! > 65535 || !Number.isInteger(pid) || pid! <= 0) return unavailable("devtools.json has no valid port and pid");
    if (!(await (this.opts.pidCheck ?? isCmuxNextPid)(pid!))) return unavailable("the cmux-next app that opened DevTools is not running");
    const base = `http://127.0.0.1:${port}`;
    if (!(await fetchVersion(base, 2_000))) return unavailable("the cmux-next DevTools endpoint is not answering");
    return [{ state: "on", hostName, ...restartRequired }, base];
  }
}

/**
 * Pairs the Mac's browser panes (daemon tabs: url, title) with CEF page
 * targets (id, url, title). The daemon does not expose CEF target ids, so
 * tabs match by URL, then title, then order among identical candidates.
 */
export function matchTargets(
  tabs: { key: number; url?: string | null; title?: string | null }[],
  targets: { id: string; url: string; title: string }[],
): Map<number, string> {
  const out = new Map<number, string>();
  const free = [...targets];
  const take = (pred: (t: { id: string; url: string; title: string }) => boolean): string | undefined => {
    const i = free.findIndex(pred);
    if (i < 0) return undefined;
    return free.splice(i, 1)[0]!.id;
  };
  const norm = (u?: string | null) => (u ?? "").replace(/#.*$/, "").replace(/\/$/, "");
  // Exact URL and title first, then URL alone, then title alone.
  for (const pass of [0, 1, 2]) {
    for (const tab of tabs) {
      if (out.has(tab.key)) continue;
      const id =
        pass === 0
          ? take((t) => norm(t.url) === norm(tab.url) && !!tab.url && t.title === tab.title)
          : pass === 1
            ? take((t) => norm(t.url) === norm(tab.url) && !!tab.url)
            : take((t) => !!tab.title && t.title === tab.title);
      if (id) out.set(tab.key, id);
    }
  }
  return out;
}
