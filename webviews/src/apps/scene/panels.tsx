import { useEffect, useMemo, useSyncExternalStore, type ReactNode } from "react";
import { pageHostClient } from "../../agent-session/acpmux/pageHost";
import { SessionInfoSection } from "../../agent-session/acpmux/session-info/SessionInfoSection";
import type { SessionInfoSectionId } from "../../agent-session/acpmux/session-info/sessionInfoState";
import type { PageClient } from "../../pages/shared/pageClient";
import { SceneRenderer } from "./SceneRenderer";
import { appSceneIcon } from "./SceneSymbol";
import { AppPanelsClient, appPanelsDevClient, panelId, type MountContext } from "./panelsClient";
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
      panels.map(({ panel, store, dispatch }) => {
        const id = panelId(panel);
        return {
          id,
          title: panel.title,
          symbol: panel.symbol,
          node: <SceneRenderer key={id} store={store} dispatch={dispatch} />,
        };
      }),
    [panels],
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
