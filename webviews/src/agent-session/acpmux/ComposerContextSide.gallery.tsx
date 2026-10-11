// l10n-allow-file: gallery fixtures (sample folders), not shipped UI.
//
// A location menu keeps the side it chose when it opened (cx-ncc.53). The scope row sits low enough
// in the stage that the folder popover's full list does not fit above its chip, so it opens below;
// typing a filter shrinks the list until it would fit above, and the popover must not jump there.
// The play fails when the popup's side changes while typing (composer-location-side.test.ts).
import type { ComponentProps } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { ComposerContext } from "./ComposerContext";
import type { Project } from "./ProjectChooser";

const projects: Project[] = ["atlas-web", "cmux", "relay", "billing", "docs", "infra", "mobile", "design-system"].map(
  (name) => ({ cwd: `/Users/you/src/${name}`, label: name }),
);

type Props = ComponentProps<typeof ComposerContext> & { top: number };

/// The scope row `top` px down the stage.
function Placed({ top, ...props }: Props) {
  return (
    <div style={{ paddingTop: top }}>
      <ComposerContext {...props} />
    </div>
  );
}

const popupSide = (document: Document) =>
  document.querySelector(".acpmux-location-menu[data-side]")?.getAttribute("data-side") ?? undefined;

const nextFrames = () => new Promise<void>((done) => requestAnimationFrame(() => requestAnimationFrame(() => done())));

const filterKeepsSide: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Folder" });
  await ctx.waitFor(() => ctx.document.querySelectorAll('.acpmux-location-menu [role="option"]').length >= 6);
  await nextFrames();
  const opened = popupSide(ctx.document);
  if (opened !== "bottom") throw new Error(`the full folder list should open below its chip, opened ${opened}`);
  await ctx.type("relay");
  await ctx.waitFor(() => ctx.document.querySelectorAll('.acpmux-location-menu [role="option"]').length === 1);
  await nextFrames();
  const filtered = popupSide(ctx.document);
  if (filtered !== opened) throw new Error(`the folder popover moved from ${opened} to ${filtered} while filtering`);
};

export default componentEntry<Props>({
  id: "agent-pane.composer-context-side",
  title: "Composer location menu keeps its side",
  area: "Agent pane",
  covers: ["agent-session/acpmux/ComposerContext.tsx#ComposerContext"],
  styles: () => Promise.all([import("./styles.css"), import("./composerLocation.css")]),
  load: async () => Placed,
  widths: { narrow: 400, normal: 620, wide: 760 },
  height: 560,
  variants: {
    "filter-keeps-side": {
      note: "Too little room above for the full folder list: the popover opens below its chip and stays there while a filter shrinks the list.",
      props: {
        top: 140,
        started: true,
        projectChoices: projects,
        summary: {
          sessionId: "gallery-side",
          harness: "claude",
          cwd: projects[1]!.cwd,
          host: "This Mac",
          hostKind: "local",
        },
        onMove: () => undefined,
      },
      play: filterKeepsSide,
    },
  },
});
