/// What a page the dev server serves does when the server stops answering under it (cmux live,
/// docs/cmux-next/hot-reload.md). The app serves a page's document from the server and each file it
/// imports from the server too, else from the shipped copy; a dev document whose modules the server
/// no longer answers (a restart, a crash, `cmux live start` on another checkout) has nothing to fall
/// back to and stayed blank. Now the page shows one small note and loads again: from the server
/// when it answers, else the app gives it the shipped page. A few tries, then the note stays.
///
/// `liveRecovery` runs inline, first in the document's head, so it works when no module loads, and
/// watches the Vite client's HMR socket to know whether the client is connected;
/// src/devkit/liveNote.dev.ts (a module) shows the note while the HMR socket is down (the Vite client reloads the page when the server is back). A
/// failure while the client is connected is the server's own answer (a build error, an outdated
/// dependency): Vite's overlay or its full reload handles it, so the guard does nothing.

/// The tries, the first one's delay and the quiet time after which a page counts as recovered.
export const LIVE_RECOVERY = { tries: 4, firstDelayMs: 500, settledMs: 60_000, storageKey: "cmux.liveRecovery" };

type RecoveryWindow = Pick<Window, "addEventListener" | "setTimeout" | "location" | "sessionStorage" | "document"> & {
  __cmuxLiveNote?: (text: string | null) => void;
  __cmuxLiveConnected?: boolean;
  WebSocket?: typeof WebSocket;
};

/// A failed module load, a failed dynamic import or Vite's preload error: the page cannot run.
export function isModuleFailure(event: Event): boolean {
  if (event.type === "vite:preloadError") return true;
  if (event.type === "unhandledrejection") {
    const reason = (event as PromiseRejectionEvent).reason as { message?: unknown } | undefined;
    const message = typeof reason?.message === "string" ? reason.message : String(reason);
    return /dynamically imported module|importing a module script failed|error loading dynamically imported/i.test(
      message,
    );
  }
  const target = event.target as { tagName?: string; type?: string } | null;
  return event.type === "error" && target?.tagName === "SCRIPT" && target.type === "module";
}

/// Installs the guard on `win`. Inlined as source with ``isModuleFailure``, so it names nothing else.
export function liveRecovery(win: RecoveryWindow, options: typeof LIVE_RECOVERY): void {
  const doc = win.document;
  let host: HTMLElement | null = null;
  const note = (text: string | null) => {
    if (text === null) {
      host?.remove();
      host = null;
      return;
    }
    if (!host) {
      host = doc.createElement("cmux-live-note");
      const root = host.attachShadow({ mode: "open" });
      const pill = doc.createElement("div");
      pill.setAttribute("role", "status");
      pill.style.cssText =
        "position:fixed;right:8px;bottom:8px;z-index:2147483647;max-width:min(360px,80vw);padding:4px 8px;" +
        "border-radius:6px;font:500 11px/1.35 system-ui,-apple-system,sans-serif;color:#fff;background:rgba(32,32,32,.9);box-shadow:0 0 0 0.5px rgba(255,255,255,.18);pointer-events:none";
      root.append(pill);
      (doc.body ?? doc.documentElement).append(host);
    }
    const pill = host.shadowRoot?.firstElementChild as HTMLElement | null;
    if (pill) pill.textContent = text;
  };
  win.__cmuxLiveNote = note;

  // Whether the Vite client holds the server, from its HMR socket (protocol "vite-hmr"): this script
  // runs before /@vite/client, so it sees the socket open even when liveNote.dev.ts, which only hears
  // later vite:ws events, loads after it connected.
  const Native = win.WebSocket;
  if (Native) {
    win.WebSocket = class extends Native {
      constructor(url: string | URL, protocols?: string | string[]) {
        super(url, protocols);
        if (!([] as string[]).concat(protocols ?? []).includes("vite-hmr")) return;
        this.addEventListener("open", () => {
          win.__cmuxLiveConnected = true;
        });
        this.addEventListener("close", () => {
          win.__cmuxLiveConnected = false;
        });
      }
    };
  }

  const read = (): { tries: number; at: number } => {
    try {
      const value = JSON.parse(win.sessionStorage.getItem(options.storageKey) ?? "null") as {
        tries?: unknown;
        at?: unknown;
      } | null;
      if (typeof value?.tries === "number" && typeof value.at === "number") return { tries: value.tries, at: value.at };
    } catch {}
    return { tries: 0, at: 0 };
  };
  let pending = false;
  const recover = (event: Event) => {
    if (pending || !isModuleFailure(event)) return;
    pending = true;
    const last = read();
    const tries = Date.now() - last.at > options.settledMs ? 0 : last.tries;
    if (tries >= options.tries) {
      note("cmux Live: this page's code did not load from the dev server. `cmux live status` says why.");
      return;
    }
    // Decided after the delay, once the Vite client has had the time to connect.
    win.setTimeout(
      () => {
        pending = false;
        if (win.__cmuxLiveConnected) return;
        // A try that cannot be counted is not taken: without the count, reloads would never stop.
        try {
          win.sessionStorage.setItem(options.storageKey, JSON.stringify({ tries: tries + 1, at: Date.now() }));
        } catch {
          note("cmux Live: this page's code did not load from the dev server. `cmux live status` says why.");
          return;
        }
        note("cmux Live: the dev server did not answer. Loading this page again…");
        win.location.reload();
      },
      options.firstDelayMs * 2 ** tries,
    );
  };
  win.addEventListener("error", recover, true);
  win.addEventListener("unhandledrejection", recover);
  win.addEventListener("vite:preloadError", recover);
}

/// The inline script: ``liveRecovery`` on this window.
export const liveRecoveryScript = `(() => { ${isModuleFailure.toString()}\n(${liveRecovery.toString()})(window, ${JSON.stringify(LIVE_RECOVERY)}); })();`;
