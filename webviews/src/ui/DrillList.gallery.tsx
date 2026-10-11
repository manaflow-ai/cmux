// l10n-allow-file: gallery labels and actions are fixture content, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../gallery/format";
import type { Play } from "../gallery/play";
import { DrillList, type DrillSection } from "./DrillList";
import { UiProvider } from "./UiProvider";

type Item = { id: string; label: string; detail: string };

const RECENT: Item[] = [
  { id: "build", label: "Build project", detail: "⌘B" },
  { id: "review", label: "Review changes", detail: "⌘R" },
];
const ACTIONS: Item[] = [
  { id: "run", label: "Run checks", detail: "⌘↵" },
  { id: "deploy", label: "Deploy preview", detail: "⌘D" },
  { id: "archive", label: "Archive branch", detail: "" },
];
const VIRTUAL_ITEMS: Item[] = Array.from({ length: 140 }, (_, index) => ({
  id: `item-${index}`,
  label: `Generated action ${String(index + 1).padStart(3, "0")}`,
  detail: index % 2 ? "" : "⌘↵",
}));

type Props = {
  direction?: "ltr" | "rtl";
  virtual?: boolean;
  empty?: boolean;
  initialQuery?: string;
};

function DrillListGallery({ direction = "ltr", virtual = false, empty = false, initialQuery = "" }: Props) {
  const source = virtual ? VIRTUAL_ITEMS : [...RECENT, ...ACTIONS];
  const [query, setQuery] = useState(initialQuery);
  const [highlight, setHighlight] = useState(0);
  const [event, setEvent] = useState("Ready");
  const visible = source.filter((item) => item.label.toLocaleLowerCase().includes(query.toLocaleLowerCase()));
  const sections: DrillSection<Item>[] = empty
    ? [{ id: "actions", items: [] }]
    : virtual
      ? [{ id: "generated", label: "All actions", items: visible }]
      : [
          { id: "recent", label: "Recent", items: visible.filter((item) => RECENT.includes(item)) },
          { id: "actions", label: "Actions", items: visible.filter((item) => ACTIONS.includes(item)) },
        ];
  const describe = (item: Item | undefined) => item?.label ?? "nothing";
  return (
    <UiProvider container={null} dir={direction}>
      <div className="drill-list-gallery-stage" dir={direction}>
        <div className="drill-list-gallery-copy">
          <strong>Command browser</strong>
          <span>Filter actions, then use the list keys to enter or choose one.</span>
        </div>
        <DrillList
          sections={sections}
          getKey={(item) => item.id}
          renderItem={(item) => (
            <>
              <span>{item.label}</span>
              {item.detail ? <kbd>{item.detail}</kbd> : null}
            </>
          )}
          itemAttributes={(item) => ({ title: item.label })}
          highlight={highlight}
          onHighlight={setHighlight}
          query={query}
          onQueryChange={(next) => {
            setQuery(next);
            setHighlight(0);
          }}
          onEnter={(item) => setEvent(`Entered ${describe(item)}`)}
          onUp={() => setEvent("Moved up")}
          onChoose={(item) => setEvent(`Chosen ${describe(item)}`)}
          onCancel={() => setEvent("Cancelled")}
          onActivate={(item) => setEvent(`Activated ${item.label}`)}
          label="Command browser"
          placeholder="Filter commands"
          listLabel="Command results"
          empty="No matching commands"
          hint="Return chooses · Tab enters · Escape clears"
          status={`${visible.length} command${visible.length === 1 ? "" : "s"}`}
          fieldClassName="drill-list-gallery-field"
          listClassName="drill-list-gallery-list"
          rowClassName="drill-list-gallery-row"
          emptyClassName="drill-list-gallery-empty"
          sectionClassName="drill-list-gallery-section"
          hintClassName="drill-list-gallery-hint"
          // oxlint-disable-next-line jsx-a11y/no-autofocus -- the fixture demonstrates the picker field's initial-focus contract.
          autoFocus
        />
        <output className="drill-list-gallery-receipt" data-testid="drill-list-gallery-receipt" aria-live="polite">
          {event}
        </output>
      </div>
    </UiProvider>
  );
}

const selected = (ctx: Parameters<Play>[0], name: string) =>
  ctx.find({ role: "option", name }).getAttribute("aria-selected") === "true";
const receipt = (ctx: Parameters<Play>[0], text: string) =>
  ctx.find({ testId: "drill-list-gallery-receipt" }).textContent === text;

const arrowsHomeEnd: Play = async (ctx) => {
  await ctx.focus({ role: "combobox", name: "Command browser" });
  await ctx.press("ArrowDown");
  await ctx.waitFor(() => selected(ctx, "Review changes"));
  await ctx.press("End");
  await ctx.waitFor(() => selected(ctx, "Archive branch"));
  await ctx.press("Home");
  await ctx.waitFor(() => selected(ctx, "Build project"));
};

const filtering: Play = async (ctx) => {
  await ctx.focus({ role: "combobox", name: "Command browser" });
  await ctx.type("deploy");
  await ctx.waitFor(() => selected(ctx, "Deploy preview"));
  await ctx.waitFor(
    () => ctx.find({ role: "listbox", name: "Command results" }).querySelectorAll('[role="option"]').length === 1,
  );
};

const choose: Play = async (ctx) => {
  await ctx.focus({ role: "combobox", name: "Command browser" });
  await ctx.press("ArrowDown");
  await ctx.press("Enter");
  await ctx.waitFor(() => receipt(ctx, "Chosen Review changes"));
};

const enterAndTab: Play = async (ctx) => {
  await ctx.focus({ role: "combobox", name: "Command browser" });
  await ctx.press("Tab");
  await ctx.waitFor(() => receipt(ctx, "Entered Build project"));
};

const filterClear: Play = async (ctx) => {
  await ctx.focus({ role: "combobox", name: "Command browser" });
  await ctx.type("run");
  await ctx.waitFor(() => selected(ctx, "Run checks"));
  await ctx.press("Escape");
  await ctx.waitFor(() => (ctx.find({ role: "combobox", name: "Command browser" }) as HTMLInputElement).value === "");
};

const emptyCancel: Play = async (ctx) => {
  await ctx.focus({ role: "combobox", name: "Command browser" });
  await ctx.press("Escape");
  await ctx.waitFor(() => receipt(ctx, "Cancelled"));
};

const virtualNavigation: Play = async (ctx) => {
  await ctx.focus({ role: "combobox", name: "Command browser" });
  await ctx.press("End");
  await ctx.waitFor(() => selected(ctx, "Generated action 140"));
  await ctx.press("Home");
  await ctx.waitFor(() => selected(ctx, "Generated action 001"));
};

export default componentEntry<Props>({
  id: "ui.drill-list",
  title: "Drill-down list",
  area: "UI primitives",
  height: 460,
  widths: { narrow: 360, normal: 560, wide: 820 },
  anchors: [{ selector: ".drill-list-gallery-receipt" }],
  checks: {
    anchorMovePx: { value: 0, reason: "Filtering and list navigation must not move the receipt anchor." },
    layoutShiftMax: {
      value: 0.08,
      reason: "A highlighted row or filtered result may repaint without moving the receipt.",
    },
    longFrameFailMs: { value: 33, reason: "Picker keyboard feedback should stay within two display frames." },
    settleMaxMs: { value: 250, reason: "Filtering and picker navigation are local interactions." },
  },
  covers: ["ui/DrillList.tsx#DrillList"],
  load: async () => DrillListGallery,
  styles: () => Promise.all([import("./ui.css"), import("./DrillList.gallery.css")]),
  variants: {
    initial: { props: {} },
    "arrows-home-end": { props: {}, play: arrowsHomeEnd },
    filtering: { props: {}, play: filtering },
    choose: { props: {}, play: choose },
    "tab-enters": { props: {}, play: enterAndTab },
    "escape-clears": { props: {}, play: filterClear },
    empty: { props: { empty: true }, play: emptyCancel },
    virtualized: { props: { virtual: true }, play: virtualNavigation },
    rtl: { props: { direction: "rtl" }, play: arrowsHomeEnd },
  },
});
