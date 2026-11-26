// l10n-allow-file: gallery fixtures (host texts), not shipped UI.
// Updates > App Update: Go Back to Previous Build, three looks for the pick (rulebook: more than two).
// Leo (2026-11-21): "...and/or the user should be able to easily access it too". Shipped: `row`. It
// is a Settings row like the card's status row above it: the kept build's number, day and commit in
// the help line, one quiet button on the trailing edge, and a refusal in the row's error line with
// the button off. `line` is the quietest (a sentence and an inline link) and the easiest to miss on
// the bad day the person needs it; `panel` boxes the build, a card inside the card.
import { componentEntry } from "../../../gallery/format";
import type { PreviousBuild } from "../ops";
import type { PreviousBuildLook } from "./PreviousBuildRow";

type Props = { look: PreviousBuildLook; previous: PreviousBuild };

const kept: PreviousBuild = {
  build: "3913596493801",
  version: "1.0.0-nightly.3913596493801",
  date: "2026-11-20",
  commit: "d7ce54c2",
  commit_url: "https://github.com/manaflow-ai/cmux/commit/d7ce54c2272",
  title: "Go Back to Previous Build",
  action: "Go Back",
  detail: "Restarts once into 1.0.0-nightly.3913596493801, kept on this Mac. Settings and sessions stay.",
  build_label: "Build 3913596493801",
  refusal: null,
};
const refused: PreviousBuild = {
  ...kept,
  refusal:
    "1.0.0-nightly.3913596493801 cannot read this Mac's sessions store (it is newer). Your data stays safe here.",
};

async function load() {
  const { PreviousBuildRow } = await import("./PreviousBuildRow");
  return function PreviousBuildLooks({ look, previous }: Props) {
    return (
      <section className="settings-page" style={{ padding: 16 }}>
        <section className="group" data-card="app-update" data-phase="idle">
          <h3 className="group-title">App Update</h3>
          <div className="rows">
            <div className="row" data-action-row="">
              <div className="row-main">
                <div className="row-label">
                  <div className="row-title">You have 1.0.0-nightly.3913596493802.</div>
                </div>
                <div className="row-control action-row-control">
                  <button type="button" className="button">
                    Check Now
                  </button>
                </div>
              </div>
            </div>
            <PreviousBuildRow previous={previous} look={look} onGoBack={async () => null} />
          </div>
        </section>
      </section>
    );
  };
}

export default componentEntry<Props>({
  id: "settings.previous-build",
  title: "Updates: Go Back to Previous Build",
  area: "Settings",
  height: 260,
  widths: { narrow: 420, normal: 720 },
  covers: ["pages/settings/components/PreviousBuildRow.tsx#PreviousBuildRow"],
  load,
  styles: () => import("../page.css"),
  variants: {
    row: {
      note: "Shipped: a Settings row; the build in the help line, Go Back on the trailing edge.",
      props: { look: "row", previous: kept },
    },
    line: {
      note: "A sentence under the status with an inline link: quietest, easy to miss.",
      props: { look: "line", previous: kept },
    },
    panel: {
      note: "The build in a box of its own with its version: loudest, a card in a card.",
      props: { look: "panel", previous: kept },
    },
    "row-refused": {
      note: "Shipped look, the rollback refuses: the button is off and the host's reason shows.",
      props: { look: "row", previous: refused },
    },
    "line-refused": { note: "`line` refusing.", props: { look: "line", previous: refused } },
    "panel-refused": { note: "`panel` refusing.", props: { look: "panel", previous: refused } },
  },
});
