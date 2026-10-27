// Fakes for page state tests (pageState.ts): a page DOM whose route, scrollers, layout and
// visibility the test drives, and the client a discard then restore hands the next document.
import { BridgePageClient, RESTORE_NAME, type ReplyHandler } from "./pageClient";
import { PAGE_STATE_KEY, type PageStateHost } from "./pageLifecycle";
import type { PageScroller, PageStateDom, SavedPageState } from "./pageState";

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
