// l10n-allow-file: gallery fixtures (sample prompts, replies and machine names), not shipped UI.
// A chat on another machine (huge-blue) while that machine is offline or paused (peerCopy.ts).
// Before this change, the pane had nothing of it to draw and said it was unreachable; now it draws
// the Mac's own copy of the chat at once, under a line that says the copy may be out of date.
import { agentPaneEntry } from "../../gallery/format";
import { assistant, chat, noChat, session, SESSION_ID, user } from "../../gallery/fixtures/acpmux";
import { GALLERY_NOW } from "../../gallery/clock";

const PEER = "huge-blue";
const peerSession = session({
  sessionId: SESSION_ID,
  title: "Retry the flaky upload test",
  host: PEER,
});
const rows = [
  user("The upload test fails about one run in ten. Find out why and fix it.", 48),
  assistant(
    "The test races the progress callback: it asserts on the final byte count before the last chunk's callback runs. I made the assertion wait for the upload's completion event and ran it 200 times with no failure.",
    46,
  ),
  user("Good. Open a PR with that.", 40),
  assistant("Opened the PR with the fix and a note on the race in its description.", 39),
];

export default agentPaneEntry({
  id: "agent-pane.peer-copy",
  title: "Peer chat while its machine is offline",
  area: "Agent pane",
  height: 520,
  covers: ["agent-session/acpmux/PeerCopyBanner.tsx#PeerCopyBanner"],
  variants: {
    before: {
      note: "Before: a peer chat whose machine is offline has nothing to draw (the chat is unreachable).",
      snapshot: noChat([peerSession], {
        unavailable: { reason: "offline", machine: PEER, lastSeen: GALLERY_NOW - 39 * 60_000 },
      }),
    },
    after: {
      note: "After: the Mac's copy draws at once, marked as possibly out of date until the machine is back.",
      snapshot: chat(rows, {
        title: "Retry the flaky upload test",
        sessions: [peerSession],
        peerCopy: { peer: PEER, capturedAt: GALLERY_NOW - 39 * 60_000, offline: true },
      }),
    },
    "after-no-time": {
      note: "A copy that names no time.",
      snapshot: chat(rows, { title: "Retry the flaky upload test", peerCopy: { peer: PEER, offline: true } }),
    },
  },
});
