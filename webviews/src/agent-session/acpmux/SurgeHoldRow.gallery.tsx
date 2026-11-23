// l10n-allow-file: gallery fixtures (sample agent names and messages), not shipped UI.
// The chat's held message surge as one row of the composer hat (SurgeHoldRow.tsx; Leo, 2026-11-20:
// "when it gets to states like this all of you need to be able to temporarily let the messages go to
// some inbox that you later categorize/read"). Shut, the counts; open, a search field and the held
// threads in the transcript's received-messages look. Names and messages are made up.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { SurgeHoldRow, type SurgeRowLook } from "./SurgeHoldRow";
import type { InboxMessage } from "./conversation/inboxNotice";

type Props = { look?: SurgeRowLook; held: number; needYou: number; open?: boolean; failing?: boolean };

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
const failingList = () => Promise.reject(new Error("offline"));
const readThread = async (threadId: string): Promise<InboxMessage[]> => {
  const thread = THREADS.find((t) => t.threadId === threadId)!;
  return [{ promptId: `${threadId}-1`, from: thread.from[0]!, at: thread.newestAt, text: thread.newestPreview }];
};

function Stage({ look = "counts", held, needYou, open = false, failing = false }: Props) {
  return (
    <div className="acpmux-shell" style={{ padding: 16, maxWidth: 760, justifyContent: "flex-end", height: "100%" }}>
      <SurgeHoldRow
        surge={{ held, needYou, seq: 1 }}
        sessionId={`gallery-surge-${look}-${open}`}
        listThreads={failing ? failingList : listThreads}
        readThread={readThread}
        onOpenSender={() => undefined}
        look={look}
        initiallyOpen={open}
      />
    </div>
  );
}

const listed: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-surge-threads .cv-inbox"));
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
      note: "Shipped: one line, the title and the held count, and a need-you pill that opens the panel on those alone.",
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
    "open-failed": {
      props: { held: 37, needYou: 0, open: true, failing: true },
      note: "Open while acpmux cannot list the inbox: one line and Try again; the row stays.",
    },
  },
});
