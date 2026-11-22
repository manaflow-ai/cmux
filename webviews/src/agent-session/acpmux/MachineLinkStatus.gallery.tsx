// l10n-allow-file: gallery fixtures (machine and model names), not shipped UI.
// The machine link of a chat on another machine, in the composer's quiet row (MachineLinkStatus.tsx;
// goal remote-reconnect-fast, Leo 2026-11-07: "with a connection UI that says plainly what is
// happening"; Leo 2026-11-22: "i dont wanna see connecting to <machine>... with the spinner, i
// want it to just work"). Every state acpmux brings back by itself is the dot alone, at any duration:
// no spinner, no words, no Reconnect. Only a step a person must take (a refused sign-in, an update
// the machine needs) is said, in one of three looks:
//
//   - `dot`: the dot alone, the words in its tooltip. Nothing to read without a hover.
//   - `words`: the dot and the step's words. Says what to do, not on which machine.
//   - `named` (shipped): the dot, the machine and the step, the sidebar header's same words. The words
//     fold out of the dot, so the model chip and the ring never move.
//
// References: claude/live/sidebar-project-groups-status-dots (a status dot per remote group, words
// only when there is something to read) and the right sidebar's machine rows (design/machines-section.md).
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
const signIn: PeerLink = { machine: MACHINE, link: "offline", why: "authFailed", stuck: true };
const update: PeerLink = { machine: MACHINE, link: "offline", why: "updateRequired", stuck: true };
const longName: PeerLink = { ...signIn, machine: "gcp-codex-lane-12-us-central1-a" };

function Row({ link, look, before = false }: Props) {
  return (
    <div className="acpmux-shell" data-machine-link-fixture style={{ padding: 16 }}>
      <form className="acpmux-composer" data-foot="">
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
          {!before && <MachineLinkStatus link={link} look={look} />}
        </div>
      </form>
    </div>
  );
}

const stuck = { "sign-in": signIn, update } as const;
const looks: MachineLinkLook[] = ["named", "words", "dot"];
const variants: Record<string, { note: string; props: Props }> = {
  before: {
    note: 'Before: 40 s into a dropped link, the only change is the model chip\'s "Unavailable", which reads as the model.',
    props: { link: null, before: true },
  },
  local: { note: "A chat on this Mac: no link, the row as before.", props: { link: null } },
  connected: { note: "A chat on another machine, connected: the dot alone.", props: { link: connected } },
};
for (const look of looks)
  for (const [state, link] of Object.entries(stuck))
    variants[`${look}-${state}`] = {
      note: `${look === "named" ? "Shipped" : "Alternate"} look \`${look}\`, ${state === "sign-in" ? "a refused sign-in" : "an update the machine needs"}: said at once.`,
      props: { link, look },
    };
variants["named-long-name"] = {
  note: "A long machine name cuts at its end; the step stays whole.",
  props: { link: longName },
};

// A link acpmux brings back on its own is never said here, however long it is down: the plain dot in
// its connected look, no spinner, no words, no Reconnect, in every state that heals by itself.
for (const [state, link] of Object.entries({ connecting, reconnecting, offline }))
  variants[`quiet-${state}`] = {
    note: `${state}, at any duration: the plain dot; nothing is said.`,
    props: { link },
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
