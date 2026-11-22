// l10n-allow-file: gallery fixtures (sample agent names and messages), not shipped UI.
// The chat's held message surge as one row of the bottom stack (SurgeHoldRow.tsx; Leo, 2026-11-20:
// "when it gets to states like this all of you need to be able to temporarily let the messages go to
// some inbox that you later categorize/read"). Shut, the counts; open, a search field and the held
// threads in the transcript's received-messages look. Each stage stands the row on a stand-in composer
// card, so its surface (stack, card, line) shows against the part it sits on. Names and messages are
// made up.
import type { CSSProperties } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { SurgeHoldRow, type SurgeRowLook, type SurgeSurface } from "./SurgeHoldRow";
import type { InboxMessage } from "./conversation/inboxNotice";

type Failing = "host" | "offline" | "daemon";
type Props = {
  look?: SurgeRowLook;
  surface?: SurgeSurface;
  held: number;
  needYou: number;
  open?: boolean;
  failing?: Failing;
  unmarked?: boolean;
};

const MINUTE = 60_000;
const NOW = Date.now();
const LABELS = ["ubuntu-2404", "macos-15", "fleet-linux", "gpu-a100"];

const THREADS = [
  {
    threadId: "pr:48120",
    label: "#48120",
    from: ["lane-7"],
    count: 2,
    newestAt: NOW - 2 * MINUTE,
    newestPreview: "Review is SHIP at 3b01de6; the land is refused on a merge freeze. Can you lift it?",
    class: "blocker",
    surgeHeld: true,
    sender: { session: "lane-7-session", label: "lane-7" },
  },
  ...LABELS.map((label, i) => ({
    threadId: `topic:runner-capacity/${label}`,
    label: `runner-capacity/${label}`,
    from: ["runner-watch"],
    count: 6 + i,
    newestAt: NOW - (5 + i) * MINUTE,
    newestPreview: `Queued jobs on ${label}: ${3 + i} waiting, oldest ${8 + i} min`,
    class: "fyi",
    surgeHeld: true,
  })),
  {
    threadId: "from:disk-hygiene",
    label: "",
    from: ["disk-hygiene"],
    count: 4,
    newestAt: NOW - 14 * MINUTE,
    newestPreview: "disk-hygiene on swarm-06: healthy again (unowned-fetch cleared)",
    class: "fyi",
    surgeHeld: true,
  },
];

const listThreads = async () => ({ surge: undefined, threads: THREADS });
// A listing that names no thread held (the daemon counts a surge but marks none yet).
const unmarkedList = async () => ({ surge: undefined, threads: THREADS.map(({ surgeHeld: _, ...t }) => t) });
// The three ways a listing fails, as the pane's relay and acpmux answer.
const FAILURES: Record<Failing, unknown> = {
  host: Object.assign(new Error("refused"), {
    code: "transport.method_refused",
    data: { origin: "native", method: "_acpmux/inbox_threads" },
  }),
  offline: Object.assign(new Error("not connected"), { code: "native.not_connected" }),
  daemon: Object.assign(new Error("inbox store is locked by another acpmux (pid 4412)"), { code: -32000 }),
};
const readThread = async (threadId: string): Promise<InboxMessage[]> => {
  const thread = THREADS.find((t) => t.threadId === threadId)!;
  return [{ promptId: `${threadId}-1`, from: thread.from[0]!, at: thread.newestAt, text: thread.newestPreview }];
};

// The pane's column inset (--cv-inset), which the row and the composer both stand on.
const STAGE = {
  display: "flex",
  flexDirection: "column",
  justifyContent: "flex-end",
  height: "100%",
  maxWidth: 760,
  "--cv-inset": "16px",
} as CSSProperties;

function Stage({ look = "counts", surface = "stack", held, needYou, open = false, failing, unmarked }: Props) {
  const list = failing ? () => Promise.reject(FAILURES[failing]) : unmarked ? unmarkedList : listThreads;
  return (
    <div className="acpmux-shell" style={STAGE}>
      <div className="acpmux-dock">
        <SurgeHoldRow
          surge={{ held, needYou, seq: 1 }}
          sessionId={`gallery-surge-${look}-${surface}-${open}-${failing ?? ""}-${unmarked ?? ""}`}
          listThreads={list}
          readThread={readThread}
          onOpenSender={() => undefined}
          look={look}
          surface={surface}
          initiallyOpen={open}
          connected={failing !== "offline"}
        />
        {/* A stand-in for the composer card the row sits on (Composer.tsx), its glass and edge only. */}
        <div className="acpmux-composer">
          <div className="acpmux-composer-box ui-glass ui-glass-floats ui-glass-material" style={{ minHeight: 76 }} />
        </div>
      </div>
    </div>
  );
}

const listed: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-surge-threads .cv-inbox"));
};
const noted: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-surge-note:is([role="alert"], [data-empty])'));
};

export default componentEntry<Props>({
  id: "agent-pane.surge-hold-row",
  title: "Held message surge row",
  area: "Agent pane",
  pane: true,
  height: 560,
  widths: { narrow: 420, normal: 760 },
  covers: ["agent-session/acpmux/SurgeHoldRow.tsx#SurgeHoldRow"],
  styles: () =>
    Promise.all([import("./styles.css"), import("./conversation/conversation.css"), import("./SurgeHoldRow.css")]),
  load: async () => Stage,
  variants: {
    counts: {
      props: { held: 37, needYou: 2 },
      note: "Shipped (surface stack): the row is the top of the bottom stack, the tray header's look on the stack's glass, joined to the composer with one hairline.",
    },
    "surface-card": {
      props: { surface: "card", held: 37, needYou: 2 },
      note: "Variant: the same glass as its own card, one 4px step over the composer.",
    },
    "surface-line": {
      props: { surface: "line", held: 37, needYou: 2 },
      note: "Variant: no card, a quiet line over the composer.",
    },
    "counts-held-only": {
      props: { held: 33, needYou: 0 },
      note: "Shipped, nothing needs the person: the line alone, muted mark.",
    },
    sentence: {
      props: { look: "sentence", held: 37, needYou: 2 },
      note: "Variant: the counts as one phrase, no pill.",
    },
    "need-first": {
      props: { look: "needFirst", held: 37, needYou: 2 },
      note: "Variant: the need-you count leads the line, inside the toggle.",
    },
    open: {
      props: { held: 37, needYou: 2, open: true },
      note: "Open: the search field, the held / need-you filter and the held threads, the one that needs the person first.",
      play: listed,
    },
    "open-card": {
      props: { surface: "card", held: 37, needYou: 2, open: true },
      note: "Open, card surface.",
      play: listed,
    },
    "open-unmarked": {
      props: { held: 100, needYou: 0, open: true, unmarked: true },
      note: "Open while acpmux counts a surge but marks no thread held: says so, lists nothing (before, every inbox thread showed).",
      play: noted,
    },
    "open-host-refused": {
      props: { held: 37, needYou: 0, open: true, failing: "host" },
      note: "The app refuses the listing (an older cmux): says to update cmux; no button, a retry cannot help.",
      play: noted,
    },
    "open-offline": {
      props: { held: 37, needYou: 0, open: true, failing: "offline" },
      note: "Not connected: says the list loads on reconnect; no button, it reads by itself.",
      play: noted,
    },
    "open-daemon-error": {
      props: { held: 37, needYou: 0, open: true, failing: "daemon" },
      note: "acpmux answers with an error: its message, no button; it reads again on the next snapshot.",
      play: noted,
    },
  },
});
