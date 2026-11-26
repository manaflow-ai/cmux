// l10n-allow-file: gallery fixtures (notes for the pick), not shipped UI.
// The Customize cmux checklist's layouts, side by side for the pick (rulebook: 3+ versions), each
// fresh, part way and all done. Leo, 2026-11-22: "a customizations checklist. actually, this needs to
// be SOMEWHERE as a default. not just for me."
// Shipped: `card`, Settings > General's first card. General is where Settings opens, so everyone sees
// it with no setup, and a Settings card is where every step's link lands: an Open goes one section
// over, never out of the window. It shows the next five steps left (not all fifteen, so General stays
// short) with Show All a click away, and the × puts it away until General's switch brings it back.
// `newTab` is one line with the next step, but the New Tab page belongs to the person's own choice
// of page (tabs.newTabTemplate), so a checklist there would cover what they picked. `ring` fits a
// sidebar footer, but a ring and a count say nothing of what to do. `sheet` lists every step at
// first launch, which is a wall of fifteen rows before the person has seen cmux.
import { componentEntry } from "../../../gallery/format";
import type { Checklist } from "../ops";
import type { ProgressLayout } from "./CustomizeProgressCard";

type State = "fresh" | "partway" | "done";
type Props = { layout: ProgressLayout; state: State };

async function load() {
  const { installCatalog } = await import("../strings");
  installCatalog((await import("../generated/strings.json")).default);
  const { CustomizeProgressView } = await import("./CustomizeProgressCard");
  const { mockChecklist, mockChecklistDone } = await import("../mockChecklist");
  const checklists: Record<State, Checklist> = {
    fresh: mockChecklist(),
    partway: mockChecklist(
      new Map<string, unknown>([
        ["appearance.theme", "Nightfall"],
        ["terminal.fontSize", 14],
        ["customize.checklist.done", ["look", "sidebar"]],
      ]),
      ["github", "models"],
    ),
    done: mockChecklistDone(15),
  };
  const actions = { onOpen: () => {}, onCheck: () => {}, onDismiss: () => {} };
  return function CustomizeProgressLayouts({ layout, state }: Props) {
    return (
      <section className="settings-page" style={{ padding: 16, maxWidth: layout === "ring" ? 260 : undefined }}>
        <CustomizeProgressView checklist={checklists[state]} layout={layout} actions={actions} />
      </section>
    );
  };
}

const LAYOUTS: Record<ProgressLayout, string> = {
  card: "Shipped: Settings > General's first card, the next five steps left, Show All, a dismiss",
  newTab: "One line on the New Tab page: the count and the next step",
  ring: "A sidebar footer ring with its count and the next step",
  sheet: "A first-run sheet listing every step",
};
const STATES: Record<State, string> = {
  fresh: "a fresh install, nothing done",
  partway: "six done: a theme and font set, GitHub and a model connected, two checked off",
  done: "every step done",
};

const variants: Record<string, { note: string; props: Props }> = {};
for (const layout of Object.keys(LAYOUTS) as ProgressLayout[]) {
  for (const state of Object.keys(STATES) as State[]) {
    // Variant names are lower kebab case: `newTab` is `new-tab`.
    const name = layout.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`);
    variants[`${name}-${state}`] = { note: `${LAYOUTS[layout]}; ${STATES[state]}.`, props: { layout, state } };
  }
}

export default componentEntry<Props>({
  id: "settings.customize-progress-layouts",
  title: "Customize cmux checklist layouts",
  area: "Settings",
  height: 560,
  widths: { narrow: 420, normal: 720, wide: 980 },
  covers: [
    "pages/settings/components/CustomizeProgressCard.tsx#CustomizeProgressView",
    "pages/settings/components/CustomizeProgressCard.tsx#CardBody",
    "pages/settings/components/CustomizeProgressCard.tsx#StepRow",
  ],
  load,
  styles: () => import("../page.css"),
  variants,
});
