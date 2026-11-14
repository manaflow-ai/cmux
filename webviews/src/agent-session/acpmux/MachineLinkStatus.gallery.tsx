// l10n-allow-file: gallery fixtures (machine and model names), not shipped UI.
// The machine link of a chat on another machine, in the composer's quiet row (MachineLinkStatus.tsx;
// goal remote-reconnect-fast, Leo 2026-11-07: "with a connection UI that says plainly what is
// happening"). Before, the row's only change 40 s into a dropped link was the model chip's
// "Unavailable" (`before`). Three looks for a link that is not connected, each in every state:
//
//   - `dot`: the dot alone, the words in its tooltip. Nothing to read without a hover: the probe's
//     failure, a link down that the screen does not say.
//   - `words`: the dot and the state's word. Says what happens, not to which machine; a pane beside
//     another machine's chat reads the same.
//   - `named` (shipped): the dot, the machine and the state's word, the sidebar header's same word,
//     with Reconnect when it is down. The words fold out of the dot, so the model chip and the
//     ring never move; connected folds back to the dot.
//
// References: claude/live/sidebar-project-groups-status-dots (a status dot per remote group, words
// only when there is something to read) and the right sidebar's machine rows (design/machines-section.md:
// a connected machine needs no word; a spinner while connecting; the word once the link is down).
import { componentEntry } from "../../gallery/format";
import type { PeerLink } from "./peerLink";
import { MachineLinkStatus, type MachineLinkLook } from "./MachineLinkStatus";

type Props = {
  link: PeerLink | null;
  look?: MachineLinkLook;
  /// The row as it was: the model chip's "Unavailable" and no link.
  before?: boolean;
};

const MACHINE = "walk-remote";
const connected: PeerLink = { machine: MACHINE, link: "connected" };
const connecting: PeerLink = { machine: MACHINE, link: "connecting" };
const reconnecting: PeerLink = { machine: MACHINE, link: "connecting", reconnecting: true };
const offline: PeerLink = { machine: MACHINE, link: "offline" };
const longName: PeerLink = { machine: "gcp-codex-lane-12-us-central1-a", link: "offline" };

function Row({ link, look, before = false }: Props) {
  return (
    <div className="acpmux-shell" data-machine-link-fixture style={{ padding: 16 }}>
      <form className="acpmux-composer">
        <div className="acpmux-composer-bar acpmux-composer-foot" data-footer-look="plain">
          <span className="acpmux-chips">
            <span className="acpmux-access">
              <button type="button" className="acpmux-picker-button">
                Normal
              </button>
            </span>
            <span className="acpmux-model">
              <button type="button" className="acpmux-picker-button">
                {before && <span className="acpmux-model-detail">Unavailable </span>}
                <span className="acpmux-model-name">m1</span>
              </button>
            </span>
          </span>
          {!before && <MachineLinkStatus link={link} look={look} onReconnect={() => undefined} />}
        </div>
      </form>
    </div>
  );
}

const states = { connected, connecting, reconnecting, offline } as const;
const looks: MachineLinkLook[] = ["named", "words", "dot"];
const variants: Record<string, { note: string; props: Props }> = {
  before: {
    note: 'Before: 40 s into a dropped link, the only change is the model chip\'s "Unavailable", which reads as the model.',
    props: { link: null, before: true },
  },
  local: { note: "A chat on this Mac: no link, the row as before.", props: { link: null } },
};
for (const look of looks)
  for (const [state, link] of Object.entries(states))
    variants[`${look}-${state}`] = {
      note: `${look === "named" ? "Shipped" : "Alternate"} look \`${look}\`, ${state}.`,
      props: { link, look },
    };
variants["named-long-name"] = {
  note: "A long machine name cuts at its end; the state and Reconnect stay whole.",
  props: { link: longName },
};

export default componentEntry<Props>({
  id: "agent-pane.machine-link",
  title: "Composer machine link",
  area: "Agent pane",
  height: 96,
  widths: { narrow: 360, normal: 560, wide: 760 },
  anchors: [{ selector: "[data-machine-link-fixture]" }],
  covers: ["agent-session/acpmux/MachineLinkStatus.tsx#MachineLinkStatus"],
  pane: true,
  load: async () => Row,
  variants,
});
