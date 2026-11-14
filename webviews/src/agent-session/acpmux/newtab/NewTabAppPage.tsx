import { useEffect, useEffectEvent, useMemo, useSyncExternalStore } from "react";
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
  /// The app is missing, hidden or disabled, or failed, or its host went away: the caller draws
  /// cmux's own page from then on. Called once.
  onUnavailable(): void;
  inputToken?: string | undefined;
  onInputReady?(token: string): void;
  /// Tests and the gallery inject their host; the page uses the page host's.
  client?: PageClient | null;
};

/// A whole New Tab page drawn by an extension (`cmux.newtab/1`), shown only because the person named
/// it in `tabs.newTabApp`. Nothing shows while its first scene loads. Once its mount is refused or it
/// fails (or its host goes away) it calls `onUnavailable`, and the caller draws cmux's own page for
/// the rest of this page's life, so a reconnect never swaps out a page the person is typing in. It
/// stays mounted while the page lives, also behind another tab (no visibility listener:
/// check:switch-fetches).
export function NewTabAppPage({ app, cwd, onUnavailable, inputToken, onInputReady, client: injected }: Props) {
  const client = injected === undefined ? (pageHostClient() ?? appPanelsDevClient()) : injected;
  const mount = useMemo(() => new AppSceneMount(client, "newTab", app, cwd ? { cwd } : {}), [client, app, cwd]);
  const status = useSyncExternalStore(mount.store.subscribeStatus, mount.store.getStatus, mount.store.getStatus);
  const failed = status.state === "failed" || status.state === "disconnected";
  // The reason stays in the app's log (`cmux apps logs`); the page only draws cmux's own.
  const unavailable = useEffectEvent(() => onUnavailable());
  useEffect(() => {
    if (failed) unavailable();
  }, [failed]);
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
  // The app holds the keys typed after Cmd-T until the page says it is ready. This page has no
  // field, so it is ready as soon as it shows (cmux's own page, if it takes over, reports for itself).
  const report = useEffectEvent((token: string) => onInputReady?.(token));
  useEffect(() => {
    if (!inputToken) return;
    return reportInputReadyWhenFocused(globalThis.window, () => report(inputToken));
  }, [inputToken]);
  if (failed) return null;
  return (
    <div className="nt-app-page" data-app={app} data-status={status.state} aria-busy={status.state === "loading"}>
      <div className="nt-app-page-body">
        <SceneRenderer store={mount.store} dispatch={mount.dispatch} resolveAsset={mount.resolveAsset} />
      </div>
    </div>
  );
}
