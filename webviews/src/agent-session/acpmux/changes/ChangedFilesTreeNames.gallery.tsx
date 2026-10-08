// l10n-allow-file: gallery fixtures, not shipped UI.
// Long names in the changes tree: clipped at the column's edge with a fade (no ellipsis, the
// extension is not kept), the counts whole, a marquee on hover and on keyboard focus. The
// experiment compares the fade's length; Reduce Motion shows the full name in the tooltip instead.
import { componentEntry } from "../../../gallery/format";
import { LONG_NAMES } from "../../../gallery/fixtures/changedFiles";
import type { TurnFile } from "../diff";
import { treeNameFade } from "./treeMotion.experiment";

type Props = { files: TurnFile[] };

/** A row by the end of its label (a flattened folder's label is "parent / child"). */
const row = (name: string) => ({ deep: `[role="treeitem"][aria-label$="${name}"]` });

export default componentEntry<Props>({
  id: "agent-pane.changes-tree-names",
  title: "Changes tree: long names",
  area: "Agent pane",
  covers: ["agent-session/acpmux/changes/ChangedFilesTree.tsx#ChangedFilesTree"],
  load: () => import("../../../gallery/fixtures/ChangedFilesTreeStage").then((module) => module.ChangedFilesTreeStage),
  pane: true,
  widths: { narrow: 200, normal: 250, wide: 320 },
  height: 360,
  experiment: {
    definition: treeNameFade,
    script: [
      {
        name: "hover a long file name",
        run: async (ctx) => {
          await ctx.hover(row("AccountRecoveryVerificationCodeInputField.test.tsx"));
        },
      },
      {
        name: "focus a long folder name",
        run: async (ctx) => {
          await ctx.focus(row("third-party-identity-provider-configuration"));
        },
      },
    ],
  },
  variants: {
    "long-names": { note: "Long file and folder names, with their counts.", props: { files: LONG_NAMES } },
    "long-names-hover": {
      note: "The pointer rests on a long file name: after 0.6 s it scrolls to its end, holds, returns.",
      props: { files: LONG_NAMES },
      play: async (ctx) => {
        await ctx.hover(row("AccountRecoveryVerificationCodeInputField.test.tsx"));
      },
    },
  },
});
