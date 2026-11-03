import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { pageHostClient } from "../../agent-session/acpmux/pageHost";
import { SessionInfoSection } from "../../agent-session/acpmux/session-info/SessionInfoSection";
import type { SessionInfoSectionId } from "../../agent-session/acpmux/session-info/sessionInfoState";
import { registerAppSectionIds } from "../../agent-session/acpmux/session-info/sectionOrder";
import { SceneRenderer } from "./SceneRenderer";
import { SceneStore, type SceneOp } from "./store";
export type AppPanel = { app: string; section: string; title: string; symbol?: string };
type SceneEvent = { mount_id: string; ops?: SceneOp[]; reset?: boolean };
type MountContext = { session_id: string; cwd?: string; branch?: string; harness?: string };
export type AppPanelSection = { id: SessionInfoSectionId; title: string; symbol?: string; node: ReactNode };
const idFor = (panel: AppPanel): SessionInfoSectionId => `app:${panel.app}#${panel.section}` as SessionInfoSectionId;
const isUnknownHost = (error: unknown) => typeof error === "object" && error !== null && "code" in error && String((error as { code?: unknown }).code).includes("unknown_op");
export function useAppPanelSections(context: MountContext | undefined): AppPanelSection[] {
  const [panels, setPanels] = useState<AppPanel[]>([]);
  const [, redraw] = useState(0);
  const stores = useRef(new Map<string, SceneStore>());
  const mounts = useRef(new Map<string, { mountId: string; stop: () => void }>()).current;
  const client = pageHostClient();
  const mock = typeof location !== "undefined" && new URLSearchParams(location.search).has("mock");
  const load = useCallback(async () => {
    if (!client || !context?.session_id) {
      const mockPanel = mock && context?.session_id ? [{ app: "github-prs", section: "recent", title: "Recent PRs", symbol: "git.pullrequest" }] : [];
      setPanels(mockPanel); registerAppSectionIds(mockPanel.map(idFor)); return;
    }
    try {
      const result = await client.call<{ panels?: AppPanel[] }>("cmux.apps.panels.list", {});
      const next = Array.isArray(result?.panels) ? result.panels.filter((panel) => panel && panel.app && panel.section && panel.title) : [];
      setPanels(next); registerAppSectionIds(next.map(idFor));
    } catch (error) { if (!isUnknownHost(error)) setPanels([]); }
  }, [client, context?.session_id, mock]);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => {
    if (!client) return;
    let stop: (() => void) | undefined; let active = true;
    void client.subscribe("cmux.apps.panels.changed", () => { if (active) void load(); }).then((unsubscribe) => { stop = unsubscribe; }).catch(() => undefined);
    return () => { active = false; stop?.(); };
  }, [client, load]);
  useEffect(() => {
    if (!client || !context?.session_id) return;
    const wanted = new Set(panels.map((panel) => idFor(panel)));
    for (const [id, mounted] of mounts) if (!wanted.has(id)) {
      void client.call("cmux.apps.panels.unmount", { mount_id: mounted.mountId }).catch(() => undefined);
      mounted.stop(); mounts.delete(id); stores.current.delete(id);
    }
    let disposed = false;
    for (const panel of panels) {
      const id = idFor(panel); if (mounts.has(id)) continue;
      const store = stores.current.get(id) ?? new SceneStore(); stores.current.set(id, store);
      void client.call<{ mount_id?: string }>("cmux.apps.panels.mount", { app: panel.app, section: panel.section, context }).then(async (result) => {
        if (!result?.mount_id) return;
        const mountId = result.mount_id;
        if (disposed) { void client.call("cmux.apps.panels.unmount", { mount_id: mountId }).catch(() => undefined); return; }
        const unsubscribe = await client.subscribe<SceneEvent>("cmux.apps.panels.scene", (event) => {
          if (event?.mount_id !== mountId || !Array.isArray(event.ops)) return;
          store.apply(event.ops, event.reset === true); redraw((value) => value + 1);
        }, { mount_id: mountId });
        if (disposed) { unsubscribe(); void client.call("cmux.apps.panels.unmount", { mount_id: mountId }).catch(() => undefined); return; }
        mounts.set(id, { mountId, stop: unsubscribe }); redraw((value) => value + 1);
      }).catch(() => undefined);
    }
    return () => { disposed = true; };
  }, [client, context, panels, mounts]);
  useEffect(() => () => {
    if (!client) return;
    for (const mounted of mounts.values()) { mounted.stop(); void client.call("cmux.apps.panels.unmount", { mount_id: mounted.mountId }).catch(() => undefined); }
    mounts.clear(); stores.current.clear();
  }, [client, mounts]);
  return useMemo(() => panels.map((panel) => {
    const id = idFor(panel); const store = stores.current.get(id) ?? new SceneStore(); stores.current.set(id, store);
    if (mock && !store.getRoot()) {
      store.apply([{ op: "create", id: `${id}:root`, type: "VStack" }, { op: "create", id: `${id}:pr`, type: "Row", props: { title: "cmux #32944", subtitle: "Recent pull request", symbol: "pullRequest", badge: "open", onTap: true } }, { op: "create", id: `${id}:session`, type: "Row", props: { title: "Session app", subtitle: "Local · running", symbol: "terminal" } }, { op: "children", id: `${id}:root`, children: [`${id}:pr`, `${id}:session`] }, { op: "root", id: `${id}:root` }]);
    }
    const dispatch = (node: string, event: string, payload?: unknown) => {
      const mounted = mounts.get(id); if (!mounted || !client) return;
      void client.call("cmux.apps.panels.dispatch", { mount_id: mounted.mountId, node, event, payload }).catch(() => undefined);
    };
    return { id, title: panel.title, symbol: panel.symbol, node: <SceneRenderer key={id} store={store} dispatch={dispatch} /> };
  }), [client, mock, mounts, panels]);
}
export function AppPanelSection({ section, open = true, onOpenChange }: { section: AppPanelSection; open?: boolean; onOpenChange?: (open: boolean) => void }) {
  return <SessionInfoSection id={section.id} title={section.title} icon={section.symbol} open={open} onOpenChange={onOpenChange}>{section.node}</SessionInfoSection>;
}
