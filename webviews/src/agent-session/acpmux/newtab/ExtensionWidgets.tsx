// New Tab widgets from apps (`cmux.newtab.widget/1`, cmux-app-host/interfaces/cmux.newtab.widget/1.json):
// an installed app's widget is drawn in the page's widget row beside the built-in ones (clock, timer,
// quote), through the same scene renderer as Session Info's app sections, in the row's own inks.
// The person places, removes and moves them in the page's edit mode; their layout (placed widgets and
// the row's order, built-ins included) is the daemon's (`apps.panels.layout.set`), so it is the same on
// every New Tab page.
//
// Cost (extensibility-DESIGN.md R1): nothing mounts while the page is hidden or no widget is placed.
// The listing reads the daemon's catalog only; an app's VM starts at its widget's first mount. A switch
// away and back reads nothing (shared-projections.md): the mounts stay through a short hide, and end
// only once the page has been hidden for WIDGETS_HIDDEN_GRACE_MS (the same 60 s as a hidden sidebar
// panel, extensibility-DESIGN.md section 4), when it closes (pagehide) or unmounts, which also stops
// the app's timers (they belong to the mount). A widget that fails or draws past the interface's limits
// (`nodes`, `maxNodes`) shows its name and why in its cell; the page around it is untouched.
import { useEffect, useMemo, useState, useSyncExternalStore } from "react";
import {
  appPanelsDevClient,
  AppPanelsClient,
  panelId,
  type AppPanel,
  type MountedPanel,
  type PanelsView,
} from "../../../apps/scene/panelsClient";
import { SceneRenderer } from "../../../apps/scene/SceneRenderer";
import type { PageClient } from "../../../pages/shared/pageClient";
import { Icon } from "../icons/Icon";
import { pageHostClient } from "../pageHost";
import { useNt } from "./strings";

export const NEW_TAB_WIDGET_INTERFACE = "cmux.newtab.widget/1";
/** The interface file's `nodes` and `maxNodes` (cmux.newtab.widget/1.json). */
export const NEW_TAB_WIDGET_NODES: ReadonlySet<string> = new Set([
  "VStack",
  "HStack",
  "Group",
  "Text",
  "Icon",
  "Spacer",
  "Divider",
  "Badge",
  "Row",
  "Button",
  "ProgressView",
  "EmptyState",
]);
export const NEW_TAB_WIDGET_MAX_NODES = 64;

/** The built-in widgets of the row, in their default order (NewTabExtras.tsx). */
export const GRID_BUILTINS = ["warmGreeting", "clock", "timer", "quote"] as const;
export type GridBuiltin = (typeof GRID_BUILTINS)[number];

export type NewTabExtensionWidgets = {
  /** Every widget the installed apps offer (Add Widgets lists the ones not placed). */
  readonly available: readonly AppPanel[];
  /** The person's layout: widget ids (`app:<id>#<interface>`) and built-in names, in order. */
  readonly layout: readonly string[];
  /** The placed widgets, mounted while the page shows. */
  readonly mounted: readonly MountedPanel[];
  /** The host keeps the layout (`apps.panels.layout.set`). Until it does (the Mac bridge passes
   * only Session Info through today), the row has no app widgets to add and no edit frames. */
  readonly editable: boolean;
  setLayout(layout: readonly string[]): void;
};

const NO_WIDGETS: NewTabExtensionWidgets = {
  available: [],
  layout: [],
  mounted: [],
  editable: false,
  setLayout: () => undefined,
};

/** How long the page stays hidden before its widgets' mounts end. A switch to another tab and back
 * inside it keeps every mount and reads nothing; a page left hidden longer costs nothing. */
export const WIDGETS_HIDDEN_GRACE_MS = 60_000;

const pageHidden = () => typeof document !== "undefined" && document.visibilityState === "hidden";

/** Whether the page's widgets are mounted: from the first time the page shows until it has been hidden
 * for `graceMs`. Showing the page again inside the grace changes nothing, so a switch reads nothing. */
export function useWidgetsLive(graceMs = WIDGETS_HIDDEN_GRACE_MS): boolean {
  const [live, setLive] = useState(() => !pageHidden());
  useEffect(() => {
    if (typeof document === "undefined") return;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const follow = () => {
      if (!pageHidden()) {
        if (timer !== undefined) clearTimeout(timer);
        timer = undefined;
        setLive(true);
      } else if (timer === undefined) {
        timer = setTimeout(() => {
          timer = undefined;
          setLive(false);
        }, graceMs);
      }
    };
    follow();
    // ui-allow: a page hidden past the grace ends its app widgets' mounts (R1); a switch reads nothing.
    document.addEventListener("visibilitychange", follow);
    return () => {
      if (timer !== undefined) clearTimeout(timer);
      document.removeEventListener("visibilitychange", follow);
    };
  }, [graceMs]);
  return live;
}

/** The page's app widgets. `injected` is the gallery's or a test's client; the page host's otherwise
 * (none in a browser without the dev mock: no widgets, no calls). */
export function useNewTabExtensionWidgets(injected?: PageClient | null): NewTabExtensionWidgets {
  const client = injected === undefined ? (pageHostClient() ?? appPanelsDevClient()) : injected;
  const owner = useMemo(
    () =>
      client
        ? new AppPanelsClient(
            client,
            { surface: "newTab" },
            {
              interface: NEW_TAB_WIDGET_INTERFACE,
              limits: { maxNodes: NEW_TAB_WIDGET_MAX_NODES, types: NEW_TAB_WIDGET_NODES },
              // Only a placed widget mounts: an installed app nobody placed costs nothing here.
              mounts: (panel, layout) => layout.includes(panelId(panel)),
            },
          )
        : undefined,
    [client],
  );
  const live = useWidgetsLive();
  const view = useSyncExternalStore(
    owner?.subscribe ?? NOOP_SUBSCRIBE,
    owner?.getView ?? EMPTY_VIEW_READ,
    owner?.getView ?? EMPTY_VIEW_READ,
  );
  useEffect(() => {
    if (!owner || !live) return;
    owner.start();
    const stop = () => owner.stop();
    // Native pane retirement can discard the document without unmounting React first.
    globalThis.addEventListener?.("pagehide", stop);
    return () => {
      globalThis.removeEventListener?.("pagehide", stop);
      owner.stop();
    };
  }, [owner, live]);
  return useMemo(
    () =>
      owner && live
        ? {
            available: view.panels,
            layout: view.layout,
            mounted: view.mounted,
            editable: view.editable,
            setLayout: (layout: readonly string[]) => owner.setLayout(layout),
          }
        : NO_WIDGETS,
    [owner, live, view],
  );
}
const NOOP_SUBSCRIBE = () => () => undefined;
const EMPTY_VIEW: PanelsView = { panels: [], layout: [], mounted: [], editable: false };
const EMPTY_VIEW_READ = () => EMPTY_VIEW;

/** The row's cells in the person's order: the ones the layout names first, in its order, then the
 * rest (built-ins in their default order, then app widgets as listed). */
export function gridOrder(ids: readonly string[], layout: readonly string[]): string[] {
  const at = new Map(layout.map((id, index) => [id, index]));
  return ids
    .map((id, index) => ({ id, rank: at.get(id) ?? layout.length + index }))
    .sort((a, b) => a.rank - b.rank)
    .map((entry) => entry.id);
}

/** One app widget's cell: its scene in the row's inks, or its name and why it draws nothing. */
export function ExtensionWidgetCell({ widget }: { widget: MountedPanel }) {
  const nt = useNt();
  const { panel, problem } = widget;
  return (
    <section
      className="nt-ext-widget"
      data-size={panel.size ?? "small"}
      data-problem={problem?.kind}
      data-app={panel.app}
      aria-label={panel.title}
    >
      {problem ? (
        <output className="nt-ext-widget-notice">
          <Icon name="status.warning" size={12} />
          <span>{nt(problem.kind === "failed" ? "extWidget.failed" : "extWidget.over", { name: panel.title })}</span>
        </output>
      ) : (
        <SceneRenderer store={widget.store} dispatch={widget.dispatch} resolveAsset={widget.resolveAsset} />
      )}
    </section>
  );
}
