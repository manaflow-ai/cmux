// l10n-allow-file: gallery labels and actions are fixture content, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { Listbox } from "./Listbox";

const DEFAULT_ITEMS = ["Build", "Review", "Run", "Deploy"];
const REPEATING_ITEMS = ["Alpha", "Archive", "Build"];

type Props = {
  items?: readonly string[];
  autoFocus?: boolean;
  rowClassName?: string;
};

function ListboxGallery({ items = DEFAULT_ITEMS, autoFocus = true, rowClassName }: Props) {
  const [opened, setOpened] = useState("Ready");
  return (
    <div className="listbox-gallery-stage">
      <div className="listbox-gallery-copy">
        <strong>Actions</strong>
        <span>Use the arrow keys, Home/End, typeahead, or click a row.</span>
      </div>
      <Listbox
        items={items}
        getKey={(item) => item}
        textValue={(item) => item}
        renderItem={(item) => <span>{item}</span>}
        label="Actions"
        className="listbox-gallery-list"
        rowClassName={rowClassName ?? "listbox-gallery-row"}
        // oxlint-disable-next-line jsx-a11y/no-autofocus -- the fixture demonstrates the listbox's documented initial-focus contract.
        autoFocus={autoFocus}
        onOpen={(item) => setOpened(`Opened ${item}`)}
      />
      <output className="listbox-gallery-receipt" data-testid="listbox-gallery-receipt" aria-live="polite">
        {opened}
      </output>
    </div>
  );
}

const selected = (ctx: Parameters<Play>[0], name: string) =>
  ctx.find({ role: "option", name }).getAttribute("aria-selected") === "true";

const arrowsHomeEnd: Play = async (ctx) => {
  await ctx.focus({ role: "listbox", name: "Actions" });
  await ctx.press("ArrowDown");
  await ctx.waitFor(() => selected(ctx, "Review"));
  await ctx.press("End");
  await ctx.waitFor(() => selected(ctx, "Deploy"));
  await ctx.press("Home");
  await ctx.waitFor(() => selected(ctx, "Build"));
};

const typeahead: Play = async (ctx) => {
  await ctx.focus({ role: "listbox", name: "Actions" });
  await ctx.press("r");
  await ctx.waitFor(() => selected(ctx, "Review"));
};

const repeatedLetterTypeahead: Play = async (ctx) => {
  await ctx.focus({ role: "listbox", name: "Actions" });
  await ctx.press("a");
  await ctx.waitFor(() => selected(ctx, "Archive"));
  await ctx.press("a");
  await ctx.waitFor(() => selected(ctx, "Alpha"));
};

const keyboardOpen: Play = async (ctx) => {
  await ctx.focus({ role: "listbox", name: "Actions" });
  await ctx.press("ArrowDown");
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.find({ testId: "listbox-gallery-receipt" }).textContent === "Opened Review");
};

const spaceOpen: Play = async (ctx) => {
  await ctx.focus({ role: "listbox", name: "Actions" });
  await ctx.press("Space");
  await ctx.waitFor(() => ctx.find({ testId: "listbox-gallery-receipt" }).textContent === "Opened Build");
};

const pointerOpen: Play = async (ctx) => {
  await ctx.click({ role: "option", name: "Run" });
  await ctx.waitFor(() => ctx.find({ testId: "listbox-gallery-receipt" }).textContent === "Opened Run");
};

export default componentEntry<Props>({
  id: "ui.listbox",
  title: "Listbox",
  area: "UI primitives",
  height: 360,
  widths: { narrow: 320, normal: 520, wide: 760 },
  anchors: [{ selector: ".listbox-gallery-receipt" }],
  checks: {
    anchorMovePx: { value: 0, reason: "Listbox navigation and activation must not move the receipt anchor." },
    layoutShiftMax: { value: 0.05, reason: "Changing the highlighted row only changes its paint state." },
    longFrameFailMs: { value: 33, reason: "Local listbox keyboard feedback should stay within two display frames." },
    settleMaxMs: { value: 250, reason: "Listbox navigation and activation are local interactions." },
  },
  covers: ["ui/Listbox.tsx#Listbox"],
  load: async () => ListboxGallery,
  styles: () => Promise.all([import("./ui.css"), import("./Listbox.gallery.css")]),
  variants: {
    initial: { props: {} },
    "arrows-home-end": { props: {}, play: arrowsHomeEnd },
    typeahead: { props: {}, play: typeahead },
    "repeated-letter": { props: { items: REPEATING_ITEMS }, play: repeatedLetterTypeahead },
    "enter-opens": { props: {}, play: keyboardOpen },
    "space-opens": { props: {}, play: spaceOpen },
    "pointer-opens": { props: {}, play: pointerOpen },
    empty: { props: { items: [] } },
  },
});
