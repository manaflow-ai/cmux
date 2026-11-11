// l10n-allow-file: gallery fixtures, not shipped UI.
// The New Tab page with installed apps' widgets (`cmux.newtab.widget/1`, ExtensionWidgets.tsx): the
// example clock (examples/extensions/clock), a wide review list and a widget that draws past the
// interface's node cap, through the real panels client against the panels mock (list, layout, mount,
// scene, unmount), in the page's widget row beside the built-in widgets.
import type { ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import { noChat } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { NewTabScreen } from "./NewTabScreen";
import type { PageWidget } from "./pageWidgets";

const CLOCK = "app:manaflow-ai/clock#cmux.newtab.widget/1";
const PRS = "app:samples/github-prs#cmux.newtab.widget/1";
const TOO_BIG = "app:samples/too-big#cmux.newtab.widget/1";

type Props = {
  /// The person's saved layout (the daemon's `apps-newtab-layout.json`).
  layout: string[];
  /// The built-in widgets on (`tabs.newTabWidgets.*`).
  builtins?: PageWidget[];
  /// Apps whose mount fails.
  failing?: string[];
};

const base: Omit<ComponentProps<typeof NewTabScreen>, "widgetClient"> = {
  snapshot: noChat([], { catalog: [] }),
  home: "/Users/you",
  cwd: "/Users/you/atlas",
  projects: [{ cwd: "/Users/you/atlas", label: "atlas" }],
  knownProjects: null,
  onAsk: () => {},
  onOpen: () => {},
  onSearch: () => {},
  onShell: () => {},
  onJump: () => {},
  onOpenSession: () => {},
  onShowAll: () => {},
  onBrowseProject: async () => undefined,
  template: "minimal",
};

const cells = (ctx: Parameters<Play>[0]) => [...ctx.document.querySelectorAll(".nt-extras > *")];
/// Every placed widget drew (its scene, or its notice).
const drawn =
  (count: number): Play =>
  async (ctx) => {
    await ctx.waitFor(
      () =>
        ctx.document.querySelectorAll(".nt-ext-widget [data-app-type], .nt-ext-widget-notice").length > 0 &&
        ctx.document.querySelectorAll(".nt-ext-widget").length === count,
    );
  };

export default componentEntry<Props>({
  id: "agent-pane.newtab-app-widgets",
  title: "New Tab widgets from apps",
  area: "New Tab",
  height: 620,
  pane: true,
  covers: [
    "agent-session/acpmux/newtab/ExtensionWidgets.tsx",
    "agent-session/acpmux/newtab/NewTabExtras.tsx",
    "agent-session/acpmux/newtab/WidgetEditing.tsx",
    "apps/scene/panelsClient.ts",
    "apps/scene/SceneRenderer.tsx",
  ],
  load: async () => {
    const [{ NewTabScreen }, { MockAppPanelsClient }, { editedPageWidgets }, { useState }] = await Promise.all([
      import("./NewTabScreen"),
      import("../../../apps/scene/panelsMock"),
      import("./pageWidgets"),
      import("react"),
    ]);
    return function AppWidgetsPage({ layout, builtins = [], failing = [] }: Props) {
      const [client] = useState(() => {
        const mock = new MockAppPanelsClient();
        mock.layout = [...layout];
        for (const app of failing) mock.failing.add(app);
        return mock;
      });
      const [widgets, setWidgets] = useState<PageWidget[]>(builtins);
      return (
        <NewTabScreen
          {...base}
          pageWidgets={new Set(widgets)}
          widgetClient={client}
          onEditWidgets={(edit) => setWidgets((current) => editedPageWidgets(current, edit))}
        />
      );
    };
  },
  styles: () => Promise.all([import("../styles.css"), import("./screen.css"), import("../../../apps/scene/scene.css")]),
  variants: {
    "clock-only": {
      note: "Recommended first look: the example clock app alone under the composer, in the widget row's own type and inks (the time a title step, the date a caption), no card or app label around it.",
      props: { layout: [CLOCK] },
      play: drawn(1),
    },
    "with-built-ins-reordered": {
      note: "The app clock and a wide app list placed between the built-in greeting, stopwatch and quote, in the order the person dragged them; a wide widget takes the row's whole width as the quote does.",
      props: { layout: ["warmGreeting", CLOCK, "timer", PRS, "quote"], builtins: ["warmGreeting", "timer", "quote"] },
      play: async (ctx) => {
        await drawn(2)(ctx);
        const order = cells(ctx).map(
          (cell) => cell.getAttribute("data-app") ?? cell.className.replace(/^nt-extra-/, "").split(" ")[0],
        );
        if (order.join() !== "warm,manaflow-ai/clock,timer,samples/github-prs,quote")
          throw new Error(`unexpected row order ${order.join()}`);
      },
    },
    "error-and-over-budget": {
      note: "Two widgets that cannot draw: one whose app failed to mount, one whose scene went past the interface's 64 nodes. Each cell keeps its name and says why; the clock beside them and the page are untouched.",
      props: { layout: [CLOCK, PRS, TOO_BIG], failing: ["samples/github-prs"] },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelectorAll(".nt-ext-widget-notice").length === 2);
      },
    },
    "edit-mode": {
      note: "Edit New Tab: built-in and app widgets wiggle alike, each with its ✕; drag along the row or Option-Left / Option-Right moves one; Add Widgets lists the apps' widgets not yet placed after the built-in ones.",
      props: { layout: ["timer", CLOCK, PRS], builtins: ["timer"] },
      play: async (ctx) => {
        await drawn(2)(ctx);
        // On the widget row, as a person would: the trusted right-click lands at its target's centre, and
        // the screen's centre is the composer, which keeps its own menu (NewTabScreen's ContextMenu `ignore`).
        await ctx.contextMenu({ selector: ".nt-extras" });
        await ctx.click({ role: "menuitem", name: "Edit New Tab" });
        await ctx.waitFor(() => ctx.document.querySelectorAll(".nt-grid-frame .nt-widget-remove").length === 3);
        await ctx.click({ selector: '.nt-edit-button[data-menu="newtab-add-widget"]' });
        await ctx.waitFor(
          () => ctx.document.querySelector('.nt-edit-add-menu [data-value="' + TOO_BIG + '"]') !== null,
        );
      },
    },
  },
});
