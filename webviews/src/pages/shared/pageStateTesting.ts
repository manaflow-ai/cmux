// Fakes for page state tests (pageState.ts): a page DOM whose route, scrollers, layout and
// visibility the test drives, and the client a discard then restore hands the next document.
import { BridgePageClient, RESTORE_NAME, type PageClient, type ReplyHandler } from "./pageClient";
import { PAGE_STATE_KEY, type PageStateHost } from "./pageLifecycle";
import { openPageState, type PageScroller, type PageStateDom, type SavedPageState } from "./pageState";

const handler: ReplyHandler = { postMessage: async () => ({ t: "ok", id: 0, value: null }) };

/** One scroller whose offset is clamped to its content, as a browser's is. */
export class FakeScroller implements PageScroller {
  private top = 0;

  constructor(
    public scrollHeight: number,
    public clientHeight: number,
  ) {}

  get scrollTop(): number {
    return this.top;
  }

  set scrollTop(value: number) {
    this.top = Math.max(0, Math.min(value, this.scrollHeight - this.clientHeight));
  }
}

/** A page's DOM: a route, named scrollers, a layout the test changes and a host that records saves. */
export class FakePageDom implements PageStateDom {
  hash: string;
  readonly replaced: string[] = [];
  readonly posts: string[] = [];
  readonly host: PageStateHost;
  private readonly scrollerMap = new Map<string, FakeScroller>();
  private visibility: DocumentVisibilityState = "visible";
  private readonly visibilityListeners = new Set<() => void>();
  private readonly layoutListeners = new Set<() => void>();
  private readonly userListeners = new Set<() => void>();
  private readonly stored = new Map<string, string>();

  constructor(hash = "") {
    this.hash = hash;
    const visibility = () => this.visibility;
    this.host = {
      document: {
        get visibilityState() {
          return visibility();
        },
        addEventListener: (_type: string, listener: () => void) => void this.visibilityListeners.add(listener),
        removeEventListener: (_type: string, listener: () => void) => void this.visibilityListeners.delete(listener),
      } as unknown as PageStateHost["document"],
      storage: {
        getItem: (key) => this.stored.get(key) ?? null,
        setItem: (key, value) => void this.stored.set(key, value),
        removeItem: (key) => void this.stored.delete(key),
      },
      post: (json) => void this.posts.push(json),
    };
  }

  route = (): string => this.hash;

  replaceRoute = (route: string): void => {
    this.replaced.push(route);
    this.hash = route;
  };

  scrollers = (): Map<string, PageScroller> => new Map<string, PageScroller>(this.scrollerMap);

  observeLayout = (changed: () => void): (() => void) => {
    this.layoutListeners.add(changed);
    return () => void this.layoutListeners.delete(changed);
  };

  observeUserScroll = (moved: () => void): (() => void) => {
    this.userListeners.add(moved);
    return () => void this.userListeners.delete(moved);
  };

  /** Adds the scroller `key` with `scrollHeight` of content in a `clientHeight` view. */
  scroller(key: string, scrollHeight: number, clientHeight = 100): FakeScroller {
    const scroller = new FakeScroller(scrollHeight, clientHeight);
    this.scrollerMap.set(key, scroller);
    return scroller;
  }

  /** The content changed (a list grew, a section mounted). */
  layout(): void {
    for (const listener of this.layoutListeners) listener();
  }

  /** The person scrolled or pressed a key. */
  userInput(): void {
    for (const listener of this.userListeners) listener();
  }

  hide(): void {
    this.visibility = "hidden";
    for (const listener of this.visibilityListeners) listener();
  }

  /** What the last hide posted to the host, parsed. */
  lastSaved(): SavedPageState {
    return JSON.parse(this.posts.at(-1) ?? "null") as SavedPageState;
  }

  /** The state the last hide stored in sessionStorage. */
  storedState(): string | undefined {
    return this.stored.get(PAGE_STATE_KEY);
  }

  /** The layout and person-input observers the restore still holds. */
  observerCount(): number {
    return this.layoutListeners.size + this.userListeners.size;
  }
}

/** The client of the document that comes back after a discard, with what the old one saved. */
export function restoredClient(saved: unknown, hash = ""): BridgePageClient {
  return new BridgePageClient(handler, { [RESTORE_NAME]: { wasDiscarded: true, state: saved }, location: { hash } });
}

/** Hides `dom`'s page and returns the client a discard then restore hands the next document. */
export function discardAndRestore(dom: FakePageDom, hash = dom.hash): BridgePageClient {
  dom.hide();
  return restoredClient(dom.lastSaved(), hash);
}

/** One page's discard as a test drives it (`pageRoundTrip`). */
export interface PageRoundTrip {
  /** The first document: its scrollers are set, and `keep` saves its inputs on hide. */
  readonly before: FakePageDom;
  /** Hides `before`, and opens the next document's state on a DOM whose scrollers are `heights`. */
  restore(heights?: Record<string, number>): { client: BridgePageClient; after: FakePageDom };
}

/**
 * Opens `page`'s state on a document at `route` with each `scroll` offset set, saving `inputs()` on
 * hide, as main.tsx does for that page. `restore` then gives the next document's client and DOM,
 * with its state opened (the scroll comes back as its scrollers lay out).
 */
export function pageRoundTrip(
  page: string,
  {
    route = "",
    scroll = {},
    inputs = () => null,
  }: { route?: string; scroll?: Record<string, number>; inputs?: () => unknown },
): PageRoundTrip {
  const before = new FakePageDom(route);
  for (const [key, offset] of Object.entries(scroll)) before.scroller(key, offset + 5000).scrollTop = offset;
  openPageState(new BridgePageClient(handler, { location: { hash: route } }), page, before).keep(inputs);
  return {
    before,
    restore(heights = {}) {
      const client = discardAndRestore(before, route);
      const after = new FakePageDom(route);
      for (const key of Object.keys(scroll)) after.scroller(key, heights[key] ?? (scroll[key] ?? 0) + 5000);
      openPageState(client, page, after).keep(() => null);
      return { client, after };
    },
  };
}

/** `provider` (a page's mock) as the restored document's client: its ops, `restored`'s restore. */
export function withRestore(provider: PageClient, restored: PageClient): PageClient {
  return {
    call: (op, params, options) => provider.call(op, params, options),
    subscribe: (stream, onEvent, filter) => provider.subscribe(stream, onEvent, filter),
    handle: (op, handler) => provider.handle(op, handler),
    restore: restored.restore,
    entryRoute: restored.entryRoute,
  };
}

/** The scroll offset of `after`'s scroller `key`. */
export function scrollOf(after: FakePageDom, key: string): number {
  return after.scrollers().get(key)?.scrollTop ?? 0;
}
