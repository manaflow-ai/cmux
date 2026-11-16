// l10n-allow-file: gallery fixtures (sample chats and steps), not shipped UI.
// Steer queue (SteerQueue.tsx, experiment `steer-queue`): every live chat ranked by which needs the
// person now. The looks: `rows` (the one the pane uses: two lines, the live step under the title),
// `compact` (one line per chat), and `split` (rows beside the focused chat's whole line and the
// person's last step into it). Light and dark come from the gallery's appearance control.
import { componentEntry } from "../../../gallery/format";
import type { SteerAct } from "./log";
import { steerQueue } from "./model";
import type { SteerActions, SteerQueueLook } from "./SteerQueue";
import type { AcpmuxSessionEntry } from "../sessionList";

const NOW = Date.now();
const ago = (minutes: number) => NOW - minutes * 60_000;
const session = (fields: Partial<AcpmuxSessionEntry> & { sessionId: string }): AcpmuxSessionEntry => ({
  harness: "claude",
  hostKind: "local",
  host: "This Mac",
  ...fields,
});

const sessions: AcpmuxSessionEntry[] = [
  session({
    sessionId: "s-tabs",
    title: "Review the terminal tab strip",
    pendingPermissions: 1,
    indicator: "input",
    doing: "Run bun run lint:ci",
    updatedAt: ago(9),
  }),
  session({
    sessionId: "s-notes",
    title: "Release notes on build box",
    hostKind: "cloud",
    host: "build-box",
    indicator: "input",
    waitingOn: { on: "question", prompt: "Which tag should the notes start from?" },
    updatedAt: ago(3),
  }),
  session({
    sessionId: "s-ios",
    title: "Port the pairing sheet to React",
    harness: "codex",
    indicator: "failed",
    laneError: "The agent exited: out of context",
    updatedAt: ago(6),
  }),
  session({
    sessionId: "s-flicker",
    title: "Fix sidebar flicker on theme change",
    hostKind: "cloud",
    host: "hearty-beige-elk",
    indicator: "working",
    doing: "Waiting for CI on #18231",
    updatedAt: ago(11),
  }),
  session({
    sessionId: "s-l10n",
    title: "Localize the changes view",
    harness: "codex",
    indicator: "done",
    unread: true,
    preview: "Added the 14 new strings in all app locales; the Arabic toolbar mirrors.",
    updatedAt: ago(4),
  }),
  session({
    sessionId: "s-retry",
    title: "Add retry backoff to the fleet uploader",
    indicator: "working",
    doing: "Editing src/upload/retry.ts",
    updatedAt: ago(0.5),
  }),
  session({
    sessionId: "s-bench",
    title: "Bench the transcript at 10k rows",
    indicator: "working",
    doing: "Running bun run bench:transcript",
    updatedAt: ago(1),
  }),
];

const log: SteerAct[] = [
  { sessionId: "s-flicker", act: "steer", text: "Check every theme in dark mode before the PR", at: ago(7) },
  { sessionId: "s-retry", act: "redirect", text: "Use the shared backoff helper instead", at: ago(2) },
];

const items = steerQueue({ sessions, now: NOW, log });
const actions: SteerActions = {
  steer: async () => undefined,
  redirect: async () => undefined,
  stop: async () => undefined,
  fork: async () => undefined,
  open: async () => undefined,
};

type Props = { look: SteerQueueLook; empty?: boolean; focus?: string };

export default componentEntry<Props>({
  id: "agent-pane.steer-queue",
  title: "Steer queue",
  area: "Agent pane",
  height: 560,
  keywords: ["steer", "queue", "interrupt", "redirect", "fork", "triage", "needs you"],
  covers: ["agent-session/acpmux/steerQueue/SteerQueue.tsx"],
  load: () =>
    import("./SteerQueue").then(
      ({ SteerQueue }) =>
        function Stage({ look, empty, focus }: Props) {
          return (
            <div className="acpmux-shell" style={{ height: "100%" }}>
              <SteerQueue
                items={empty ? [] : items}
                now={NOW}
                actions={actions}
                onClose={() => undefined}
                look={look}
                initialFocus={focus}
              />
            </div>
          );
        },
    ),
  styles: async () => {
    await import("../../../ui/ui.css");
    await import("../styles.css");
  },
  variants: {
    rows: {
      note: "The pane's look: asks first (longest wait first), then the failed turn, the quiet one, the unread finish and the running turns; each row's live step under its title, and where the person last stepped in.",
      props: { look: "rows" },
    },
    "rows-running": {
      note: "Focus on a running turn: Return steers it, ⌘Return redirects, ⌘. stops, ⌘⇧Return forks.",
      props: { look: "rows", focus: "s-flicker" },
    },
    compact: {
      note: "One line per chat: the most chats at once, no live step.",
      props: { look: "compact", focus: "s-flicker" },
    },
    split: {
      note: "Rows beside the focused chat's whole line and the person's last step into it, quoted.",
      props: { look: "split", focus: "s-flicker" },
    },
    empty: { note: "Nothing needs the person: every chat is idle and read.", props: { look: "rows", empty: true } },
  },
});
