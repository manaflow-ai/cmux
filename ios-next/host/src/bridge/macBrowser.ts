// The cmux-next app's opt-in "Allow cmux on iPhone to view browser tabs"
// setting (cmux.json `browser.allowIPhoneAccess`, branch
// feat-cmux-next-cef-devtools-optin). The app writes
// `~/Library/Application Support/<bundle id>/devtools.json` (0600, atomic,
// removed on quit):
//   {version:1, enabled, state:"off"|"waitingForBrowser"|"ready"|"restartRequired",
//    pid, port?, startedAt?, targets?:[{tabId, targetId}]}
// `port` only when `state` is "ready". `targets` (when the app publishes it)
// maps the daemon's browser tabs to CEF DevTools target ids; it is the only
// way the host pairs a Mac pane with a target.
// The host adopts the endpoint only when the file is the user's own and not
// readable by others, the pid is a running cmux-next app, and the endpoint
// answers /json/version on 127.0.0.1.

import { execFile } from "node:child_process";
import { EventEmitter } from "node:events";
import { existsSync, readdirSync, readFileSync, statSync, watch, type FSWatcher } from "node:fs";
import { homedir, userInfo } from "node:os";
import { basename, dirname, join } from "node:path";
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

/**
 * devtools.json of the cmux-next app this host bridges. Explicit
 * CMUX_NEXT_DEVTOOLS_FILE wins; otherwise the newest
 * `~/Library/Application Support/com.cmuxterm.app*\/devtools.json`, preferring
 * the bundle whose id ends with the daemon session's tag.
 */
export function findDevtoolsFile(tag?: string | null): string {
  if (process.env.CMUX_NEXT_DEVTOOLS_FILE) return process.env.CMUX_NEXT_DEVTOOLS_FILE;
  const support = join(homedir(), "Library", "Application Support");
  // A tagged build's bundle id carries the tag with "-" and "_" as "."
  // (session cmux-app-nx-cefdt-v2 -> com.cmuxterm.app.debug.nx.cefdt.v2).
  const bundleTag = tag ? tag.replace(/[-_]/g, ".") : null;
  const fallback = join(support, bundleTag ? `com.cmuxterm.app.debug.${bundleTag}` : "com.cmuxterm.app", "devtools.json");
  let dirs: string[] = [];
  try {
    dirs = readdirSync(support).filter((d) => d.startsWith("com.cmuxterm.app"));
  } catch {
    return fallback;
  }
  const found = dirs
    .map((d) => join(support, d, "devtools.json"))
    .filter((f) => existsSync(f))
    .map((f) => ({ f, mtime: statSync(f).mtimeMs, tagged: Boolean(bundleTag && dirname(f).endsWith(`.${bundleTag}`)) }))
    .sort((a, b) => Number(b.tagged) - Number(a.tagged) || b.mtime - a.mtime);
  // A tagged bridge must not read another build's file.
  if (bundleTag) return found.find((x) => x.tagged)?.f ?? fallback;
  return found.find((x) => basename(dirname(x.f)) === "com.cmuxterm.app")?.f ?? fallback;
}

/** @deprecated kept for callers; same as findDevtoolsFile(). */
export function defaultDevtoolsFile(): string {
  return findDevtoolsFile();
}

export interface DevtoolsFile {
  version?: number;
  enabled?: boolean;
  state?: "off" | "waitingForBrowser" | "ready" | "restartRequired" | string;
  port?: number;
  pid?: number;
  startedAt?: number | string;
  /** Daemon browser tab -> CEF target (published by the app). */
  targets?: { tabId: string | number; targetId: string }[];
}

/** The .app bundle of a running cmux-next app (one that ships the cmux-tui daemon), or null. */
export function cmuxNextBundleOf(pid: number): Promise<string | null> {
  return new Promise((resolve) => {
    execFile("/bin/ps", ["-p", String(pid), "-o", "command="], { timeout: 10_000 }, (err, stdout) => {
      if (err) return resolve(null);
      const cmd = String(stdout).trim();
      const m = /^(.*?\.app)\/Contents\/MacOS\//.exec(cmd);
      resolve(m && existsSync(join(m[1]!, "Contents", "Resources", "bin", "cmux-tui")) ? m[1]! : null);
    });
  });
}

/** Is `pid` a running cmux-next app? */
export async function isCmuxNextPid(pid: number): Promise<boolean> {
  return (await cmuxNextBundleOf(pid)) !== null;
}

/**
 * Shows a browser tab in the cmux-next app's window ("Show on Mac"). The
 * daemon's select-tab moves the shared selection, but the app window keeps
 * its own selection; the app's bundled CLI (`cmux browser <tab_…> select`,
 * fixed argv, no shell) selects it in the window. Only the bundle of the
 * validated app pid is used.
 */
export async function selectTabInApp(pid: number, tabResourceId: string): Promise<void> {
  if (!/^tab_[0-9a-f]{16,64}$/.test(tabResourceId)) throw new Error("bad tab id");
  const bundle = await cmuxNextBundleOf(pid);
  if (!bundle) throw new Error("the cmux-next app is not running");
  const cli = join(bundle, "Contents", "Resources", "bin", "cmux");
  const env = { ...process.env };
  delete env.CMUX_SOCKET_PATH;
  await new Promise<void>((resolve, reject) =>
    execFile(cli, ["browser", tabResourceId, "select"], { timeout: 10_000, env }, (err) => (err ? reject(err) : resolve())),
  );
}

export interface MacBrowserOptions {
  /** devtools.json path, or a resolver re-run on every check (the app may move). */
  file?: string | (() => string);
  hostName: string;
  log?: Logger;
  /** Overridable for tests. */
  pidCheck?: (pid: number) => Promise<boolean>;
  pollMs?: number;
}

export class MacBrowser extends EventEmitter<{ status: [status: MacBrowserStatus]; targets: [] }> {
  private status: MacBrowserStatus;
  private endpointUrl: string | null = null;
  private watcher: FSWatcher | null = null;
  private timer: NodeJS.Timeout | null = null;
  private checking: Promise<void> | null = null;
  private readonly fileOf: () => string;
  private file: string;
  private targetMap = new Map<string, string>();
  private readonly log: Logger;

  constructor(private readonly opts: MacBrowserOptions) {
    super();
    this.fileOf = typeof opts.file === "function" ? opts.file : typeof opts.file === "string" ? () => opts.file as string : () => findDevtoolsFile();
    this.file = this.fileOf();
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

  /**
   * CEF target id for a daemon browser tab, from the app's published mapping.
   * Keys: surface number, "t<surface>" or the daemon's tab resource id.
   */
  targetFor(keys: (string | number | null | undefined)[]): string | undefined {
    if (this.status.state !== "on") return undefined;
    for (const k of keys) {
      if (k === null || k === undefined) continue;
      const hit = this.targetMap.get(String(k));
      if (hit) return hit;
    }
    return undefined;
  }

  /** Whether the app publishes a tab -> target mapping at all. */
  get publishesTargets(): boolean {
    return this.hasTargets;
  }
  private hasTargets = false;
  /** pid of the app that wrote the validated file (state "on"). */
  appPid: number | null = null;

  /** Shows a tab in the Mac app's window (see selectTabInApp). */
  async showInApp(tabResourceId: string): Promise<void> {
    if (this.status.state !== "on" || !this.appPid) throw new Error("Mac browser tab sharing is not on");
    await selectTabInApp(this.appPid, tabResourceId);
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
      const file = this.fileOf();
      if (file !== this.file) {
        this.file = file;
        this.watcher?.close();
        this.watcher = null;
      }
      this.checking = this.evaluate()
        .then(([status, endpoint, targets]) => {
          const targetsChanged = JSON.stringify([...targets]) !== JSON.stringify([...this.targetMap]);
          this.targetMap = targets;
          if (targetsChanged && status.state === "on") this.emit("targets");
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

  private async evaluate(): Promise<[MacBrowserStatus, string | null, Map<string, string>]> {
    const hostName = this.opts.hostName;
    const none = new Map<string, string>();
    const unavailable = (reason: string, extra: Partial<MacBrowserStatus> = {}): [MacBrowserStatus, null, Map<string, string>] => [{ state: "unavailable", reason, hostName, ...extra }, null, none];
    // Absent: an app build without the setting, or cmux-next not running
    // (the app removes the file on quit).
    if (!existsSync(this.file)) return [{ state: "unsupported", reason: "cmux-next is not running, or this build has no browser-tab sharing setting", hostName }, null, none];
    let st;
    try {
      st = statSync(this.file);
    } catch {
      return [{ state: "unsupported", hostName }, null, none];
    }
    if (st.uid !== userInfo().uid) return unavailable("devtools.json is not owned by this user");
    if ((st.mode & 0o077) !== 0) return unavailable("devtools.json is readable by other users");
    let data: DevtoolsFile;
    try {
      data = JSON.parse(readFileSync(this.file, "utf8")) as DevtoolsFile;
    } catch {
      return unavailable("devtools.json is not valid JSON");
    }
    if (!data || typeof data !== "object") return unavailable("devtools.json is not an object");
    this.hasTargets = Array.isArray(data.targets);
    const state = data.state ?? (data.enabled === false ? "off" : data.port ? "ready" : undefined);
    switch (state) {
      case "off":
        return [{ state: "off", hostName }, null, none];
      case "restartRequired":
        // The setting changed after Chromium started; never use an endpoint
        // found earlier. Off-and-restart vs on-and-restart differ only in the banner.
        return data.enabled === false
          ? [{ state: "off", restartRequired: true, reason: "restart cmux to close the endpoint", hostName }, null, none]
          : unavailable("restart cmux to start sharing browser tabs", { restartRequired: true });
      case "waitingForBrowser":
        return unavailable("open a browser tab on the Mac to start sharing");
      case "ready":
        break;
      default:
        return unavailable("devtools.json has an unknown state");
    }
    const port = data.port;
    const pid = data.pid;
    if (!Number.isInteger(port) || port! <= 0 || port! > 65535 || !Number.isInteger(pid) || pid! <= 0) return unavailable("devtools.json has no valid port and pid");
    if (!(await (this.opts.pidCheck ?? isCmuxNextPid)(pid!))) return unavailable("the cmux-next app that opened DevTools is not running");
    const base = `http://127.0.0.1:${port}`;
    if (!(await fetchVersion(base, 2_000))) return unavailable("the cmux-next DevTools endpoint is not answering");
    this.appPid = pid!;
    const targets = new Map<string, string>();
    for (const t of Array.isArray(data.targets) ? data.targets : []) {
      if (t && (typeof t.tabId === "string" || typeof t.tabId === "number") && typeof t.targetId === "string" && t.targetId) targets.set(String(t.tabId), t.targetId);
    }
    return [{ state: "on", hostName }, base, targets];
  }
}

/** Tab fields a Mac browser pane may carry (daemon list-workspaces). */
interface MacTab {
  surface: number;
  tab_resource_id?: string | null;
  browser_target_id?: string | null;
  cdp_target_id?: string | null;
}

/**
 * Pairs a Mac browser pane with its CEF target using only the mapping the app
 * publishes (devtools.json `targets`, or a target id in the daemon's tab
 * state). `openTargets` is the target list of the connected CEF endpoint
 * (null while not connected).
 */
export function macBrowserResolver(mac: MacBrowser, openTargets: () => string[] | null, visibleOf: (targetId: string) => boolean | undefined = () => undefined) {
  return (tab: MacTab): { refId: string; visible?: boolean } | { reason: string } => {
    const st = mac.current;
    if (st.state === "off") return { reason: `Turn on 'Allow cmux on iPhone to view browser tabs' in cmux Settings on ${st.hostName}${st.restartRequired ? ", then restart cmux" : ""}` };
    if (st.state === "unsupported") return { reason: "This cmux build cannot share browser tabs with the phone" };
    if (st.state !== "on") return { reason: st.reason ?? "Browser tab sharing is not available" };
    const target = mac.targetFor([tab.surface, `t${tab.surface}`, tab.tab_resource_id]) ?? tab.browser_target_id ?? tab.cdp_target_id ?? undefined;
    if (!target) return { reason: mac.publishesTargets ? "cmux has not linked this tab to a browser target yet" : "This cmux build does not say which browser target each tab is" };
    const open = openTargets();
    if (open && !open.includes(target)) return { reason: "This tab is not open in the Mac's browser" };
    const visible = visibleOf(target);
    return visible === undefined ? { refId: target } : { refId: target, visible };
  };
}
