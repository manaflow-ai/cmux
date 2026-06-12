/** The webview surface kinds the entry can boot. */
export type WebviewKind = "agent-session" | "diff" | "editor";

/** A surface mount function: given the root element, render the surface. */
export type SurfaceMount = (root: HTMLElement) => void | Promise<void>;

/** Injectable environment so the boot orchestration is testable without a real page. */
export type SurfaceBootEnv = {
  root: HTMLElement;
  kind: WebviewKind;
  /** Lazily imports the surface chunk and resolves its mount function. */
  load: () => Promise<SurfaceMount>;
  /** Re-requests the page (real impl: `window.location.reload()`). */
  reload: () => void;
  /** One-shot reload guard store (real impl: `window.sessionStorage`). */
  storage: Pick<Storage, "getItem" | "setItem" | "removeItem">;
  /** Failure sink (real impl: `console.error`). */
  onError?: (message: string, error: unknown) => void;
};

const RELOAD_FLAG = "cmuxSurfaceBootReloaded";

/**
 * Boots a webview surface such that a blank `#root` is never a terminal state.
 *
 * A surface boots by lazily importing its chunk and calling its mount fn. Any
 * failure on that path — the lazy chunk 404ing because a session-restored
 * page's custom-scheme token is no longer registered, a mount-time throw, a
 * transient asset hiccup — previously rejected an unhandled promise and left
 * `#root` empty forever (a silent blank surface). This orchestration instead:
 * auto-reloads ONCE (which re-requests the page through the scheme handler and
 * often self-heals a transient/registration failure), and if a reloaded
 * attempt still fails, renders a visible error with a manual retry. The
 * one-shot flag in `storage` bounds the auto-reload so a hard failure can't
 * loop.
 *
 * - Returns a promise that resolves once boot settles (mounted, reloaded, or
 *   error-rendered) so tests can await it.
 */
export async function bootSurface(env: SurfaceBootEnv): Promise<void> {
  const report = (stage: string, error: unknown) => {
    env.onError?.(`[cmux] ${env.kind} surface ${stage} failed`, error);
    if (env.storage.getItem(RELOAD_FLAG) === "1") {
      renderSurfaceBootError(env.root, env.kind, env.storage, env.reload);
      return;
    }
    env.storage.setItem(RELOAD_FLAG, "1");
    env.reload();
  };

  let mount: SurfaceMount;
  try {
    mount = await env.load();
  } catch (error) {
    report("import", error);
    return;
  }
  try {
    await mount(env.root);
    // A clean mount clears the one-shot guard so a later genuine failure can
    // still get its single auto-reload.
    env.storage.removeItem(RELOAD_FLAG);
  } catch (error) {
    report("mount", error);
  }
}

/** Minimal, dependency-free error UI shown when a surface cannot boot. */
export function renderSurfaceBootError(
  root: HTMLElement,
  kind: WebviewKind,
  storage: Pick<Storage, "removeItem">,
  reload: () => void,
): void {
  root.textContent = "";
  const wrap = root.ownerDocument.createElement("div");
  wrap.dataset.cmuxSurfaceBootError = "true";
  wrap.style.cssText =
    "display:flex;flex-direction:column;gap:12px;align-items:center;justify-content:center;" +
    "height:100vh;font-family:-apple-system,BlinkMacSystemFont,sans-serif;font-size:13px;" +
    "color:#888;text-align:center;padding:24px;box-sizing:border-box;";
  const msg = root.ownerDocument.createElement("div");
  msg.textContent = `The ${kind} view failed to load.`;
  const btn = root.ownerDocument.createElement("button");
  btn.textContent = "Reload";
  btn.style.cssText =
    "padding:4px 12px;border-radius:6px;border:1px solid #666;background:transparent;" +
    "color:inherit;font:inherit;cursor:pointer;";
  btn.addEventListener("click", () => {
    storage.removeItem(RELOAD_FLAG);
    reload();
  });
  wrap.append(msg, btn);
  root.append(wrap);
}
