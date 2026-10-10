// Computer-visible browser tabs (PROTOCOL.md §4 browser): page targets of a
// Chromium browser on this Mac, driven over CDP. Attaching a tab emulates a
// mobile viewport and streams Page.startScreencast JPEG frames to the phone
// over the bulk lane with ack-based flow control.

import { EventEmitter } from "node:events";
import { FrameKind, type Tab } from "../../protocol.ts";
import { RpcError, type ClientSession, type RpcServer, encodeBrowserFramePayload, num, optStr, str } from "../../rpc/index.ts";
import type { Logger } from "../../util.ts";
import { CdpConnection } from "./cdp.ts";
import { fetchVersion, findChromeBinaries, ownEndpoint, resolveCdpEndpoint, retireUnsafeProfileChrome } from "./chrome.ts";

/** Frames the host keeps in flight before holding CDP acks (flow control). */
export const MAX_UNACKED = envNumber("CMUX_NEXT_SCREENCAST_UNACKED", 4);
/** JPEG quality of the screencast (one setting: restarting the screencast to change it costs frames). */
export const SCREENCAST_QUALITY = envNumber("CMUX_NEXT_SCREENCAST_QUALITY", 65);
/** Highest pixel density the screencast is encoded at (the page still renders at the phone's scale). */
export const SCREENCAST_MAX_SCALE = envNumber("CMUX_NEXT_SCREENCAST_MAX_SCALE", 3);

/** `CMUX_NEXT_BROWSER_TRACE=1`: log input and frame timing (latency investigations). */
const TRACE = process.env.CMUX_NEXT_BROWSER_TRACE === "1";

function envNumber(name: string, fallback: number): number {
  const v = Number(process.env[name]);
  return Number.isFinite(v) && v > 0 ? v : fallback;
}
/** Header flag on the format byte: an extended header follows (PROTOCOL.md §3). */
export const FRAME_META_FLAG = 0x80;
export const IPHONE_USER_AGENT =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1";
const SCROLL_BINDING = "__cmuxNextScroll";
const VISIBILITY_BINDING = "__cmuxNextVisibility";
const VISIBILITY_SCRIPT = `(() => {
  if (window.__cmuxNextVisibilityHooked) return;
  window.__cmuxNextVisibilityHooked = true;
  const post = () => { try { ${VISIBILITY_BINDING}(document.visibilityState); } catch {} };
  document.addEventListener("visibilitychange", post);
  post();
})()`;
/** Input that Chrome has not acknowledged by then is dropped (it blocks the phone's ordered input). */
const INPUT_TIMEOUT_MS = 3_000;
const SCROLL_SCRIPT = `(() => {
  if (window.__cmuxNextScrollHooked) return;
  window.__cmuxNextScrollHooked = true;
  let queued = false;
  const post = () => { queued = false; try { ${SCROLL_BINDING}(scrollX + "," + scrollY); } catch {} };
  addEventListener("scroll", () => { if (!queued) { queued = true; requestAnimationFrame(post); } }, { passive: true, capture: true });
  post();
})()`;

interface Cast {
  session: ClientSession;
  streamId: number;
  width: number;
  height: number;
  scale: number;
  /** Mobile emulation (iPhone user agent) vs desktop metrics. */
  mobile: boolean;
  /** Phone asked for the extended frame header with scroll offsets. */
  meta: boolean;
  seq: number;
  unacked: number[];
  pendingCdpAck: number | null;
  lastFrame?: Buffer;
  scrollScriptId?: string;
  visibilityScriptId?: string;
}

interface TabState {
  tab: Tab;
  sessionId?: string;
  attaching?: Promise<string>;
  cast?: Cast;
  refreshTimer?: NodeJS.Timeout;
  lastShot?: Buffer;
  /** Tail of the per-tab attach/detach/viewport chain. */
  chain?: Promise<unknown>;
  /** Latest document scroll offset reported by the page (CSS px). */
  scroll?: { x: number; y: number };
  /** User agent Chrome currently sends for this tab (our override). */
  uaOverride?: "mobile" | "desktop";
  /** User agent the current document was loaded with, when the host saw it load. */
  docMode?: "mobile" | "desktop";
  /** Created through browser.create (the phone opened it). */
  createdByHost?: boolean;
  /** Last document.visibilityState the page reported (cached; no per-input round trip). */
  hidden?: boolean;
  /** Tail of this tab's input chain: input reaches Chrome in arrival order. */
  inputChain?: Promise<unknown>;
}

/** Runs `fn` after every earlier attach/detach/viewport of the same tab. */
function serialized<T>(t: TabState, fn: () => Promise<T>): Promise<T> {
  const run = (t.chain ?? Promise.resolve()).catch(() => {}).then(fn);
  t.chain = run.catch(() => {});
  return run;
}

export interface BrowserProviderOptions {
  cdp?: string;
  launch?: boolean;
  headless?: boolean;
  download?: boolean;
  log?: Logger;
  /** Resolver override (tests). */
  resolveEndpoint?: () => Promise<string | null>;
}

export interface BrowserProviderEvents {
  event: [topic: string, payload: unknown];
}

export class BrowserProvider extends EventEmitter<BrowserProviderEvents> {
  private cdp: CdpConnection | null = null;
  private connecting: Promise<CdpConnection> | null = null;
  private readonly tabs = new Map<string, TabState>();
  private readonly bySession = new Map<string, TabState>();
  private readonly log: Logger;
  private endpoint: string | null = null;
  private lastActivated: string | null = null;
  private defaultUserAgent: string | null = null;
  /** The browser is the host's own Chrome profile (not an explicit --cdp / CMUX_NEXT_CDP). */
  private get ownsBrowser(): boolean {
    return !this.opts.cdp && !process.env.CMUX_NEXT_CDP && !this.opts.resolveEndpoint;
  }
  /** Tabs a phone closed that Chrome has not destroyed yet (kept out of the list). */
  private readonly closing = new Map<string, () => void>();
  /** Closed by a phone but never destroyed by Chrome; kept out of the list. */
  private readonly hiddenClosed = new Set<string>();

  private endpointSeen = false;

  constructor(private readonly opts: BrowserProviderOptions = {}) {
    super();
    this.log = opts.log ?? (() => {});
    // A browser this host launched earlier (still running) counts as capable.
    if (!opts.resolveEndpoint && !opts.cdp) {
      void retireUnsafeProfileChrome(this.log).then(() => ownEndpoint()).then((v) => {
        if (v) this.endpointSeen = true;
      });
    }
  }

  /** Whether a browser is (or can be made) available for browser.v1. */
  get capable(): boolean {
    if (this.cdp && !this.cdp.isClosed) return true;
    if (this.opts.cdp || process.env.CMUX_NEXT_CDP || this.endpointSeen) return true;
    if (this.opts.resolveEndpoint) return false;
    return this.opts.launch !== false && findChromeBinaries().length > 0;
  }

  get connected(): boolean {
    return Boolean(this.cdp && !this.cdp.isClosed);
  }

  /** Connects (launching the browser if needed). Safe to call repeatedly. */
  async connect(): Promise<CdpConnection> {
    if (this.cdp && !this.cdp.isClosed) return this.cdp;
    if (!this.connecting) {
      this.connecting = this.doConnect().finally(() => {
        this.connecting = null;
      });
    }
    return this.connecting;
  }

  private async doConnect(): Promise<CdpConnection> {
    const resolve =
      this.opts.resolveEndpoint ??
      (() => resolveCdpEndpoint({ cdp: this.opts.cdp, launch: this.opts.launch, headless: this.opts.headless, download: this.opts.download, log: this.log }));
    const endpoint = (this.endpoint && (await fetchVersion(this.endpoint)) ? this.endpoint : null) ?? (await resolve());
    if (!endpoint) throw new RpcError("unavailable", "no Chromium browser with remote debugging is available on this Mac");
    const version = await fetchVersion(endpoint);
    if (!version) throw new RpcError("unavailable", `CDP endpoint ${endpoint} is not responding`);
    this.endpoint = endpoint;
    this.endpointSeen = true;
    const ua = (version as { "User-Agent"?: unknown })["User-Agent"];
    this.defaultUserAgent = typeof ua === "string" ? ua : null;
    const cdp = await CdpConnection.connect(version.webSocketDebuggerUrl);
    this.cdp = cdp;
    this.log(`connected to ${version.Browser ?? "browser"} at ${endpoint}`);
    cdp.on("event", (method, params, sessionId) => this.onEvent(method, params, sessionId));
    cdp.on("close", () => this.onDisconnect(cdp));
    await cdp.send("Target.setDiscoverTargets", { discover: true });
    const { targetInfos } = await cdp.send<{ targetInfos: any[] }>("Target.getTargets");
    for (const info of targetInfos) this.upsertTarget(info);
    return cdp;
  }

  private onDisconnect(cdp: CdpConnection): void {
    if (this.cdp !== cdp) return;
    this.cdp = null;
    this.log("browser connection closed");
    for (const [id, t] of this.tabs) {
      if (t.cast) t.cast.session.removeStream(t.cast.streamId);
      this.emit("event", "browser.closed", { tabId: id });
    }
    this.tabs.clear();
    this.bySession.clear();
  }

  close(): void {
    this.cdp?.close();
  }

  // ---------------------------------------------------------------- tabs

  async list(): Promise<Tab[]> {
    await this.connect();
    return [...this.tabs.values()].map((t) => ({ ...t.tab }));
  }

  private get(tabId: string): TabState {
    const t = this.tabs.get(tabId);
    if (!t) throw new RpcError("not_found", `tab ${tabId} not found`);
    return t;
  }

  private async session(tabId: string): Promise<{ cdp: CdpConnection; t: TabState; sid: string }> {
    const cdp = await this.connect();
    const t = this.get(tabId);
    return { cdp, t, sid: await this.attachTarget(t) };
  }

  private isPage(info: any): boolean {
    return info.type === "page" && !String(info.url).startsWith("devtools://");
  }

  private upsertTarget(info: any): void {
    if (!this.isPage(info)) return;
    if (this.closing.has(info.targetId) || this.hiddenClosed.has(info.targetId)) return;
    let t = this.tabs.get(info.targetId);
    const isNew = !t;
    if (!t) {
      t = {
        tab: { id: info.targetId, url: info.url, title: info.title || info.url, loading: false, progress: 1, canGoBack: false, canGoForward: false, active: false },
      };
      this.tabs.set(info.targetId, t);
      if (!this.lastActivated) this.lastActivated = info.targetId;
      void this.attachTarget(t).catch((err) => this.log(`attach ${info.targetId} failed: ${err.message}`));
    }
    t.tab.url = info.url;
    t.tab.title = info.title || info.url;
    this.updateActive();
    this.emitTab(t, isNew);
  }

  private updateActive(): void {
    for (const t of this.tabs.values()) t.tab.active = t.tab.id === this.lastActivated;
  }

  private emitTab(t: TabState, _isNew = false): void {
    this.emit("event", "browser.tab", { tab: { ...t.tab } });
  }

  private attachTarget(t: TabState): Promise<string> {
    if (t.sessionId) return Promise.resolve(t.sessionId);
    if (!t.attaching) {
      t.attaching = (async () => {
        const cdp = await this.connect();
        const { sessionId } = await cdp.send<{ sessionId: string }>("Target.attachToTarget", { targetId: t.tab.id, flatten: true });
        t.sessionId = sessionId;
        this.bySession.set(sessionId, t);
        await Promise.all([
          cdp.send("Page.enable", {}, sessionId),
          cdp.send("Runtime.enable", {}, sessionId).catch(() => {}),
          cdp.send("Runtime.runIfWaitingForDebugger", {}, sessionId).catch(() => {}),
        ]);
        this.scheduleRefresh(t);
        return sessionId;
      })().finally(() => {
        t.attaching = undefined;
      });
    }
    return t.attaching;
  }

  private onEvent(method: string, params: any, sessionId?: string): void {
    switch (method) {
      case "Target.targetCreated":
      case "Target.targetInfoChanged":
        this.upsertTarget(params.targetInfo);
        return;
      case "Target.targetDestroyed":
        this.closing.get(params.targetId)?.();
        this.closing.delete(params.targetId);
        this.hiddenClosed.delete(params.targetId);
        this.removeTab(params.targetId);
        return;
      case "Target.detachedFromTarget": {
        const t = params.sessionId ? this.bySession.get(params.sessionId) : undefined;
        if (t) {
          this.bySession.delete(params.sessionId);
          t.sessionId = undefined;
        }
        return;
      }
    }
    const t = sessionId ? this.bySession.get(sessionId) : undefined;
    if (!t) return;
    switch (method) {
      case "Page.frameStartedLoading":
        if (!t.tab.loading) {
          t.tab.loading = true;
          t.tab.progress = 0.1;
          this.emitTab(t);
        }
        return;
      case "Page.domContentEventFired":
        t.tab.progress = Math.max(t.tab.progress, 0.7);
        this.emitTab(t);
        return;
      case "Page.frameStoppedLoading":
      case "Page.loadEventFired":
        if (t.tab.loading) {
          t.tab.loading = false;
          t.tab.progress = 1;
          this.emitTab(t);
        }
        this.scheduleRefresh(t);
        return;
      case "Page.frameNavigated":
        if (!params.frame?.parentId) {
          // The new document loaded with whatever user agent was in effect.
          t.docMode = t.uaOverride ?? "desktop";
          t.tab.url = params.frame.url + (params.frame.urlFragment ?? "");
          t.tab.progress = Math.max(t.tab.progress, 0.3);
          this.emitTab(t);
          this.scheduleRefresh(t);
        }
        return;
      case "Page.navigatedWithinDocument":
        t.tab.url = params.url;
        this.emitTab(t);
        this.scheduleRefresh(t);
        return;
      case "Page.screencastFrame":
        this.onScreencastFrame(t, params);
        return;
      case "Runtime.bindingCalled":
        if (params.name === VISIBILITY_BINDING && typeof params.payload === "string") {
          t.hidden = params.payload === "hidden";
          return;
        }
        if (params.name === SCROLL_BINDING && typeof params.payload === "string") {
          const [x, y] = params.payload.split(",").map(Number);
          if (Number.isFinite(x) && Number.isFinite(y)) t.scroll = { x: x!, y: y! };
        }
        return;
    }
  }

  private removeTab(targetId: string): void {
    const t = this.tabs.get(targetId);
    if (!t) return;
    if (t.cast) t.cast.session.removeStream(t.cast.streamId);
    if (t.sessionId) this.bySession.delete(t.sessionId);
    if (t.refreshTimer) clearTimeout(t.refreshTimer);
    this.tabs.delete(targetId);
    if (this.lastActivated === targetId) this.lastActivated = this.tabs.keys().next().value ?? null;
    this.updateActive();
    this.emit("event", "browser.closed", { tabId: targetId });
  }

  /** Debounced history/favicon refresh. */
  private scheduleRefresh(t: TabState): void {
    if (t.refreshTimer) clearTimeout(t.refreshTimer);
    t.refreshTimer = setTimeout(() => {
      t.refreshTimer = undefined;
      void this.refresh(t).catch(() => {});
    }, 120);
    t.refreshTimer.unref?.();
  }

  private async refresh(t: TabState): Promise<void> {
    const cdp = this.cdp;
    if (!cdp || !t.sessionId) return;
    const hist = await cdp.send<{ currentIndex: number; entries: any[] }>("Page.getNavigationHistory", {}, t.sessionId);
    t.tab.canGoBack = hist.currentIndex > 0;
    t.tab.canGoForward = hist.currentIndex < hist.entries.length - 1;
    const r = await cdp
      .send<{ result: { value?: { icon?: string; title?: string } } }>(
        "Runtime.evaluate",
        {
          expression:
            "(() => { const l = document.querySelector(\"link[rel~='icon']\"); return { icon: l ? l.href : (location.protocol.startsWith('http') ? location.origin + '/favicon.ico' : ''), title: document.title }; })()",
          returnByValue: true,
        },
        t.sessionId,
        3_000,
      )
      .catch(() => null);
    const icon = r?.result?.value?.icon;
    if (icon) t.tab.faviconUrl = icon;
    else delete t.tab.faviconUrl;
    if (r?.result?.value?.title) t.tab.title = r.result.value.title;
    this.emitTab(t);
  }

  async create(url?: string): Promise<Tab> {
    const cdp = await this.connect();
    const { targetId } = await cdp.send<{ targetId: string }>("Target.createTarget", { url: url ? normalizeUrl(url) : "about:blank" });
    const deadline = Date.now() + 3_000;
    while (!this.tabs.has(targetId) && Date.now() < deadline) await new Promise((r) => setTimeout(r, 25));
    if (!this.tabs.has(targetId)) {
      const { targetInfo } = await cdp.send<{ targetInfo: any }>("Target.getTargetInfo", { targetId });
      this.upsertTarget(targetInfo);
    }
    this.lastActivated = targetId;
    this.updateActive();
    const t = this.get(targetId);
    t.createdByHost = true;
    this.emitTab(t);
    return { ...t.tab };
  }

  async activate(tabId: string): Promise<void> {
    const cdp = await this.connect();
    this.get(tabId);
    await cdp.send("Target.activateTarget", { targetId: tabId });
    this.lastActivated = tabId;
    this.updateActive();
    for (const t of this.tabs.values()) this.emitTab(t);
  }

  async closeTab(tabId: string): Promise<void> {
    const cdp = await this.connect();
    // Listen for Target.targetDestroyed before asking, so a fast destroy is
    // not missed; drop the listener on failure or timeout.
    let resolveDestroyed: (gone: boolean) => void = () => {};
    const destroyed = new Promise<boolean>((resolve) => (resolveDestroyed = resolve));
    const timer = setTimeout(() => {
      this.closing.delete(tabId);
      resolveDestroyed(false);
    }, 2_000);
    timer.unref?.();
    // While registered, the tab is also kept out of the list (upsertTarget).
    this.closing.set(tabId, () => {
      clearTimeout(timer);
      resolveDestroyed(true);
    });
    // Close the Chrome target even when this host lost track of it (for
    // example after a reconnect raced the target list); only an unknown
    // target id is an error.
    let closed = false;
    try {
      const r = await cdp.send<{ success?: boolean }>("Target.closeTarget", { targetId: tabId });
      closed = r?.success !== false;
    } catch (err) {
      this.log(`browser.close ${tabId}: Target.closeTarget failed: ${(err as Error).message}`);
    }
    if (!closed && this.endpoint) {
      // Fallback: the DevTools HTTP endpoint closes any page target.
      const res = await fetch(`${this.endpoint}/json/close/${encodeURIComponent(tabId)}`).catch(() => null);
      closed = Boolean(res?.ok);
    }
    if (!closed) {
      clearTimeout(timer);
      this.closing.delete(tabId);
      if (!this.tabs.has(tabId)) throw new RpcError("not_found", `tab ${tabId} not found`);
      throw new RpcError("unavailable", `Chrome did not close tab ${tabId}`);
    }
    // Chrome reports success before the tab is gone and, with a stalled
    // browser UI (seen on a headless Mac), may never destroy it. The tab
    // leaves the phone's list either way.
    this.removeTab(tabId);
    if (!(await destroyed)) {
      this.hiddenClosed.add(tabId);
      this.log(`browser.close ${tabId}: Chrome acknowledged the close but the tab is still open; hiding it from phones`);
    }
  }

  // ---------------------------------------------------------------- screencast

  async attach(
    session: ClientSession,
    tabId: string,
    width: number,
    height: number,
    scale: number,
    mobile = true,
    meta = false,
    reloadForMode = false,
  ): Promise<{ streamId: number; tab: Tab }> {
    const { cdp, t, sid } = await this.session(tabId);
    // Attach/detach/viewport of one tab run one at a time, so two concurrent
    // attaches cannot both start a screencast and orphan a stream.
    return serialized(t, async () => {
      // One screencast per tab: a new attachment takes over. Tell the
      // displaced phone, and fully stop the old screencast first.
      const displaced = t.cast;
      if (displaced) {
        t.cast = undefined;
        displaced.session.removeStream(displaced.streamId);
        if (displaced.session.open) {
          displaced.session.sendEvent("browser.detached", { streamId: displaced.streamId, tabId, reason: "displaced" });
        }
        await this.stopCast(t, displaced);
      }
      if (!session.open) throw new RpcError("unavailable", "client disconnected");
      const cast: Cast = { session, streamId: 0, width, height, scale, mobile, meta, seq: 0, unacked: [], pendingCdpAck: null };
      cast.streamId = session.addStream({
        kind: "browser",
        target: tabId,
        dispose: () => {
          // Link closed or explicit detach: stop through the same chain.
          if (t.cast !== cast) return;
          t.cast = undefined;
          void serialized(t, () => this.stopCast(t, cast)).catch(() => {});
        },
      });
      t.cast = cast;
      await cdp.send("Target.activateTarget", { targetId: tabId }).catch(() => {});
      await cdp.send("Page.bringToFront", {}, sid).catch(() => {});
      this.lastActivated = tabId;
      this.updateActive();
      t.hidden = false;
      await this.applyViewport(cdp, sid, cast);
      const reload = await this.applyUserAgent(cdp, t, sid, cast.mobile, reloadForMode);
      await this.installVisibilityReporter(cdp, sid, cast);
      if (cast.meta) await this.installScrollReporter(cdp, sid, cast);
      await this.startCast(cdp, sid, cast);
      // A document loaded with the other user agent keeps its layout until
      // it reloads (desktop Wikipedia at 1120 CSS px on a phone).
      if (reload) {
        t.docMode = cast.mobile ? "mobile" : "desktop";
        await cdp.send("Page.reload", {}, sid).catch(() => {});
      }
      return { streamId: cast.streamId, tab: { ...t.tab } };
    });
  }

  /** Ends a screencast stream and waits until the tab's screencast is stopped. */
  async detach(session: ClientSession, streamId: number): Promise<void> {
    const sink = session.streams.get(streamId);
    if (!sink || sink.kind !== "browser") {
      session.removeStream(streamId);
      return;
    }
    const t = this.tabs.get(sink.target);
    session.removeStream(streamId); // dispose queues stopCast on the tab chain
    if (t?.chain) await t.chain;
  }

  private async applyViewport(cdp: CdpConnection, sid: string, cast: Pick<Cast, "width" | "height" | "scale" | "mobile">): Promise<void> {
    // The emulated viewport is exactly the CSS size the phone asked for, so
    // frame pixels map 1:1 onto the phone's view (no fit or letterboxing).
    const w = Math.max(1, Math.round(cast.width));
    const h = Math.max(1, Math.round(cast.height));
    await cdp.send(
      "Emulation.setDeviceMetricsOverride",
      { width: w, height: h, deviceScaleFactor: cast.scale, mobile: cast.mobile, screenWidth: w, screenHeight: h },
      sid,
    );
    await cdp.send("Emulation.setTouchEmulationEnabled", { enabled: true, maxTouchPoints: 5 }, sid).catch(() => {});
  }

  /**
   * Sets the iPhone (mobile) or the browser's own (desktop) user agent and
   * returns whether the loaded document should reload to pick it up. It
   * reloads only when the phone asked for it (Request Mobile/Desktop
   * Website), or for a tab the phone created whose document the host saw
   * load with the other user agent. Other tabs keep their state (forms, SPA
   * state, scroll) and get the new user agent on their next navigation.
   */
  private async applyUserAgent(cdp: CdpConnection, t: TabState, sid: string, mobile: boolean, explicit: boolean): Promise<boolean> {
    const mode = mobile ? "mobile" : "desktop";
    if (mobile) {
      await cdp
        .send(
          "Emulation.setUserAgentOverride",
          {
            userAgent: IPHONE_USER_AGENT,
            platform: "iPhone",
            userAgentMetadata: { brands: [], fullVersionList: [], platform: "iOS", platformVersion: "18.5", architecture: "", model: "iPhone", mobile: true },
          },
          sid,
        )
        .catch(() => {});
    } else {
      await this.restoreUserAgent(cdp, sid);
    }
    t.uaOverride = mode;
    if (!/^https?:/i.test(t.tab.url)) return false;
    const loadedWith = t.docMode;
    if (loadedWith === mode) return false;
    return explicit || (t.createdByHost === true && loadedWith !== undefined);
  }

  private async restoreUserAgent(cdp: CdpConnection, sid: string): Promise<void> {
    await cdp.send("Emulation.setUserAgentOverride", { userAgent: this.defaultUserAgent ?? "" }, sid).catch(() => {});
  }

  /** Reports document.visibilityState changes (cached for input; see ensureVisible). */
  private async installVisibilityReporter(cdp: CdpConnection, sid: string, cast: Cast): Promise<void> {
    await cdp.send("Runtime.addBinding", { name: VISIBILITY_BINDING }, sid).catch(() => {});
    const r = await cdp
      .send<{ identifier?: string }>("Page.addScriptToEvaluateOnNewDocument", { source: VISIBILITY_SCRIPT }, sid)
      .catch(() => null);
    cast.visibilityScriptId = r?.identifier;
    await cdp.send("Runtime.evaluate", { expression: VISIBILITY_SCRIPT }, sid).catch(() => {});
  }

  /** Reports document scroll offsets through a binding (frame header metadata). */
  private async installScrollReporter(cdp: CdpConnection, sid: string, cast: Cast): Promise<void> {
    await cdp.send("Runtime.addBinding", { name: SCROLL_BINDING }, sid).catch(() => {});
    const r = await cdp
      .send<{ identifier?: string }>("Page.addScriptToEvaluateOnNewDocument", { source: SCROLL_SCRIPT }, sid)
      .catch(() => null);
    cast.scrollScriptId = r?.identifier;
    await cdp.send("Runtime.evaluate", { expression: SCROLL_SCRIPT }, sid).catch(() => {});
  }

  private async startCast(cdp: CdpConnection, sid: string, cast: Cast): Promise<void> {
    // maxWidth/maxHeight are the phone's pixel size, so Chrome renders the
    // viewport at the phone's scale without downscaling.
    await cdp.send(
      "Page.startScreencast",
      {
        format: "jpeg",
        quality: SCREENCAST_QUALITY,
        maxWidth: Math.round(cast.width * Math.min(cast.scale, SCREENCAST_MAX_SCALE)),
        maxHeight: Math.round(cast.height * Math.min(cast.scale, SCREENCAST_MAX_SCALE)),
        everyNthFrame: 1,
      },
      sid,
    );
  }

  private async stopCast(t: TabState, cast?: Cast): Promise<void> {
    const cdp = this.cdp;
    const sid = t.sessionId;
    if (!cdp || !sid) return;
    await cdp.send("Page.stopScreencast", {}, sid).catch(() => {});
    if (cast?.scrollScriptId) await cdp.send("Page.removeScriptToEvaluateOnNewDocument", { identifier: cast.scrollScriptId }, sid).catch(() => {});
    if (cast?.meta) await cdp.send("Runtime.removeBinding", { name: SCROLL_BINDING }, sid).catch(() => {});
    if (cast?.visibilityScriptId) await cdp.send("Page.removeScriptToEvaluateOnNewDocument", { identifier: cast.visibilityScriptId }, sid).catch(() => {});
    await cdp.send("Runtime.removeBinding", { name: VISIBILITY_BINDING }, sid).catch(() => {});
    t.hidden = undefined;
    // New navigations on the Mac use its desktop user agent again. The loaded
    // document keeps the mode it was loaded with (docMode is not reset), so
    // the next attach does not reload it needlessly.
    if (t.uaOverride === "mobile") await this.restoreUserAgent(cdp, sid);
    t.uaOverride = "desktop";
    await cdp.send("Emulation.clearDeviceMetricsOverride", {}, sid).catch(() => {});
    await cdp.send("Emulation.setTouchEmulationEnabled", { enabled: false }, sid).catch(() => {});
  }

  private onScreencastFrame(
    t: TabState,
    params: { data: string; metadata: { deviceWidth: number; deviceHeight: number; pageScaleFactor?: number; offsetTop?: number }; sessionId: number },
  ): void {
    const cast = t.cast;
    const cdp = this.cdp;
    if (!cdp || !t.sessionId) return;
    if (!cast || !cast.session.open) {
      void cdp.send("Page.screencastFrameAck", { sessionId: params.sessionId }, t.sessionId).catch(() => {});
      return;
    }
    const image = Buffer.from(params.data, "base64");
    const dims = jpegSize(image);
    cast.seq = (cast.seq + 1) >>> 0;
    const header = {
      seq: cast.seq,
      cssW: params.metadata.deviceWidth || cast.width,
      cssH: params.metadata.deviceHeight || cast.height,
      pxW: dims?.width ?? Math.round(cast.width * cast.scale),
      pxH: dims?.height ?? Math.round(cast.height * cast.scale),
      format: 0 as const,
    };
    const payload = cast.meta
      ? encodeBrowserFrameMeta(header, { scrollX: t.scroll?.x ?? 0, scrollY: t.scroll?.y ?? 0, pageScale: params.metadata.pageScaleFactor ?? 1, offsetTop: params.metadata.offsetTop ?? 0 }, image)
      : encodeBrowserFramePayload(header, image);
    cast.lastFrame = image;
    t.lastShot = image;
    cast.session.sendFrame(FrameKind.browserFrame, cast.streamId, payload);
    if (TRACE) this.log(`trace frame seq=${cast.seq} ${payload.byteLength}B unacked=${cast.unacked.length + 1} scrollY=${t.scroll?.y ?? -1}`);
    cast.unacked.push(cast.seq);
    // CDP sends the next frame only after an ack. Ack right away while the
    // phone has room, otherwise hold the ack until the phone catches up.
    if (cast.unacked.length < MAX_UNACKED) {
      void cdp.send("Page.screencastFrameAck", { sessionId: params.sessionId }, t.sessionId).catch(() => {});
    } else {
      cast.pendingCdpAck = params.sessionId;
    }
  }

  ack(session: ClientSession, streamId: number, seq: number): void {
    for (const t of this.tabs.values()) {
      const cast = t.cast;
      if (!cast || cast.session !== session || cast.streamId !== streamId) continue;
      cast.unacked = cast.unacked.filter((s) => s > seq);
      if (cast.pendingCdpAck !== null && cast.unacked.length < MAX_UNACKED && this.cdp && t.sessionId) {
        const frameId = cast.pendingCdpAck;
        cast.pendingCdpAck = null;
        void this.cdp.send("Page.screencastFrameAck", { sessionId: frameId }, t.sessionId).catch(() => {});
      }
      return;
    }
    throw new RpcError("not_found", `stream ${streamId} not found`);
  }

  async viewport(tabId: string, width: number, height: number, scale: number): Promise<void> {
    const { cdp, t, sid } = await this.session(tabId);
    return serialized(t, () => this.applyViewportChange(cdp, t, sid, width, height, scale));
  }

  private async applyViewportChange(cdp: CdpConnection, t: TabState, sid: string, width: number, height: number, scale: number): Promise<void> {
    const cast = t.cast;
    if (!cast) {
      await this.applyViewport(cdp, sid, { width, height, scale, mobile: t.uaOverride !== "desktop" });
      return;
    }
    cast.width = width;
    cast.height = height;
    cast.scale = scale;
    await this.applyViewport(cdp, sid, cast);
    await cdp.send("Page.stopScreencast", {}, sid).catch(() => {});
    cast.unacked = [];
    cast.pendingCdpAck = null;
    await this.startCast(cdp, sid, cast);
  }

  // ---------------------------------------------------------------- navigation and input

  async navigate(tabId: string, url: string): Promise<void> {
    const { cdp, sid } = await this.session(tabId);
    await cdp.send("Page.navigate", { url: normalizeUrl(url) }, sid);
  }

  async history(tabId: string, delta: -1 | 1): Promise<void> {
    const { cdp, sid } = await this.session(tabId);
    const h = await cdp.send<{ currentIndex: number; entries: { id: number }[] }>("Page.getNavigationHistory", {}, sid);
    const entry = h.entries[h.currentIndex + delta];
    if (!entry) return;
    await cdp.send("Page.navigateToHistoryEntry", { entryId: entry.id }, sid);
  }

  async reload(tabId: string): Promise<void> {
    const { cdp, sid } = await this.session(tabId);
    await cdp.send("Page.reload", {}, sid);
  }

  async stop(tabId: string): Promise<void> {
    const { cdp, sid } = await this.session(tabId);
    await cdp.send("Page.stopLoading", {}, sid);
  }

  /**
   * Runs one input event for `tabId` after every earlier one. RPC handlers
   * run concurrently, so without this a touch end could reach Chrome before
   * its start (the phone pipelines up to 8 inputs). Enqueued synchronously
   * on arrival, so the order is the link's message order.
   */
  private input(tabId: string, _session: ClientSession | undefined, fn: (cdp: CdpConnection, t: TabState, sid: string) => Promise<void>): Promise<void> {
    const t = this.tabs.get(tabId);
    if (!t) return this.session(tabId).then(() => undefined); // throws not_found
    const queued = TRACE ? performance.now() : 0;
    const run = (t.inputChain ?? Promise.resolve())
      .catch(() => {})
      .then(async () => {
        const started = TRACE ? performance.now() : 0;
        const { cdp, sid } = await this.session(tabId);
        await fn(cdp, t, sid);
        if (TRACE) this.log(`trace input queued+${(started - queued).toFixed(0)}ms dispatched+${(performance.now() - started).toFixed(0)}ms`);
      });
    t.inputChain = run.catch(() => {});
    return run;
  }

  /**
   * A hidden (background) tab produces no screencast frames and Chrome never
   * acknowledges input dispatched to it (Input.* times out), for example after
   * the Mac user or another phone brought a different tab to the front. The
   * page reports visibilitychange through a binding (cached in `t.hidden`),
   * so this costs no round trip per input.
   *
   * Only a tab the phone is streaming is brought to the front. In the
   * host's own Chrome profile that is enough; with an explicit --cdp (the
   * user's own Chrome), the input must also come from the phone that owns
   * the stream, so another client's input never moves the user's window.
   */
  private async ensureVisible(cdp: CdpConnection, t: TabState, sid: string, session?: ClientSession): Promise<void> {
    const cast = t.cast;
    if (!cast || t.hidden !== true) return;
    if (!this.ownsBrowser && cast.session !== session) return;
    this.log(`browser: tab ${t.tab.id} was in the background; bringing it to the front for input`);
    await cdp.send("Target.activateTarget", { targetId: t.tab.id }).catch(() => {});
    await cdp.send("Page.bringToFront", {}, sid).catch(() => {});
    t.hidden = false;
    this.lastActivated = t.tab.id;
    this.updateActive();
  }

  pointer(tabId: string, p: { type: string; x: number; y: number; button?: string; clickCount?: number }, session?: ClientSession): Promise<void> {
    return this.input(tabId, session, async (cdp, t, sid) => {
      if (p.type === "down") await this.ensureVisible(cdp, t, sid, session);
      const type = p.type === "down" ? "mousePressed" : p.type === "up" ? "mouseReleased" : "mouseMoved";
      await cdp.send(
        "Input.dispatchMouseEvent",
        { type, x: p.x, y: p.y, button: p.button === "left" ? "left" : "none", clickCount: p.clickCount ?? (type === "mouseMoved" ? 0 : 1), pointerType: "mouse" },
        sid,
        INPUT_TIMEOUT_MS,
      );
    });
  }

  touch(tabId: string, type: string, points: { x: number; y: number; id: number }[], session?: ClientSession): Promise<void> {
    const map: Record<string, string> = { start: "touchStart", move: "touchMove", end: "touchEnd", cancel: "touchCancel" };
    const cdpType = map[type];
    if (!cdpType) return Promise.reject(new RpcError("bad_request", `bad touch type ${type}`));
    return this.input(tabId, session, async (cdp, t, sid) => {
      if (type === "start") await this.ensureVisible(cdp, t, sid, session);
      await cdp.send(
        "Input.dispatchTouchEvent",
        { type: cdpType, touchPoints: cdpType === "touchEnd" || cdpType === "touchCancel" ? [] : points.map((pt) => ({ x: pt.x, y: pt.y, id: pt.id })) },
        sid,
        INPUT_TIMEOUT_MS,
      );
    });
  }

  scroll(tabId: string, x: number, y: number, dx: number, dy: number, session?: ClientSession): Promise<void> {
    return this.input(tabId, session, async (cdp, _t, sid) => {
      await cdp.send("Input.dispatchMouseEvent", { type: "mouseWheel", x, y, deltaX: dx, deltaY: dy }, sid, INPUT_TIMEOUT_MS);
    });
  }

  key(tabId: string, p: { type: string; key: string; code?: string; text?: string; modifiers?: number }, session?: ClientSession): Promise<void> {
    return this.input(tabId, session, async (cdp, t, sid) => {
      if (p.type !== "up") await this.ensureVisible(cdp, t, sid, session);
      const vk = virtualKeyCode(p.key);
      const params: Record<string, unknown> = {
        type: p.type === "up" ? "keyUp" : p.text ? "keyDown" : "rawKeyDown",
        key: p.key,
        code: p.code ?? "",
        modifiers: p.modifiers ?? 0,
        ...(vk ? { windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk } : {}),
      };
      if (p.type !== "up" && p.text) {
        params.text = p.text;
        params.unmodifiedText = p.text;
      }
      await cdp.send("Input.dispatchKeyEvent", params, sid, INPUT_TIMEOUT_MS);
    });
  }

  text(tabId: string, text: string, session?: ClientSession): Promise<void> {
    return this.input(tabId, session, async (cdp, _t, sid) => {
      await cdp.send("Input.insertText", { text }, sid, INPUT_TIMEOUT_MS);
    });
  }

  async screenshot(tabId: string): Promise<string> {
    const { cdp, t, sid } = await this.session(tabId);
    if (t.cast?.lastFrame) return t.cast.lastFrame.toString("base64");
    try {
      const { data } = await cdp.send<{ data: string }>("Page.captureScreenshot", { format: "jpeg", quality: 60 }, sid, 5_000);
      t.lastShot = Buffer.from(data, "base64");
      return data;
    } catch (err) {
      if (t.lastShot) return t.lastShot.toString("base64");
      throw new RpcError("unavailable", `screenshot failed: ${(err as Error).message}`);
    }
  }

  register(server: RpcServer): void {
    this.on("event", (topic, payload) => server.broadcast(topic, payload));
    server.register("browser.list", async () => ({ tabs: await this.list() }));
    server.register("browser.create", async (p) => ({ tab: await this.create(optStr(p, "url")) }));
    server.register("browser.attach", (p, session) =>
      this.attach(
        session,
        str(p, "tabId"),
        num(p, "width", 390),
        num(p, "height", 844),
        num(p, "scale", 3),
        p.mobile !== false,
        p.frameMeta === true,
        p.reloadForMode === true,
      ),
    );
    server.register("browser.detach", async (p, session) => {
      await this.detach(session, num(p, "streamId"));
      return {};
    });
    server.register("browser.close", async (p) => {
      const tabId = str(p, "tabId");
      try {
        await this.closeTab(tabId);
      } catch (err) {
        this.log(`browser.close ${tabId} failed: ${(err as Error).message}`);
        throw err;
      }
      return {};
    });
    server.register("browser.activate", async (p) => {
      await this.activate(str(p, "tabId"));
      return {};
    });
    server.register("browser.viewport", async (p) => {
      await this.viewport(str(p, "tabId"), num(p, "width"), num(p, "height"), num(p, "scale", 3));
      return {};
    });
    server.register("browser.ack", (p, session) => {
      this.ack(session, num(p, "streamId"), num(p, "seq"));
      return {};
    });
    server.register("browser.navigate", async (p) => {
      await this.navigate(str(p, "tabId"), str(p, "url"));
      return {};
    });
    server.register("browser.back", async (p) => {
      await this.history(str(p, "tabId"), -1);
      return {};
    });
    server.register("browser.forward", async (p) => {
      await this.history(str(p, "tabId"), 1);
      return {};
    });
    server.register("browser.reload", async (p) => {
      await this.reload(str(p, "tabId"));
      return {};
    });
    server.register("browser.stop", async (p) => {
      await this.stop(str(p, "tabId"));
      return {};
    });
    server.register("browser.pointer", async (p, session) => {
      await this.pointer(str(p, "tabId"), { type: str(p, "type"), x: num(p, "x"), y: num(p, "y"), button: optStr(p, "button"), clickCount: typeof p.clickCount === "number" ? p.clickCount : undefined }, session);
      return {};
    });
    server.register("browser.touch", async (p, session) => {
      await this.touch(str(p, "tabId"), str(p, "type"), Array.isArray(p.points) ? p.points : [], session);
      return {};
    });
    server.register("browser.scroll", async (p, session) => {
      await this.scroll(str(p, "tabId"), num(p, "x"), num(p, "y"), num(p, "dx", 0), num(p, "dy", 0), session);
      return {};
    });
    server.register("browser.key", async (p, session) => {
      await this.key(str(p, "tabId"), { type: str(p, "type"), key: str(p, "key"), code: optStr(p, "code"), text: optStr(p, "text"), modifiers: typeof p.modifiers === "number" ? p.modifiers : 0 }, session);
      return {};
    });
    server.register("browser.text", async (p, session) => {
      await this.text(str(p, "tabId"), typeof p.text === "string" ? p.text : "", session);
      return {};
    });
    server.register("browser.screenshot", async (p) => ({ dataBase64: await this.screenshot(str(p, "tabId")) }));
  }
}

// ---------------------------------------------------------------- helpers

export interface BrowserFrameMeta {
  scrollX: number;
  scrollY: number;
  pageScale: number;
  offsetTop: number;
}

/** Extended frame payload (PROTOCOL.md §3): format byte | 0x80, then
 * `[f32 scrollX][f32 scrollY][f32 pageScale][f32 offsetTop]` (CSS px, BE)
 * after the 13-byte header, then the image. Sent only to phones that attach
 * with `frameMeta:true`. */
export function encodeBrowserFrameMeta(h: Parameters<typeof encodeBrowserFramePayload>[0], meta: BrowserFrameMeta, image: Uint8Array): Uint8Array {
  const base = encodeBrowserFramePayload(h, new Uint8Array(0));
  const out = new Uint8Array(base.byteLength + 16 + image.byteLength);
  out.set(base, 0);
  const v = new DataView(out.buffer);
  v.setUint8(12, (h.format & 0x7f) | FRAME_META_FLAG);
  v.setFloat32(13, meta.scrollX, false);
  v.setFloat32(17, meta.scrollY, false);
  v.setFloat32(21, meta.pageScale, false);
  v.setFloat32(25, meta.offsetTop, false);
  out.set(image, base.byteLength + 16);
  return out;
}

export function decodeBrowserFrameMeta(p: Uint8Array): BrowserFrameMeta | null {
  const v = new DataView(p.buffer, p.byteOffset, p.byteLength);
  if (p.byteLength < 29 || (v.getUint8(12) & FRAME_META_FLAG) === 0) return null;
  return { scrollX: v.getFloat32(13, false), scrollY: v.getFloat32(17, false), pageScale: v.getFloat32(21, false), offsetTop: v.getFloat32(25, false) };
}

export function normalizeUrl(input: string): string {
  const s = input.trim();
  if (/^[a-z][a-z0-9+.-]*:/i.test(s) && !/^localhost:\d/i.test(s)) return s;
  if (/^(localhost|\d{1,3}(\.\d{1,3}){3})(:\d+)?(\/|$)/i.test(s)) return `http://${s}`;
  if (!/\s/.test(s) && /^[^/]+\.[a-z]{2,}(:\d+)?(\/.*)?$/i.test(s)) return `https://${s}`;
  return `https://www.google.com/search?q=${encodeURIComponent(s)}`;
}

const VK: Record<string, number> = {
  Backspace: 8,
  Tab: 9,
  Enter: 13,
  Shift: 16,
  Control: 17,
  Alt: 18,
  Escape: 27,
  " ": 32,
  PageUp: 33,
  PageDown: 34,
  End: 35,
  Home: 36,
  ArrowLeft: 37,
  ArrowUp: 38,
  ArrowRight: 39,
  ArrowDown: 40,
  Delete: 46,
  Meta: 91,
};

function virtualKeyCode(key: string): number | undefined {
  if (VK[key] !== undefined) return VK[key];
  if (key.length === 1) {
    const c = key.toUpperCase().charCodeAt(0);
    if ((c >= 65 && c <= 90) || (c >= 48 && c <= 57)) return c;
  }
  return undefined;
}

/** Reads width/height from a JPEG's SOF marker. */
export function jpegSize(buf: Uint8Array): { width: number; height: number } | null {
  if (buf.length < 4 || buf[0] !== 0xff || buf[1] !== 0xd8) return null;
  let i = 2;
  while (i + 9 < buf.length) {
    if (buf[i] !== 0xff) {
      i++;
      continue;
    }
    const marker = buf[i + 1]!;
    if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
      i += 2;
      continue;
    }
    const len = (buf[i + 2]! << 8) | buf[i + 3]!;
    if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
      return { height: (buf[i + 5]! << 8) | buf[i + 6]!, width: (buf[i + 7]! << 8) | buf[i + 8]! };
    }
    i += 2 + len;
  }
  return null;
}
