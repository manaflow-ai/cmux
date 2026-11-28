// l10n-allow-file: gallery fixtures (sample library entries and looks), not shipped UI.
// Settings > Customize (Leo, 2026-11-22, ask-931361017e: "some sort of checklist to be able to
// toggle through customizations", "as few clicks as reasonable, as information-disclosing and
// simultaneously dense as reasonable"), three layouts for the pick (rulebook: more than two
// versions), each searched and with All Switches open, plus the App Store's Customize cmux… card.
// References (cmux-design-references): codex/web/skills-library (capabilities as rows with a switch
// each), claude/live/settings-session-workflows (title and muted line on one text column, switches
// on one trailing edge).
// Shipped: `rows`. One click flips a switch in place, the one short line under each title says what
// it is (the information Leo asked to disclose), and the switches line up on one edge like every
// other Settings row, so the page reads as Settings. `chips` is the densest (a wrap of pills, title
// only) but says nothing about what a switch does and reads in two directions; `menu` looks like
// the app menu's Customizations submenu (check marks, no line) and fits the most rows a screen, but
// a check mark reads as "chosen", not "on", and it hides the help a first-time person needs.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { ChecklistGroup, ChecklistItem, VerifiedLook } from "../customizeChecklist";
import type { ChecklistLayout } from "./CustomizeChecklist";
import type { Standup } from "../ops";

type State = "default" | "searched" | "all-open" | "locked" | "standup";
type Props = { layout: ChecklistLayout | "app-store"; state: State };

/** Looks as the examples folders name them, when the gallery cannot read examples/ itself. */
const SAMPLE_LOOKS: VerifiedLook[] = [
  ["looks/ember", "manaflow-ai/ember-look", "Ember", "Warm dark surfaces with an ember accent."],
  ["looks/hairline", "manaflow-ai/hairline", "Hairline", "One-pixel rules, no fills."],
  ["looks/lamina", "manaflow-ai/lamina", "Lamina", "Layered glass panes."],
  ["looks/paper", "manaflow-ai/paper", "Paper", "A light, printed page."],
  ["recipes/focus", "manaflow-ai/focus", "Focus", "Hide the chrome while you type."],
].map(([folder, id, name, tagline]) => ({
  id: id!,
  name: name!,
  tagline: tagline!,
  folder: folder!,
  reference: `github.com/manaflow-ai/cmux/examples/${folder}@feat-cmux-next`,
}));

async function load() {
  const { installCatalog } = await import("../strings");
  installCatalog((await import("../generated/strings.json")).default);
  const { CustomizeChecklistView } = await import("./CustomizeChecklist");
  const { checklistGroups, toggleRowsByGroup } = await import("../customizeChecklist");
  const { shippedLooks } = await import("../customizeLooks");
  const { schema } = await import("../schema");
  const { homes } = await import("../categories");
  const { mockLibrary } = await import("../mockLibrary");
  const { CustomizeFeature } = await import("../../apps/CustomizeFeature");
  const appStrings = (await import("../../apps/generated/strings.json")).default as Record<
    string,
    Record<string, string>
  >;
  const looks = shippedLooks().length > 0 ? shippedLooks() : SAMPLE_LOOKS;
  const rows = toggleRowsByGroup(schema.rows, (row) => homes.has(row.key));
  const library = mockLibrary();
  // Ember is installed (its library entry is on); the rest wait to be installed.
  library.entries = [
    ...library.entries,
    { ...library.entries[0]!, name: "setup-manaflow-ai-ember-look", position: library.entries.length + 1, on: true },
    // Unmerged code in this build: the yolo merges (Leo, 2026-11-23).
    {
      ...library.entries[0]!,
      name: "pr-43496",
      position: library.entries.length + 2,
      on: true,
      code: {
        pr: 43496,
        repo: "manaflow-ai/cmux",
        title: "Cat icon in the dock",
        head: "4b7d0aa",
        base: "36316c1",
        note: "newer head 9c1e2f0",
      },
    },
    {
      ...library.entries[0]!,
      name: "branch-lane-glass-chrome",
      position: library.entries.length + 3,
      on: false,
      code: {
        kind: "branch",
        source: "lane/glass-chrome",
        repo: "manaflow-ai/cmux",
        pr: 0,
        title: "Glass chrome",
        head: "5e21c3d",
        base: "36316c1",
      },
    },
  ];
  const standup: Standup = {
    on: 3,
    lines: [
      {
        name: "pr-43496",
        kind: "pr",
        on: true,
        title: "#43496 Cat icon in the dock",
        status: "on · newer head 9c1e2f0",
        link: "https://github.com/manaflow-ai/cmux/pull/43496",
      },
      {
        name: "branch-lane-glass-chrome",
        kind: "branch",
        on: false,
        title: "branch lane/glass-chrome: Glass chrome",
        status: "off",
        link: "https://github.com/manaflow-ai/cmux/tree/lane/glass-chrome",
      },
      {
        name: "setup-manaflow-ai-ember-look",
        kind: "setup",
        on: true,
        title: "Ember (manaflow-ai/ember-look)",
        status: "on",
        link: "https://github.com/manaflow-ai/ember-look",
      },
      { name: "night", kind: "recipe", on: true, title: "night: a darker theme at night", status: "on" },
    ],
    text: "",
  };
  const en = appStrings.en!;
  const strings = {
    language: "en",
    t: (key: string) => en[key] ?? key,
    format: (key: string, ...args: string[]) => args.reduce((text, arg) => text.replace("%@", arg), en[key] ?? key),
  };
  return function CustomizeChecklistLayouts({ layout, state }: Props) {
    const [on, setOn] = useState<Record<string, boolean>>({ "labs.liveTree": true });
    const [query, setQuery] = useState(state === "searched" ? "sidebar" : "");
    if (layout === "app-store") {
      return (
        <section className="apps-page" style={{ padding: 16 }}>
          <CustomizeFeature
            store={{ openCustomize: async () => {} }}
            strings={strings}
            looks={looks}
            open={state === "all-open"}
          />
        </section>
      );
    }
    const groups: ChecklistGroup[] = checklistGroups({
      rows,
      value: (key) => on[key] === true,
      locked: (key) => (state === "locked" && key.startsWith("browser.") ? "Set by your team's device profile" : null),
      library,
      libraryLocked: null,
      looks,
      standup,
    });
    const onToggle = (item: ChecklistItem, next: boolean) => {
      if (item.group === "experiments" || item.group === "labs" || item.group === "all")
        setOn((before) => ({ ...before, [item.id]: next }));
    };
    return (
      <section className="settings-page" style={{ padding: 16 }}>
        <CustomizeChecklistView
          groups={groups}
          query={query}
          onQuery={setQuery}
          onToggle={onToggle}
          layout={layout}
          allOpen={state === "all-open" || state === "locked"}
          standup={standup}
          standupOpen={state === "standup"}
        />
      </section>
    );
  };
}

const LAYOUTS: Record<ChecklistLayout, string> = {
  rows: "Shipped: Settings rows, switch on the trailing edge, one short line under each title",
  chips: "A wrap of pill toggles, title only",
  menu: "A menu-like list with check marks, no line",
};
const STATES: Record<State, string> = {
  default: "as it opens: All Switches closed",
  searched: "searched for sidebar: every group filtered at once",
  "all-open": "All Switches open",
  locked: "All Switches open, browser keys managed by the team",
  standup: "Standup open: every PR, repo and recipe as one line with its state and link, Copy for the Markdown",
};

const variants: Record<string, { note: string; props: Props }> = {};
for (const layout of Object.keys(LAYOUTS) as ChecklistLayout[]) {
  for (const state of Object.keys(STATES) as State[]) {
    variants[`${layout}-${state}`] = { note: `${LAYOUTS[layout]}; ${STATES[state]}.`, props: { layout, state } };
  }
}
variants["app-store-card"] = {
  note: "The App Store's Customize cmux… card at the top of Discover, closed: names the first looks; Show All opens it.",
  props: { layout: "app-store", state: "default" },
};
variants["app-store-card-open"] = {
  note: "The card after one click on Show All: every verified look and switch group, each opening Settings > Customize, and a link to it.",
  props: { layout: "app-store", state: "all-open" },
};

export default componentEntry<Props>({
  id: "settings.customize-checklist",
  title: "Customize checklist",
  area: "Settings",
  height: 720,
  widths: { narrow: 420, normal: 720, wide: 980 },
  covers: [
    "pages/settings/components/CustomizeChecklist.tsx#CustomizeChecklistView",
    "pages/apps/CustomizeFeature.tsx#CustomizeFeature",
  ],
  load,
  styles: async () => {
    await import("../../apps/styles.css");
    return import("../page.css");
  },
  variants,
});
