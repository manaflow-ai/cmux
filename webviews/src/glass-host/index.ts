// glass-host: native glass under a see-through web page, positioned by the page (README.md). The page
// opens a surface, keeps its box current and closes it; the app draws its own glass there, under the
// page, and the page draws the surface's content on top. This module has no dependencies: it imports
// nothing outside this folder, and it talks to the app only through the `transport` it is given.
//
// The wire is declarative: each report is the whole list of open surfaces (`GlassSurfaceState[]`), so
// the native side never has to track deltas and a lost report is healed by the next. Changes coalesce
// to one report per animation frame, and a report goes out only when the list changed.

/** How dense a surface's glass is: a popover (cards, pickers, panels), a menu, or a chip (tooltips). */
export type GlassLevel = "popover" | "menu" | "chip";
export const GLASS_LEVELS: readonly GlassLevel[] = ["popover", "menu", "chip"];

/** A box in the page's viewport, CSS pixels from its top-left. */
export type GlassRect = { left: number; top: number; right: number; bottom: number };

/** One open surface as the app receives it. */
export type GlassSurfaceState = GlassRect & { id: string; level: GlassLevel; radius: number; opacity: number };

/** Sends one report to the app. Resolve once the app has drawn it; reject when it cannot (an app that
 * does not know the call): the host then stops reporting and every surface falls back. */
export type GlassTransport = (surfaces: GlassSurfaceState[]) => Promise<unknown>;

/** Where a surface stands: waiting for the app's first draw, drawn on the app's glass, or fallen back
 * to the page's own look (the deadline passed, the app refused, or the host does not apply). */
export type GlassSurfacePhase = "pending" | "drawn" | "fallback";

export type GlassSurfaceOptions = {
  level?: GlassLevel;
  rect: GlassRect;
  /** Corner radius, CSS pixels. */
  radius?: number;
  /** 0...1, for a fade the page runs. */
  opacity?: number;
};

export interface GlassSurface {
  readonly id: string;
  /** The phase now; `ready` settles when it leaves "pending". */
  readonly phase: GlassSurfacePhase;
  /** Resolves true once the app drew this surface, false when it fell back. */
  readonly ready: Promise<boolean>;
  /** Moves the surface to `rect` (its size included). */
  position(rect: GlassRect): void;
  /** Keeps the top-left corner and changes the size. */
  resize(width: number, height: number): void;
  setOpacity(opacity: number): void;
  setRadius(radius: number): void;
  /** Closes the surface; the app removes its glass with the next report. */
  close(): void;
}

/** The page's window, with the observer constructors the host makes its observers from (a frame's own). */
export type GlassHostWindow = Window & {
  ResizeObserver?: typeof ResizeObserver;
  MutationObserver: typeof MutationObserver;
};

export type GlassHostOptions = {
  transport: GlassTransport;
  /** The page's window (rAF, timers). Defaults to `globalThis.window`. */
  view?: GlassHostWindow;
  /** How long a new surface waits for the app before it falls back, ms. */
  deadlineMs?: number;
  /** Whether the app's glass can show now (a page that is see-through over it). Read before every
   * report; a false answer reports nothing and falls every surface back. Defaults to true. */
  applies?: () => boolean;
};

export interface GlassHost {
  /** Opens a surface at a box you keep current. */
  open(options: GlassSurfaceOptions): GlassSurface;
  /** Opens a surface that follows `element`'s box, radius and opacity, and marks the element with its
   * phase (`data-glass-host`) so CSS can hide it until drawn and drop its own fill once drawn
   * (`glassHostCss`). Close it, or remove the element, to end it. */
  attach(element: Element, options?: { level?: GlassLevel }): GlassSurface;
  /** Attaches every element under `root` with a `data-glass-level` attribute, now and as they mount. */
  observe(root?: ParentNode): () => void;
  /** The surfaces open now. */
  readonly surfaces: readonly GlassSurface[];
  /** Whether the app is still taking reports (false after a refusal or `destroy`). */
  readonly live: boolean;
  /** Closes every surface, sends the empty report, and stops. */
  destroy(): void;
}

/** On an attached element: its phase. */
export const PHASE_ATTRIBUTE = "data-glass-host";
/** Marks an element for `observe`, with its level as the value. */
export const LEVEL_ATTRIBUTE = "data-glass-level";
export const DEFAULT_DEADLINE_MS = 50;
export const MAX_SURFACES = 16;
/** Unchanged frames before an attached element's follow loop stops. */
const STABLE_FRAMES = 3;

/** The CSS an attached element needs: hidden while pending, no fill of its own once drawn. Put it in the
 * page once (a stylesheet or a <style>). `--glass-host-fill` keeps a veil of your own on the glass.
 * Under `prefers-reduced-transparency: reduce` the app's glass is its opaque fill, so a drawn surface
 * needs no blur of its own there either. */
export const glassHostCss = `
[${PHASE_ATTRIBUTE}="pending"] { filter: opacity(0); }
[${PHASE_ATTRIBUTE}="drawn"] {
  background: var(--glass-host-fill, transparent) !important;
  -webkit-backdrop-filter: none !important;
  backdrop-filter: none !important;
}
`;

const round = (value: number) => Math.round(value * 100) / 100;
const finite = (value: number, fallback: number) => (Number.isFinite(value) ? value : fallback);

function cleanRect(rect: GlassRect): GlassRect {
  const left = finite(rect.left, 0);
  const top = finite(rect.top, 0);
  return {
    left: round(left),
    top: round(top),
    right: round(Math.max(left, finite(rect.right, left))),
    bottom: round(Math.max(top, finite(rect.bottom, top))),
  };
}

type Entry = {
  surface: SurfaceImpl;
  state: Omit<GlassSurfaceState, "id">;
  /** An attached element's reader: its box, radius and opacity now, or none while it is not shown. */
  read?: () => Omit<GlassSurfaceState, "id" | "level"> | undefined;
  element?: Element;
  timer?: ReturnType<typeof setTimeout>;
  observer?: ResizeObserver;
};

class SurfaceImpl implements GlassSurface {
  phase: GlassSurfacePhase = "pending";
  readonly ready: Promise<boolean>;
  settle!: (drawn: boolean) => void;
  constructor(
    readonly id: string,
    private readonly host: Host,
  ) {
    this.ready = new Promise<boolean>((resolve) => (this.settle = resolve));
  }
  position(rect: GlassRect) {
    this.host.change(this.id, { ...cleanRect(rect) });
  }
  resize(width: number, height: number) {
    const state = this.host.stateOf(this.id);
    if (!state) return;
    this.host.change(this.id, cleanRect({ ...state, right: state.left + width, bottom: state.top + height }));
  }
  setOpacity(opacity: number) {
    this.host.change(this.id, { opacity: round(Math.min(1, Math.max(0, finite(opacity, 1)))) });
  }
  setRadius(radius: number) {
    this.host.change(this.id, { radius: round(Math.max(0, finite(radius, 0))) });
  }
  close() {
    this.host.close(this.id);
  }
}

/** What moves an attached element without resizing it (``Host.follow``). */
const FOLLOW_EVENTS = ["transitionrun", "transitionend", "animationstart"] as const;

class Host implements GlassHost {
  private readonly entries = new Map<string, Entry>();
  private readonly view: GlassHostWindow;
  private stopFollowing?: () => void;
  private readonly transport: GlassTransport;
  private readonly deadline: number;
  private readonly applies: () => boolean;
  private nextId = 0;
  private frame = 0;
  private soon = false;
  private stable = 0;
  private sent = "[]";
  live = true;

  constructor(options: GlassHostOptions) {
    const view = options.view ?? (globalThis.window as GlassHostWindow | undefined);
    if (!view) throw new Error("glass-host: no window");
    this.view = view;
    this.transport = options.transport;
    this.deadline = options.deadlineMs ?? DEFAULT_DEADLINE_MS;
    this.applies = options.applies ?? (() => true);
  }

  get surfaces(): readonly GlassSurface[] {
    return [...this.entries.values()].map((entry) => entry.surface);
  }

  stateOf(id: string) {
    return this.entries.get(id)?.state;
  }

  open(options: GlassSurfaceOptions): GlassSurface {
    return this.add({
      level: options.level ?? "popover",
      ...cleanRect(options.rect),
      radius: round(Math.max(0, options.radius ?? 0)),
      opacity: round(Math.min(1, Math.max(0, options.opacity ?? 1))),
    });
  }

  attach(element: Element, options: { level?: GlassLevel } = {}): GlassSurface {
    const view = this.view;
    const read = () => {
      if (!element.isConnected || element.closest("[hidden]")) return undefined;
      const style = view.getComputedStyle(element);
      if (style.display === "none" || style.visibility === "hidden") return undefined;
      const box = element.getBoundingClientRect();
      if (!(box.width > 0 && box.height > 0)) return undefined;
      const radius = Number.parseFloat(style.borderTopLeftRadius) || 0;
      return {
        ...cleanRect(box),
        radius: round(Math.min(radius, box.width / 2, box.height / 2)),
        opacity: round(Math.min(1, Math.max(0, finite(Number.parseFloat(style.opacity), 1)))),
      };
    };
    const first = read();
    const level = options.level ?? (element.getAttribute(LEVEL_ATTRIBUTE) as GlassLevel | null) ?? "popover";
    const surface = this.add(
      { level, ...(first ?? { left: 0, top: 0, right: 0, bottom: 0, radius: 0, opacity: 0 }) },
      { read, element },
    );
    element.setAttribute(PHASE_ATTRIBUTE, surface.phase);
    const entry = this.entries.get(surface.id)!;
    if (typeof view.ResizeObserver === "function") {
      const observer = new view.ResizeObserver(() => this.kick());
      observer.observe(element);
      entry.observer = observer;
    }
    this.follow();
    return surface;
  }

  observe(root: ParentNode = this.view.document): () => void {
    const selector = `[${LEVEL_ATTRIBUTE}]`;
    const attached = new Map<Element, GlassSurface>();
    const adopt = (element: Element) => {
      if (attached.has(element) || !GLASS_LEVELS.includes(element.getAttribute(LEVEL_ATTRIBUTE) as GlassLevel)) return;
      attached.set(element, this.attach(element));
    };
    const scan = (node: Node) => {
      if (node.nodeType !== 1) return;
      const element = node as Element;
      if (element.matches(selector)) adopt(element);
      for (const inner of element.querySelectorAll(selector)) adopt(inner);
    };
    for (const element of root.querySelectorAll(selector)) adopt(element);
    const observer = new this.view.MutationObserver((records) => {
      for (const record of records) {
        for (const node of record.addedNodes) scan(node);
        if (record.type === "attributes") scan(record.target);
      }
      for (const [element, surface] of attached)
        if (!element.isConnected || !element.hasAttribute(LEVEL_ATTRIBUTE)) {
          surface.close();
          attached.delete(element);
        }
      this.kick();
    });
    observer.observe(root as Node, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: [LEVEL_ATTRIBUTE],
    });
    return () => {
      observer.disconnect();
      for (const surface of attached.values()) surface.close();
      attached.clear();
    };
  }

  change(id: string, patch: Partial<Omit<GlassSurfaceState, "id">>) {
    const entry = this.entries.get(id);
    if (!entry) return;
    entry.state = { ...entry.state, ...patch };
    this.kick();
  }

  close(id: string) {
    const entry = this.entries.get(id);
    if (!entry) return;
    if (entry.timer !== undefined) clearTimeout(entry.timer);
    entry.observer?.disconnect();
    entry.element?.removeAttribute(PHASE_ATTRIBUTE);
    if (entry.surface.phase === "pending") this.setPhase(entry, "fallback");
    this.entries.delete(id);
    if (![...this.entries.values()].some((other) => other.read)) {
      this.stopFollowing?.();
      this.stopFollowing = undefined;
    }
    this.kick();
  }

  /** While any element is attached, whatever can move it without resizing it (a scroll, a positioner
   * rewritten on a window resize, a transition or an animation) or take it out of the document (a DOM
   * change) reads the attached elements again for a few frames (`tick`). Installed by the first
   * attach, removed with the last. */
  private follow() {
    if (this.stopFollowing) return;
    const kick = () => this.kick();
    const view = this.view;
    const doc = view.document;
    const removal = new view.MutationObserver(kick);
    removal.observe(doc, { childList: true, subtree: true });
    view.addEventListener("scroll", kick, { capture: true, passive: true });
    view.addEventListener("resize", kick);
    for (const type of FOLLOW_EVENTS) doc.addEventListener(type, kick, true);
    this.stopFollowing = () => {
      removal.disconnect();
      view.removeEventListener("scroll", kick, { capture: true });
      view.removeEventListener("resize", kick);
      for (const type of FOLLOW_EVENTS) doc.removeEventListener(type, kick, true);
    };
  }

  destroy() {
    for (const id of this.entries.keys()) this.close(id);
    if (this.frame) this.view.cancelAnimationFrame(this.frame);
    this.frame = 0;
    if (this.live && this.sent !== "[]") void this.transport([]).catch(() => undefined);
    this.live = false;
  }

  private add(state: Omit<GlassSurfaceState, "id">, extra: Pick<Entry, "read" | "element"> = {}): GlassSurface {
    const surface = new SurfaceImpl(`g${++this.nextId}`, this);
    const entry: Entry = { surface, state, ...extra };
    this.entries.set(surface.id, entry);
    if (!this.live) this.setPhase(entry, "fallback");
    else
      entry.timer = setTimeout(() => {
        entry.timer = undefined;
        if (entry.surface.phase !== "pending") return;
        this.setPhase(entry, "fallback");
        // Its glass may be on its way: the next report goes without it, so a late app takes it away.
        this.flushSoon();
      }, this.deadline);
    this.flushSoon();
    return surface;
  }

  private setPhase(entry: Entry, phase: GlassSurfacePhase) {
    if (entry.surface.phase === phase) return;
    const was = entry.surface.phase;
    entry.surface.phase = phase;
    entry.element?.setAttribute(PHASE_ATTRIBUTE, phase);
    if (was === "pending") {
      if (entry.timer !== undefined) clearTimeout(entry.timer);
      entry.timer = undefined;
      entry.surface.settle(phase === "drawn");
    }
  }

  /** A new surface reports at the end of this task, not a frame later: the open costs one round trip to
   * the app, no frame of waiting. Changes in the same task (open, then position) still go as one. */
  private flushSoon() {
    if (this.soon || !this.live) return;
    this.soon = true;
    queueMicrotask(() => {
      this.soon = false;
      if (this.frame) this.view.cancelAnimationFrame(this.frame);
      this.tick();
    });
  }

  private kick() {
    this.stable = 0;
    if (!this.frame && this.live) this.frame = this.view.requestAnimationFrame(() => this.tick());
  }

  private tick() {
    this.frame = 0;
    const changed = this.report();
    this.stable = changed ? 0 : this.stable + 1;
    // Attached elements are read each frame while they move, until STABLE_FRAMES unchanged frames.
    const following = [...this.entries.values()].some((entry) => entry.read);
    if (following && this.stable < STABLE_FRAMES && this.live)
      this.frame = this.view.requestAnimationFrame(() => this.tick());
  }

  /** Sends the list if it changed; true when it did. */
  private report(): boolean {
    if (!this.live) return false;
    const applies = this.applies();
    const states: GlassSurfaceState[] = [];
    const entries: Entry[] = [];
    for (const [id, entry] of this.entries) {
      if (entry.read) {
        const now = entry.read();
        if (!now) {
          if (entry.element && !entry.element.isConnected) {
            this.close(id);
            continue;
          }
        } else entry.state = { ...entry.state, ...now };
        if (!now) continue;
      }
      if (!applies) {
        this.setPhase(entry, "fallback");
        continue;
      }
      // A surface that fell back keeps the page's own look for as long as it is open: the app's
      // glass coming in late would change it after it showed.
      if (entry.surface.phase === "fallback") continue;
      if (states.length >= MAX_SURFACES) continue;
      states.push({ id, ...entry.state });
      entries.push(entry);
    }
    const text = JSON.stringify(states);
    if (text === this.sent) return false;
    this.sent = text;
    this.transport(states).then(
      () => {
        if (!this.live) return;
        for (const entry of entries)
          if (this.entries.get(entry.surface.id) === entry && entry.surface.phase === "pending")
            this.setPhase(entry, "drawn");
      },
      () => {
        // The app cannot draw it: every surface, now and later, keeps the page's own look.
        this.live = false;
        for (const entry of this.entries.values()) this.setPhase(entry, "fallback");
      },
    );
    return true;
  }
}

/** Makes a glass host that reports through `transport`. */
export function createGlassHost(options: GlassHostOptions): GlassHost {
  return new Host(options);
}
