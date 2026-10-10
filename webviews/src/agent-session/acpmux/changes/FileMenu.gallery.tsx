// l10n-allow-file: gallery labels are the real Changes menu strings.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { FileMenu } from "./FileMenu";

type Props = { path: string; name: string; collapsed: boolean };

const props: Props = { path: "src/components/Composer.tsx", name: "Composer.tsx", collapsed: false };
const open: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "More actions for Composer.tsx" });
  await ctx.waitFor(() => ctx.find({ role: "menuitem", name: "Open file in a tab" }));
};
const keyboard: Play = async (ctx) => {
  await ctx.focus({ role: "button", name: "More actions for Composer.tsx" });
  await ctx.press("ArrowDown");
  await ctx.press("o");
  await ctx.waitFor(() => {
    const item = ctx.find({ role: "menuitem", name: "Open file in a tab" });
    return item.getAttribute("data-highlighted") !== null;
  });
};

export default componentEntry<Props>({
  id: "agent-pane.changes-file-menu",
  title: "Changes file menu",
  area: "Agent pane",
  covers: ["agent-session/acpmux/changes/FileMenu.tsx#FileMenu"],
  load: async () =>
    function GalleryFileMenu(input: Props) {
      return <FileMenu {...input} onToggleCollapsed={() => {}} onOpenInTab={() => {}} />;
    },
  styles: () => Promise.all([import("../styles.css"), import("./changes.css")]),
  widths: { narrow: 320, normal: 480, wide: 640 },
  variants: {
    closed: { props },
    open: { props, play: open },
    keyboard: { props, play: keyboard },
  },
});
