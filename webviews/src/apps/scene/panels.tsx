import { useEffect, useMemo, useRef, useSyncExternalStore, type ReactNode } from "react";
import { pageHostClient } from "../../agent-session/acpmux/pageHost";
import { SessionInfoSection } from "../../agent-session/acpmux/session-info/SessionInfoSection";
import type { SessionInfoSectionId } from "../../agent-session/acpmux/session-info/sessionInfoState";
import type { PageClient } from "../../pages/shared/pageClient";
import { SceneFailure, SceneReloadMarker } from "./SceneFailure";
import { SceneRenderer } from "./SceneRenderer";
import { appSceneIcon } from "./SceneSymbol";
import { AppPanelsClient, appPanelsDevClient, panelId, type MountContext, type MountedScene } from "./panelsClient";
export type { AppPanel, MountContext } from "./panelsClient";
export type AppPanelSection = { id: SessionInfoSectionId; title: string; symbol?: string; node: ReactNode };

export function useAppPanelSections(
  context: MountContext | undefined,
  injectedClient?: PageClient | null,
): AppPanelSection[] {
  const client = injectedClient === undefined ? (pageHostClient() ?? appPanelsDevClient()) : injectedClient;
  const sessionId = context?.session_id;
  const cwd = context?.cwd;
  const branch = context?.branch;
  const harness = context?.harness;
  // A fresh inline context object on a transcript update never restarts a mount.
  const owner = useMemo(
    () =>
      new AppPanelsClient(
        client,
        sessionId
          ? {
              session_id: sessionId,
              ...(cwd !== undefined && { cwd }),
              ...(branch !== undefined && { branch }),
              ...(harness !== undefined && { harness }),
            }
          : undefined,
      ),
    [client, sessionId, cwd, branch, harness],
  );
  const panels = useSyncExternalStore(owner.subscribe, owner.getSnapshot, owner.getSnapshot);
  useEffect(() => {
    owner.start();
    const stop = () => owner.stop();
    // Native pane retirement can discard the document without unmounting React first.
    globalThis.addEventListener?.("pagehide", stop);
    return () => {
      globalThis.removeEventListener?.("pagehide", stop);
      owner.stop();
    };
  }, [owner]);
  return useMemo(
    () =>
      panels.map((mounted) => {
        const id = panelId(mounted.panel);
        return {
          id,
          title: mounted.panel.title,
          symbol: mounted.panel.symbol,
          node: <SceneMount key={id} mounted={mounted} />,
        };
      }),
    [panels],
  );
}

/** One mounted scene as the host's model draws it: nothing while loading, the scene once ready, and
 * the failure row (Reload, Copy Error, Details) or the disconnected line in its place. A ready scene
 * whose app's last save did not load keeps drawing and says so in the marker line under it. Reports
 * its drawn height to the host (`layout`) whenever it changes. */
export function SceneMount({ mounted }: { mounted: MountedScene }) {
  const { store, dispatch, reload, layout, resolveAsset } = mounted;
  const status = useSyncExternalStore(store.subscribeStatus, store.getStatus, store.getStatus);
  const reloadFailure = useSyncExternalStore(
    store.subscribeReloadFailure,
    store.getReloadFailure,
    store.getReloadFailure,
  );
  const box = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const element = box.current;
    if (!element) return;
    layout(element.getBoundingClientRect().height);
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver((entries) => {
      const entry = entries[entries.length - 1];
      if (entry) layout(entry.target.getBoundingClientRect().height);
    });
    observer.observe(element);
    return () => observer.disconnect();
  }, [layout]);
  return (
    <div ref={box} className="cmux-app-scene-mount" data-status={status.state}>
      {status.state === "failed" || status.state === "disconnected" ? (
        <SceneFailure status={status} onReload={reload} />
      ) : (
        <>
          <SceneRenderer store={store} dispatch={dispatch} resolveAsset={resolveAsset} />
          {status.state === "ready" && reloadFailure ? <SceneReloadMarker reason={reloadFailure} /> : null}
        </>
      )}
    </div>
  );
}

export function AppPanelSection({
  section,
  open = true,
  onOpenChange,
}: {
  section: AppPanelSection;
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
}) {
  return (
    <SessionInfoSection
      id={section.id}
      title={section.title}
      icon={section.symbol ? appSceneIcon(section.symbol) : undefined}
      open={open}
      onOpenChange={onOpenChange}
    >
      {section.node}
    </SessionInfoSection>
  );
}
