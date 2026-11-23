// l10n-allow-file: gallery fixtures (sample agent names and messages), not shipped UI.
// The chat's held message surge as one row of the bottom stack (SurgeHoldRow.tsx; Leo, 2026-11-20:
// "when it gets to states like this all of you need to be able to temporarily let the messages go to
// some inbox that you later categorize/read"). Shut, the counts; open, a search field and the held
// threads in the transcript's received-messages look. Names and messages are made up.
import { useLayoutEffect } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { assistant, chat, user } from "../../gallery/fixtures/acpmux";
import { Composer } from "./Composer";
import { SurgeHoldRow, type SurgeRowLook } from "./SurgeHoldRow";
import type { InboxMessage } from "./conversation/inboxNotice";

/// The row's design arms: `stack` ships (SurgeHoldRow.css), its seam and corner the stack's
/// (bottomStack.css), so it joins the composer where the stack joins and is its own card where the
/// stack is gapped; `own-card` and `line` (SurgeHoldRow.gallery.css) are the alternatives that lost.
type Design = "stack" | "own-card" | "line";

/// The three ways a listing fails, as the pane's relay and acpmux answer (SurgeHoldRow.tsx failureText).
type Failing = "host" | "offline" | "daemon";

type Props = {
  look?: SurgeRowLook;
  design?: Design;
  /// The stack's gapped look (bottomStack.css `data-bottom-stack="cards"`), else its joined default.
  cards?: boolean;
  held: number;
  needYou: number;
  open?: boolean;
  failing?: Failing;
  /// The listing names no thread held (the daemon counts a surge but marks none yet).
  unmarked?: boolean;
};

/// The chat the row sits over: the real composer under it, so the shot shows the row in the stack.
const heldChat = chat(
  [user("Watch the fleet and land the queue", 6), assistant("On it: three PRs queued, CI running.", 5)],
  { title: "Fleet chat", harness: "claude", model: "opus" },
);
const NoChips = () => null;

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

function Stage({
  look = "counts",
  design = "stack",
  cards = false,
  held,
  needYou,
  open = false,
  failing,
  unmarked,
}: Props) {
  const list = failing ? () => Promise.reject(FAILURES[failing]) : unmarked ? unmarkedList : listThreads;
  useLayoutEffect(() => {
    if (!cards) return;
    const root = document.documentElement;
    root.dataset.bottomStack = "cards";
    return () => {
      delete root.dataset.bottomStack;
    };
  }, [cards]);
  return (
    // The pane's own frame (HarnessHealthNotice.gallery.tsx): the stage, then the bottom stack with
    // the row over the real composer.
    <section className="acpmux-shell" data-surge-design={design} style={{ height: "100%" }}>
      <div className="acpmux-main">
        <div className="acpmux-stage" />
        <div className="acpmux-dock">
          <SurgeHoldRow
            surge={{ held, needYou, seq: 1 }}
            sessionId={`gallery-surge-${look}-${design}-${open}-${failing ?? ""}-${unmarked ?? ""}`}
            listThreads={list}
            readThread={readThread}
            onOpenSender={() => undefined}
            look={look}
            initiallyOpen={open}
            connected={failing !== "offline"}
          />
          {/* The losing arms never join, so nothing of the stack's join reaches them. */}
          {design === "stack" ? null : <i hidden />}
          <Composer snapshot={heldChat} chips={NoChips} onSend={() => true} onStop={() => undefined} />
        </div>
      </div>
    </section>
  );
}

const listed: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-surge-threads .cv-inbox"));
};
const noted: Play = async (ctx) => {
  await ctx.waitFor(() =>
    ctx.document.querySelector('.acpmux-surge-failed[role="alert"], .acpmux-surge-note[data-empty]'),
  );
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
    Promise.all([
      import("./styles.css"),
      import("./composerStates.css"),
      import("./bottomStack.css"),
      import("./conversation/conversation.css"),
      import("./SurgeHoldRow.css"),
      import("./SurgeHoldRow.gallery.css"),
    ]),
  load: async () => Stage,
  variants: {
    counts: {
      props: { held: 37, needYou: 2 },
      note: "The pick (design `stack`), for Leo, 2026-11-23: \"the ui for this is still f***ing not style d properly\". A part of the bottom stack in its material and one edge, its seam and corner the stack's own (--acpmux-stack-gap, --acpmux-stack-radius), as the goal row and the tray: here the stack's joined default, square over the composer; the need-you count a quiet button (attention dot, ink words, no fill at rest), the chevron in the trailing column.",
    },
    "counts-cards": {
      props: { cards: true, held: 37, needYou: 2 },
      note: "The pick in the stack's gapped look: its own card one grid step over the composer, the stack's corner.",
    },
    "counts-held-only": {
      props: { held: 33, needYou: 0 },
      note: "The pick, nothing needs the person: the line alone, no need-you button.",
    },
    "own-card": {
      props: { design: "own-card", held: 37, needYou: 2 },
      note: "Alternative: always its own card, one grid step over the composer with 8 px corners, whatever the stack does. Lost: beside a joined goal row or tray the stack shows two seams and two corners.",
    },
    line: {
      props: { design: "line", held: 37, needYou: 2 },
      note: "Alternative: no card, a quiet line on the page over the composer. Lost: it floats free of the stack and reads as transcript text.",
    },
    sentence: {
      props: { look: "sentence", held: 37, needYou: 2 },
      note: "Words arm: the counts as one phrase, no button.",
    },
    "need-first": {
      props: { look: "needFirst", held: 37, needYou: 2 },
      note: "Words arm: the need-you count leads the line, inside the toggle.",
    },
    open: {
      props: { held: 37, needYou: 2, open: true },
      note: "Open: the search field, the held / need-you filter and the held threads, the one that needs the person first.",
      play: listed,
    },
    "need-you": {
      props: { held: 37, needYou: 12, open: true },
      note: "Open on a surge where many need the person: the need-you filter beside held.",
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
