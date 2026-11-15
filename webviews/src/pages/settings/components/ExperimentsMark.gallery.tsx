// l10n-allow-file: gallery fixtures (sample pull requests and the native mark's English words), not shipped UI.
// The "Experiment on · #N" mark (native SidebarExperimentsMarkView): where in the app it says that an
// unmerged pull request's pages are on (`cmux customize use pr:N`), and what it does. Leo, 2026-11-14:
// "these are opt-in settings ... it's obviously not going to show anything and not affect anything when
// there's nothing to toggle on and off ... I want it to like look good and look, you know, like it's a part
// of the app ... I want people to not accidentally soft lock themselves and like have good recovery
// options".
//
// References: design/app-health.md (a status the person can act on floats on its own chip at the sidebar's
// bottom-left, never in the footer row's flow: "the agent pane: slow indicator on the bottom left is
// uselsss and layout shifts the space"), Swift live mode's footer mark (LiveModeBadgeView: this app is
// running code that is not the shipped build), cmux-design-references `claude/live/sidebar-mobile-promo-banner`
// (one quiet line at the sidebar's bottom with one action) and `codex/web/browser-developer-mode` (an
// elevated-risk mode named in words where it is turned on).
//
// Each variant draws the sidebar's bottom twice, with nothing on and with the mark, so a move shows at a
// glance. The placements:
// - `chip`, shipped: its own chip above the footer row at the avatar's edge, stacked above app health's line
//   when that shows. It says in words that pages come from a PR and which one, its Off is the way back
//   without opening any page (a PR can break Settings itself), and the row never moves.
// - `in-row`: a badge in the footer row after the avatar, where Swift live mode's mark sits. Quiet, but
//   turning a PR on or off pushes the spaces strip and the update button along the row.
// - `avatar`: a flask on the avatar's corner, its line the tooltip. Nothing moves and it takes the least
//   room, but which PR is on, and the way back, need a hover and a click.
// - `titlebar`: a pill at the window's top row. Seen from everywhere, but the top row is the window's own
//   controls, and a lone pill there reads as a notification.
// With nothing on (`*-none`), every placement draws nothing and both copies are identical.
import { componentEntry } from "../../../gallery/format";
import type { ComponentVariant } from "../../../gallery/format";
import { PR_MERGED, PR_ON } from "../mockLibrary";
import type { LibraryCode } from "../ops";

type Placement = "chip" | "in-row" | "avatar" | "titlebar";
type Props = { placement: Placement; on: LibraryCode[]; health: boolean };

const PLACEMENTS: Record<Placement, string> = {
  chip: "Shipped: its own chip above the footer row, with Off; the row never moves.",
  "in-row": "A badge after the avatar, where Swift live mode's mark sits; the strip and update button move.",
  avatar: "A flask on the avatar's corner, its line the tooltip; nothing moves.",
  titlebar: "A pill at the window's top row, its line the tooltip.",
};

async function load() {
  const [{ Icon }, { experimentsOn }, { mockLibraryWithExperiments }] = await Promise.all([
    import("../icons"),
    import("../customizeLibrary"),
    import("../mockLibrary"),
  ]);
  // The native mark's words (CustomizeExperiments.line): one PR by number, more by count.
  const line = (on: LibraryCode[]) =>
    on.length === 0 ? null : on.length === 1 ? `Experiment on · #${on[0]!.pr}` : `Experiments on · ${on.length}`;
  function Row({ badge }: { badge: string | null }) {
    return (
      <div className="ahf-row">
        <span className="ahf-avatar">L</span>
        {badge && <span className="xm-in-row">{badge}</span>}
        <span className="ahf-strip" data-pushed={badge ? "true" : undefined}>
          <span className="ahf-space" data-active="true" />
          <span className="ahf-space" />
          <span className="ahf-plus">+</span>
        </span>
        <span className="ahf-button ahf-update" />
        <span className="ahf-button ahf-search" />
      </div>
    );
  }
  function Sidebar({ placement, on, health }: Props) {
    // The count comes from the listing the Library card reads, as the native mark's does.
    const listed = experimentsOn(mockLibraryWithExperiments(on));
    const text = line(listed.map((entry) => entry.code!));
    return (
      <div className="ahf-sidebar xm-sidebar">
        {placement === "titlebar" && (
          <div className="xm-titlebar">
            <span className="xm-lights" />
            {text && (
              /* tooltip-allow: the pill's tooltip names each PR */
              <span className="xm-pill" title={text}>
                <Icon name="flask" />
                {text}
              </span>
            )}
          </div>
        )}
        <div className="ahf-list">
          <span className="ahf-list-row">workspace-404</span>
          <span className="ahf-list-row">claude-sr2-coord</span>
          <span className="ahf-list-row">chat-export-anywhere</span>
          <span className="ahf-list-row">settings-library</span>
        </div>
        {health && (
          <span className="ahf-overlay" data-tone="danger">
            <span className="ah-dot" data-tone="danger" aria-hidden="true" />
            <span className="ahf-text">Agent chat isn't responding</span>
          </span>
        )}
        {placement === "chip" && text && (
          <span className="ahf-overlay xm-chip" data-stacked={health ? "" : undefined}>
            <Icon name="flask" />
            <span className="ahf-text">{text}</span>
            <span className="xm-turn-off">Off</span>
          </span>
        )}
        <Row badge={placement === "in-row" ? text : null} />
        {placement === "avatar" && text && (
          /* tooltip-allow: the badge has no text; the tooltip is its one line */
          <span className="ahf-badge xm-avatar" title={text}>
            <Icon name="flask" />
          </span>
        )}
      </div>
    );
  }
  return function ExperimentsMarkPlacements(props: Props) {
    return (
      <div className="ahf-gallery" data-placement={props.placement}>
        <span className="ahf-caption">Nothing on</span>
        <Sidebar {...props} on={[]} />
        <span className="ahf-caption">{props.on.length === 0 ? "Still nothing on: identical" : "With the mark"}</span>
        <Sidebar {...props} />
      </div>
    );
  };
}

const STATES: Record<string, { note: string; on: LibraryCode[]; health?: boolean }> = {
  "0-none": { note: "No PR's pages are on: nothing renders, the sidebar is as it is today.", on: [] },
  "1-one": { note: "One PR on: its number in words.", on: [PR_ON] },
  "2-two": { note: "Two PRs on: the count (the higher one's pages show).", on: [PR_ON, PR_MERGED] },
  "3-with-health": {
    note: "One PR on while app health has a line: the mark stacks above it, neither moves the row.",
    on: [PR_ON],
    health: true,
  },
};

const variants: Record<string, ComponentVariant<Props>> = {};
for (const [placement, lead] of Object.entries(PLACEMENTS) as [Placement, string][])
  for (const [state, { note, on, health }] of Object.entries(STATES))
    variants[`${placement}-${state}`] = {
      props: { placement, on, health: health ?? false },
      note: `${lead} ${note}`,
    };

export default componentEntry<Props>({
  id: "ui.customize-experiments.mark",
  title: "Experiments mark at the sidebar's bottom-left",
  area: "Settings",
  height: 260,
  widths: { narrow: 240, normal: 260, wide: 320 },
  covers: ["pages/settings/customizeLibrary.ts#experimentsOn"],
  keywords: ["experiment", "pull request", "pr", "customize", "library", "sidebar", "footer", "recovery"],
  load,
  styles: async () => {
    await import("../../shared/pageBase.css");
    await import("../../../ui/ui.css");
    await import("../../../app-health/appHealth.css");
    await import("../../../app-health/AppHealthFooterRow.gallery.css");
    await import("./ExperimentsMark.gallery.css");
  },
  variants,
});
