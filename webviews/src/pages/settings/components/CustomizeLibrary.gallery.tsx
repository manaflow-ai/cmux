// l10n-allow-file: gallery fixtures (sample library entries and a refusal), not shipped UI.
// The Customization Library's layouts, side by side for the pick (rulebook: more than two versions),
// each in every state: a few entries, empty, fifty, a conflict, and a refused toggle.
// References (cmux-design-references): codex/web/skills-library (installed capabilities as rows
// with a switch each), claude/live/settings-session-workflows (titles and muted explanations on one text column, switches on one
// trailing edge), codex/web/themes-side-by-side (looks shown as their colors).
// Shipped: `layers`. The library is a stack, and order is what decides a conflict, so the list must
// read top to bottom as the stack does: one Settings row per entry (design/settings.md "Columns":
// one text column, one control edge), its swatches as the mark, its switch on the row's edge, Move
// Up / Down / Remove on hover like Settings > Menus, and the losing entry says in words which one
// wins. `cards` shows the colors best but a grid reads in two directions, so "higher wins" has no
// one direction, and fifty tiles push the rest of Personalization far down. `table` fits fifty in
// the least height but truncates the conflict sentence to one per row and hides what asked for it
// in a tooltip.
import { componentEntry } from "../../../gallery/format";
import type { LibraryListing } from "../ops";
import type { LibraryLayout } from "./CustomizeLibraryCard";

type State = "few" | "empty" | "fifty" | "conflict" | "refused";
type Props = { layout: LibraryLayout; state: State };

const REFUSAL =
  "a preview is open: apply or discard it first (`cmux customize apply` or `discard`), then change the library";

async function load() {
  const { installCatalog } = await import("../strings");
  installCatalog((await import("../generated/strings.json")).default);
  const { CustomizeLibraryView } = await import("./CustomizeLibraryCard");
  const { mockEmptyLibrary, mockLibrary, mockLongLibrary, runLibrary } = await import("../mockLibrary");
  const listings: Record<State, LibraryListing> = {
    few: runLibrary(mockLibrary(), { verb: "off", name: "roomy" })!,
    empty: mockEmptyLibrary(),
    fifty: mockLongLibrary(50),
    conflict: mockLibrary(),
    refused: mockLibrary(),
  };
  const actions = { onToggle: () => {}, onMove: () => {}, onRemove: () => {} };
  return function CustomizeLibraryLayouts({ layout, state }: Props) {
    return (
      <section className="settings-page" style={{ padding: 16 }}>
        <CustomizeLibraryView
          listing={listings[state]}
          layout={layout}
          refusal={state === "refused" ? REFUSAL : null}
          actions={actions}
          onConfirmRemove={() => {}}
          onCancelRemove={() => {}}
        />
      </section>
    );
  };
}

const LAYOUTS: Record<LibraryLayout, string> = {
  layers: "Shipped: the stack as Settings rows, top first; switch on the row's edge, order on hover",
  cards: "A grid of swatch tiles",
  table: "One dense line per entry, its number first",
};
const STATES: Record<State, string> = {
  few: "a few entries, one off, no conflict",
  empty: "nothing applied yet",
  fifty: "fifty entries",
  conflict: "night and roomy are on and both set the sidebar width: roomy says night wins",
  refused: "a toggle refused while a preview is open: the CLI's words under the list",
};

const variants: Record<string, { note: string; props: Props }> = {};
for (const layout of Object.keys(LAYOUTS) as LibraryLayout[]) {
  for (const state of Object.keys(STATES) as State[]) {
    variants[`${layout}-${state}`] = { note: `${LAYOUTS[layout]}; ${STATES[state]}.`, props: { layout, state } };
  }
}

export default componentEntry<Props>({
  id: "settings.customize-library-layouts",
  title: "Customization Library layouts",
  area: "Settings",
  height: 520,
  widths: { narrow: 420, normal: 720, wide: 980 },
  covers: [
    "pages/settings/components/CustomizeLibraryCard.tsx#CustomizeLibraryView",
    "pages/settings/components/CustomizeLibraryCard.tsx#LibraryList",
    "pages/settings/components/CustomizeLibraryCard.tsx#LibraryEntryRow",
  ],
  load,
  styles: () => import("../page.css"),
  variants,
});
