// l10n-allow-file: gallery fixtures, not shipped UI.
// The changes view's file tree at its real column width (DiffPanel: 250 px) with 200 files, and
// its folder disclosure experiment (six arms; view Compare arms). Long names and their fade:
// ChangedFilesTreeNames.gallery.tsx.
import { componentEntry, type ArmMeasurement } from "../../../gallery/format";
import { MANY_FILES } from "../../../gallery/fixtures/changedFiles";
import type { PlayContext } from "../../../gallery/play";
import type { TurnFile } from "../diff";
import { diffTreeDisclosure } from "./treeMotion.experiment";
import measurements from "./treeMotion.measurements.json";

type Props = { files: TurnFile[] };

const folder = (name: string) => ({ deep: `[role="treeitem"][data-item-type="folder"][aria-label="${name}"]` });
const expanded = (ctx: PlayContext, name: string, open: boolean) =>
  ctx.waitFor(() => ctx.find(folder(name)).getAttribute("aria-expanded") === String(open));

export default componentEntry<Props>({
  id: "agent-pane.changes-tree",
  title: "Changes tree",
  area: "Agent pane",
  covers: ["agent-session/acpmux/changes/ChangedFilesTree.tsx#ChangedFilesTree"],
  load: () => import("../../../gallery/fixtures/ChangedFilesTreeStage").then((module) => module.ChangedFilesTreeStage),
  pane: true,
  widths: { narrow: 250, normal: 250, wide: 320 },
  height: 600,
  experiment: {
    definition: diffTreeDisclosure,
    // Folder A (components) and its nested folder B (forms) start closed.
    setup: async (ctx) => {
      await ctx.click(folder("forms"));
      await expanded(ctx, "forms", false);
      await ctx.click(folder("components"));
      await expanded(ctx, "components", false);
    },
    script: [
      {
        name: "open folder A",
        run: async (ctx) => {
          await ctx.click(folder("components"));
          await expanded(ctx, "components", true);
        },
      },
      {
        name: "open nested B",
        run: async (ctx) => {
          await ctx.click(folder("forms"));
          await expanded(ctx, "forms", true);
        },
      },
      {
        name: "close A",
        run: async (ctx) => {
          await ctx.click(folder("components"));
          await expanded(ctx, "components", false);
        },
      },
      {
        name: "reopen A with Right arrow",
        run: async (ctx) => {
          await ctx.focus(folder("components"));
          await ctx.press("ArrowRight");
          await expanded(ctx, "components", true);
        },
      },
    ],
    measurements: (measurements as Record<string, Record<string, ArmMeasurement>>)["agent-pane.changes-tree"],
  },
  variants: {
    "many-files": {
      note: "200 changed files; folder A is app/components, B is its forms folder.",
      props: { files: MANY_FILES },
    },
  },
});
