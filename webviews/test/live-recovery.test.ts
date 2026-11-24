// cmux Live's guard on a dev-served page (dev-server/liveRecovery.ts): a page whose modules stop
// loading under it (the dev server restarted or stopped) loads again with a note instead of staying
// blank, a few times at most, and leaves a page alone while the Vite client still holds the server
// (a build error, which Vite's overlay shows). Runs the inlined source, as the page gets it.
import { describe, expect, test } from "bun:test";
import { Window } from "happy-dom";
import { devEntrySrc } from "../dev-server/devEntrySrc";
import { LIVE_RECOVERY, liveRecoveryScript } from "../dev-server/liveRecovery";
import { directStylesheetLink } from "../dev-server/plugins";

type Page = {
  win: Window & { __cmuxLiveConnected?: boolean };
  reloads: number;
  timers: Array<() => void>;
  note: () => string | null;
  failModule: () => void;
};

// A WebSocket that opens and closes when the test says so (happy-dom's would dial the network).
class FakeSocket extends EventTarget {
  readonly protocols: string | string[] | undefined;
  constructor(_url: string, protocols?: string | string[]) {
    super();
    this.protocols = protocols;
  }
}

function page(storage?: Storage, before?: (win: Page["win"]) => void): Page {
  const win = new Window({ url: "cmux-page://cmux.settings/" }) as Page["win"];
  const state = { reloads: 0, timers: [] as Array<() => void> };
  Object.defineProperty(win, "location", { value: { reload: () => state.reloads++ }, configurable: true });
  if (storage) Object.defineProperty(win, "sessionStorage", { value: storage, configurable: true });
  win.setTimeout = ((run: () => void) => {
    state.timers.push(run);
    return 0;
  }) as unknown as Window["setTimeout"];
  before?.(win);
  new win.Function("window", liveRecoveryScript.replace(/\(window,/, "(arguments[0],"))(win);
  return {
    win,
    get reloads() {
      return state.reloads;
    },
    timers: state.timers,
    note: () => win.document.querySelector("cmux-live-note")?.shadowRoot?.textContent ?? null,
    failModule: () => {
      const script = win.document.createElement("script");
      script.type = "module";
      win.document.head.append(script);
      script.dispatchEvent(new win.Event("error"));
    },
  };
}

const flush = (p: Page) => p.timers.splice(0).forEach((run) => run());

describe("a page whose modules stop loading", () => {
  test("shows a note and loads again", () => {
    const p = page();
    p.failModule();
    expect(p.reloads).toBe(0);
    flush(p);
    expect(p.reloads).toBe(1);
    expect(p.note()).toContain("Loading this page again");
  });

  test("tries a few times, then keeps a note that names cmux live status", () => {
    const storage = new Window().sessionStorage;
    for (let i = 0; i < LIVE_RECOVERY.tries; i++) {
      const p = page(storage);
      p.failModule();
      flush(p);
      expect(p.reloads).toBe(1);
    }
    const last = page(storage);
    last.failModule();
    flush(last);
    expect(last.reloads).toBe(0);
    expect(last.note()).toContain("cmux live status");
  });

  test("stops when its try cannot be counted", () => {
    const refusing = new Window().sessionStorage;
    Object.defineProperty(refusing, "setItem", {
      value: () => {
        throw new Error("quota");
      },
    });
    const p = page(refusing);
    p.failModule();
    flush(p);
    expect(p.reloads).toBe(0);
    expect(p.note()).toContain("cmux live status");
  });

  test("is left alone while the Vite client holds the server", () => {
    const p = page();
    p.win.__cmuxLiveConnected = true;
    p.failModule();
    flush(p);
    expect(p.reloads).toBe(0);
    expect(p.note()).toBeNull();
  });

  test("knows the Vite client holds the server even when liveNote loads after it connected", () => {
    // The Vite client's socket opens before src/devkit/liveNote.dev.ts registers its listener, so
    // vite:ws:connect never reaches it; the inline guard watches the HMR socket itself.
    const p = page(undefined, (win) =>
      Object.defineProperty(win, "WebSocket", { value: FakeSocket, configurable: true }),
    );
    const socket = new (p.win as unknown as { WebSocket: typeof FakeSocket }).WebSocket(
      "ws://127.0.0.1:4200/",
      "vite-hmr",
    );
    socket.dispatchEvent(new Event("open"));
    p.failModule();
    flush(p);
    expect(p.reloads).toBe(0);
    socket.dispatchEvent(new Event("close"));
    p.failModule();
    flush(p);
    expect(p.reloads).toBe(1);
  });

  test("another page socket does not count as the Vite client", () => {
    const p = page(undefined, (win) =>
      Object.defineProperty(win, "WebSocket", { value: FakeSocket, configurable: true }),
    );
    const socket = new (p.win as unknown as { WebSocket: typeof FakeSocket }).WebSocket("wss://example.test/", "chat");
    socket.dispatchEvent(new Event("open"));
    p.failModule();
    flush(p);
    expect(p.reloads).toBe(1);
  });

  test("a failed dynamic import counts; another rejection does not", () => {
    const failed = page();
    const reject = (win: Window, message: string) => {
      const event = new win.Event("unhandledrejection");
      Object.assign(event, { reason: new Error(message) });
      win.dispatchEvent(event);
    };
    reject(failed.win, "Failed to fetch dynamically imported module: cmux-page://cmux.settings/src/x.tsx");
    flush(failed);
    expect(failed.reloads).toBe(1);
    const other = page();
    reject(other.win, "the host refused the op");
    flush(other);
    expect(other.reloads).toBe(0);
  });
});

describe("a page's stylesheet link", () => {
  test("asks for CSS directly", () => {
    expect(directStylesheetLink('<link rel="stylesheet" href="./styles.css" />')).toBe(
      '<link rel="stylesheet" href="./styles.css?direct" />',
    );
    expect(directStylesheetLink('<link href="/a/b.css" rel=stylesheet>')).toBe(
      '<link href="/a/b.css?direct" rel=stylesheet>',
    );
  });

  test("keeps other links and a href that has a query", () => {
    expect(directStylesheetLink('<link rel="icon" href="./x.css">')).toBe('<link rel="icon" href="./x.css">');
    expect(directStylesheetLink('<link rel="stylesheet" href="./x.css?v=1">')).toBe(
      '<link rel="stylesheet" href="./x.css?v=1">',
    );
  });
});

describe("an injected dev script's URL", () => {
  // Chief web serves at /c/ from src/chief-web: without the base, its server answered the guard's
  // own note module 404 and the guard reloaded the page as if the server had stopped.
  test("is under the server's base, through /@fs outside its root", () => {
    expect(devEntrySrc({ root: "/w/src/chief-web", base: "/c/" }, "/w/src/devkit/liveNote.dev.ts")).toBe(
      "/c/@fs/w/src/devkit/liveNote.dev.ts",
    );
    expect(devEntrySrc({ root: "/w", base: "/" }, "/w/src/devkit/liveNote.dev.ts")).toBe("/src/devkit/liveNote.dev.ts");
    expect(devEntrySrc({ root: "/w", base: "./" }, "/w/a.ts")).toBe("/a.ts");
  });
});
