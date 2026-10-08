// l10n-allow-file: gallery labels are the real Changes menu strings.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { OptionsMenu, type OptionsRow } from "./OptionsMenu";

type Props = { rows: OptionsRow[] };

const rows: OptionsRow[] = [
  { label: "Refresh changes", run: () => {} },
  { label: "Word wrap", run: () => {} },
  null,
  { label: "Copy git apply command", run: () => {} },
];

const open: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Changes options" });
  await ctx.waitFor(() => ctx.find({ role: "menu" }));
};

const keyboard: Play = async (ctx) => {
  await ctx.focus({ role: "button", name: "Changes options" });
  await ctx.press("ArrowDown");
  await ctx.waitFor(() => ctx.find({ role: "menuitem", name: "Refresh changes" }));
  await ctx.press("ArrowDown");
  await ctx.press("r");
  await ctx.waitFor(() => {
    const item = ctx.find({ role: "menuitem", name: "Refresh changes" });
    return item.getAttribute("data-highlighted") !== null;
  });
};

export default componentEntry<Props>({
  id: "agent-pane.changes-options-menu",
  title: "Changes options menu",
  area: "Agent pane",
  covers: ["agent-session/acpmux/changes/OptionsMenu.tsx#OptionsMenu"],
  load: async () => {
    return function GalleryOptionsMenu({ rows: entries }: Props) {
      return <OptionsMenu rows={entries} />;
    };
  },
  styles: () => Promise.all([import("../styles.css"), import("./changes.css")]),
  widths: { narrow: 320, normal: 480, wide: 640 },
  variants: {
    closed: { props: { rows } },
    open: { props: { rows }, play: open },
    keyboard: { props: { rows }, play: keyboard },
  },
});
