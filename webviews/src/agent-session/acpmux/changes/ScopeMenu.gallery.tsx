// l10n-allow-file: gallery labels are the real Changes menu strings.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { useState } from "react";
import type { ChangeScope } from "./model";
import { ScopeMenu } from "./ScopeMenu";

type Props = { scope: "staged" };
const props: Props = { scope: "staged" };
const open: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Changes: Staged" });
  await ctx.waitFor(() => ctx.find({ role: "menuitemradio", name: "Staged" }));
};
const keyboard: Play = async (ctx) => {
  await ctx.focus({ role: "button", name: "Changes: Staged" });
  await ctx.press("ArrowDown");
  await ctx.waitFor(() => {
    const selected = ctx.find({ role: "menuitemradio", name: "Staged" });
    return selected.getAttribute("aria-checked") === "true";
  });
  await ctx.press("b");
  await ctx.waitFor(() => {
    const branch = ctx.find({ role: "menuitemradio", name: "Branch" });
    return branch.getAttribute("data-highlighted") !== null;
  });
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.find({ role: "button", name: "Changes: Branch" }));
};

export default componentEntry<Props>({
  id: "agent-pane.changes-scope-menu",
  title: "Changes scope menu",
  area: "Agent pane",
  covers: ["agent-session/acpmux/changes/ScopeMenu.tsx#ScopeMenu"],
  load: async () =>
    function GalleryScopeMenu({ scope }: Props) {
      const [selected, setSelected] = useState<ChangeScope>(scope);
      return <ScopeMenu scope={selected} onScope={setSelected} />;
    },
  styles: () => Promise.all([import("../styles.css"), import("./changes.css")]),
  widths: { narrow: 320, normal: 480, wide: 640 },
  variants: {
    closed: { props },
    open: { props, play: open },
    keyboard: { props, play: keyboard },
  },
});
