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

/// The open folder popover's side and where it is against its chip and the viewport.
const placement = (document: Document) => {
  const popup = document.querySelector(".acpmux-location-menu[data-side]");
  const chip = document.querySelector('button[aria-label="Folder"]');
  const box = popup?.getBoundingClientRect();
  const anchor = chip?.getBoundingClientRect();
  return {
    side: popup?.getAttribute("data-side") ?? undefined,
    below: !!box && !!anchor && box.top >= anchor.bottom,
    inView: !!box && box.top >= 0 && box.bottom <= innerHeight,
    text: `side ${popup?.getAttribute("data-side")}, popup ${Math.round(box?.top ?? NaN)}-${Math.round(box?.bottom ?? NaN)}, chip ${Math.round(anchor?.top ?? NaN)}-${Math.round(anchor?.bottom ?? NaN)}, viewport ${innerHeight}, scroll ${Math.round(scrollY)}`,
  };
};

const nextFrames = () => new Promise<void>((done) => requestAnimationFrame(() => requestAnimationFrame(() => done())));

const filterKeepsSide: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "Folder" });
  await ctx.waitFor(() => ctx.document.querySelectorAll('.acpmux-location-menu [role="option"]').length >= 6);
  await nextFrames();
  const opened = placement(ctx.document);
  if (opened.side !== "bottom" || !opened.below || !opened.inView)
    throw new Error(`the full folder list should open below its chip, in view: ${opened.text}`);
  await ctx.type("relay");
  await ctx.waitFor(() => ctx.document.querySelectorAll('.acpmux-location-menu [role="option"]').length === 1);
  await nextFrames();
  const filtered = placement(ctx.document);
  if (filtered.side !== opened.side || !filtered.below)
    throw new Error(`the folder popover moved while filtering: opened ${opened.text}; filtered ${filtered.text}`);
};

export default componentEntry<Props>({
  id: "agent-pane.composer-context-side",
  title: "Composer location menu keeps its side",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/ComposerContext.tsx#ComposerContext"],
  // The location menu's own rules load first, so they must win over styles.css's .acpmux-menu
  // placement by specificity, not by load order (the pane's bundle and a cold dev page differ).
  styles: async () => {
    await import("./composerLocation.css");
    await import("./styles.css");
  },
  load: async () => Placed,
  widths: { narrow: 400, normal: 620, wide: 760 },
  height: 900,
  checks: {
    // The filter moves the rows it keeps up into the places of the rows it drops ("relay" rises two
    // rows): that is the filter's result, not the popover moving. The open's scale animation hid
    // that row move from the layout-shift check until popups opened in one frame (#24980).
    layoutShiftMax: {
      value: 0.01,
      reason:
        "Filtering moves the kept folder rows up inside the open list (0.0035 seen); the play itself checks that the popover keeps its side and place.",
    },
    longFrameFailMs: {
      value: 200,
      reason:
        "This entry tests the popover's side, not its timing; its first open on a cold CI page loads the menu's code (122 ms seen). agent-pane.composer-context keeps the 33 ms bar.",
    },
  },
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
        onNewChat: () => undefined,
      },
      play: filterKeepsSide,
    },
    "below-when-room": {
      note: "Both sides have room for the full folder list; the shared placement rule prefers below.",
      props: {
        top: 350,
        started: true,
        projectChoices: projects,
        summary: {
          sessionId: "gallery-side-below",
          harness: "claude",
          cwd: projects[1]!.cwd,
          host: "This Mac",
          hostKind: "local",
        },
        onNewChat: () => undefined,
      },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Folder" });
        await ctx.waitFor(() => ctx.document.querySelectorAll('.acpmux-location-menu [role="option"]').length >= 6);
        await nextFrames();
        const opened = placement(ctx.document);
        if (opened.side !== "bottom" || !opened.below || !opened.inView)
          throw new Error(`the folder list should prefer below when both sides fit: ${opened.text}`);
      },
    },
  },
});
