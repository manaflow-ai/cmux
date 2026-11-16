import { useEffect, useEffectEvent, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { AppSceneMount } from "../../../apps/scene/appSceneMount";
import { appPanelsDevClient } from "../../../apps/scene/panelsClient";
import { SceneRenderer } from "../../../apps/scene/SceneRenderer";
import type { PageClient } from "../../../pages/shared/pageClient";
import { pageHostClient } from "../pageHost";
import { reportInputReadyWhenFocused } from "./inputReady";
import "./appPage.css";

type Props = {
  /// The extension the person picked (`tabs.newTabApp`), whose `cmux.newtab/1` draws the page.
  app: string;
  /// The folder the new tab starts in: the mount context's `cwd`.
  cwd?: string;
  /// The app is missing, hidden or disabled, failed, drew nothing, did not draw within
  /// ``NEW_TAB_APP_DEADLINE_MS``, or its host went away: the caller draws cmux's own page from then
  /// on and shows why on it (``NewTabAppFailureNotice``). Called once.
  onUnavailable(failure: NewTabAppFailure): void;
  inputToken?: string | undefined;
  onInputReady?(token: string): void;
  /// Tests and the gallery inject their host; the page uses the page host's.
  client?: PageClient | null;
};

/// Why the picked app's page could not show: its mount was refused or failed (the host's reason,
/// which names a script's error and line), it did not draw in time, or it drew nothing visible.
export type NewTabAppFailure = { kind: "failed"; reason: string } | { kind: "slow" } | { kind: "empty" };

/// How long the picked app may take to draw its first scene before the visit gets cmux's own page.
/// A blank page while the daemon is busy is never the answer: the person gets a working page and
/// the reason, and the next Cmd-T tries the app again.
export const NEW_TAB_APP_DEADLINE_MS = 2000;

/// Scene nodes that only lay out their children (SceneRenderer `data-app-type`): on their own they
/// draw nothing, unless the app gave them a fill or a border.
const LAYOUT_ONLY_NODES = new Set([
  "VStack",
  "LazyVStack",
  "HStack",
  "ZStack",
  "Group",
  "ForEach",
  "Reorderable",
  "Spacer",
]);

/// Whether `element` shows anything a person can see: text, an image, a field or a control, or a
/// scene node that draws by itself (a shape, an icon, a spinner, a divider, a panel's box) or has a
/// fill or a border. A scene whose root is only stacks and spacers draws a blank page.
export function drawsSomething(element: Element | null): boolean {
  if (!element) return false;
  if ((element.textContent ?? "").trim()) return true;
  if (element.querySelector("img, input, textarea, select, button, progress, svg, canvas") !== null) return true;
  for (const node of element.querySelectorAll<HTMLElement>("[data-app-type]")) {
    if (!LAYOUT_ONLY_NODES.has(node.dataset.appType ?? "")) return true;
    const { background, backgroundColor, backgroundImage, borderStyle } = node.style;
    if (background || backgroundColor || backgroundImage || (borderStyle && borderStyle !== "none")) return true;
  }
  return false;
}

/// A whole New Tab page drawn by an extension (`cmux.newtab/1`), shown only because the person named
/// it in `tabs.newTabApp`. Nothing shows while its first scene loads, for at most
/// ``NEW_TAB_APP_DEADLINE_MS``. Once its mount is refused, it fails (or its host goes away), it is
/// that late, or its first scene draws nothing visible, it calls `onUnavailable`, and the caller draws cmux's own page for
/// the rest of this page's life, so a reconnect never swaps out a page the person is typing in. It
/// stays mounted while the page lives, also behind another tab (no visibility listener:
/// check:switch-fetches).
export function NewTabAppPage({ app, cwd, onUnavailable, inputToken, onInputReady, client: injected }: Props) {
  const client = injected === undefined ? (pageHostClient() ?? appPanelsDevClient()) : injected;
  const mount = useMemo(() => new AppSceneMount(client, "newTab", app, cwd ? { cwd } : {}), [client, app, cwd]);
  const status = useSyncExternalStore(mount.store.subscribeStatus, mount.store.getStatus, mount.store.getStatus);
  const [gone, setGone] = useState(false);
  const failed = gone || status.state === "failed" || status.state === "disconnected";
  // The page hands the visit back with the reason, which cmux's own page shows in place.
  const unavailable = useEffectEvent((failure: NewTabAppFailure) => {
    if (gone) return;
    setGone(true);
    onUnavailable(failure);
  });
  useEffect(() => {
    if (status.state === "failed" || status.state === "disconnected")
      unavailable({ kind: "failed", reason: status.reason });
  }, [status]);
  // Not drawn in time: cmux's own page, never a blank one.
  useEffect(() => {
    if (status.state !== "loading") return;
    const timer = setTimeout(() => unavailable({ kind: "slow" }), NEW_TAB_APP_DEADLINE_MS);
    return () => clearTimeout(timer);
  }, [status.state]);
  // Drawn, but nothing a person can see (an empty stack, a render that returned only spacers): the
  // signal is what the page drew, not that a scene arrived. The first scene's nodes commit with the
  // root that made the mount ready, so the DOM read after that commit is what the person sees.
  const body = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (status.state === "ready" && !drawsSomething(body.current)) unavailable({ kind: "empty" });
  }, [status.state]);
  useEffect(() => {
    mount.start();
    const stop = () => mount.stop();
    // Native pane retirement can discard the document without unmounting React first.
    globalThis.addEventListener?.("pagehide", stop);
    return () => {
      globalThis.removeEventListener?.("pagehide", stop);
      mount.stop();
    };
  }, [mount]);
  // The app holds the keys typed after Cmd-T until the page says it is ready. The extension's field
  // (an autofocus TextField) exists only once its first scene has committed, so the page is ready
  // then, not while it loads; if it fails, cmux's own page takes over and reports for itself.
  const report = useEffectEvent((token: string) => onInputReady?.(token));
  const drawn = status.state === "ready";
  useEffect(() => {
    if (!inputToken || !drawn) return;
    return reportInputReadyWhenFocused(globalThis.window, () => report(inputToken));
  }, [inputToken, drawn]);
  if (failed) return null;
  return (
    <div className="nt-app-page" data-app={app} data-status={status.state} aria-busy={status.state === "loading"}>
      <div className="nt-app-page-body" ref={body}>
        <SceneRenderer store={mount.store} dispatch={mount.dispatch} resolveAsset={mount.resolveAsset} />
      </div>
    </div>
  );
}
