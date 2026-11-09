// l10n-allow-file: gallery fixtures (sample agent names and messages), not shipped UI.
// Another agent's inbox thread read in place (InboxNoticeCard.tsx): shut, the newest message whole
// under the line, cut past eight lines with Show more; "+N more" or the line opens the whole thread
// in the same card, each message under its sender and age (Leo, 2026-11-09: "if cmux-next could be
// the bridge between claude desktop and codex desktop, that'd be super cool. we should keep going
// further into the whole messaging system type situation"). Each thread here held only its preview
// (past acpmux's 4 KB, the case Leo's capture showed, "From desktop-leo. Leo, 2026-11-09: \"tell the
// claud..."), so the line reads its messages as `chat.inbox.thread` would. The `drill-*` versions
// are inboxThreadLook.ts's `drill` look. Names and messages are made up.
import { useState } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { PromptMarksSession } from "../threadMinimap/promptMarks";
import { InboxNoticeCard } from "./InboxNoticeCard";
import { inboxThreadKey, type InboxMessage, type InboxNotice } from "./inboxNotice";
import { setMessageOpened } from "./incomingOpened";
import { configureInboxThreadLook, type InboxThreadLook } from "./inboxThreadLook";
import { newestWholeKey } from "./inboxThreadRead";

type Kind = "short" | "long" | "several";
type Props = { kind: Kind; look?: InboxThreadLook; open?: boolean; whole?: boolean };

const MINUTE = 60_000;
const NOW = Date.now();

const SHORT: InboxMessage[] = [
  {
    promptId: "s1",
    from: "desktop-leo",
    at: NOW - 3 * MINUTE,
    text: "From desktop-leo. Leo, 2026-11-09: \"tell the claude lane the review passed, it can land #38912\"",
  },
];

const LONG: InboxMessage[] = [
  {
    promptId: "l1",
    from: "ao-log-bloat",
    at: NOW - 6 * MINUTE,
    text: [
      "**Broker refusal on #28564.** The broker's GitHub returned 403 on the land, so I couldn't merge it.",
      "",
      "What I checked before asking:",
      "",
      "- the review is SHIP at `3b01de6`, a different family's",
      "- the only red is `release-notary`, red on base too (run 8812)",
      "- `merge_freeze.py check` exits 0",
      "- no HOLD line, no hold label",
      "",
      "What I tried:",
      "",
      "1. `lane-gh call land` twice, ten minutes apart: 403 both times",
      "2. `lane-gh call get` on the PR: works, so the token is alive",
      "3. a rerun of `release-notary`: still red, same as base",
      "",
      "Can you land it from a host with a token? The pinned command is",
      "`gh pr merge 28564 --squash --match-head-commit 3b01de6`.",
      "",
      "If not, I'll hand it to the coordinator in cmuxterm-hq with this note.",
    ].join("\n"),
  },
];

const SEVERAL: InboxMessage[] = [
  { promptId: "r1", from: "picker-lane", at: NOW - 14 * MINUTE, text: "The rail's band now reaches the last tick." },
  {
    promptId: "r2",
    from: "review-box",
    at: NOW - 9 * MINUTE,
    text: "Checked it in the gallery at both widths; it does.\n\nOne nit: the band's end cap is 1px short at 420px.",
  },
  {
    promptId: "r3",
    from: "picker-lane",
    at: NOW - 2 * MINUTE,
    text: "**Merged as #2231.**\n\n- the band ends on the tick at every width\n- the 1px end cap is fixed in the same commit",
  },
];

const THREADS: Record<Kind, { threadId: string; label: string; messages: InboxMessage[]; session: string }> = {
  short: { threadId: "from:desktop-leo", label: "", messages: SHORT, session: "s-desktop" },
  long: { threadId: "from:ao-log-bloat/pr:28564", label: "#28564", messages: LONG, session: "s-log-bloat" },
  several: { threadId: "topic:rail", label: '"rail"', messages: SEVERAL, session: "s-picker" },
};

/// The notice as acpmux sends one past 4 KB: the newest message's first line, no messages.
function noticeOf(kind: Kind): InboxNotice {
  const { threadId, label, messages, session } = THREADS[kind];
  return {
    threads: [
      {
        threadId,
        label,
        from: [...new Set(messages.map((m) => m.from))],
        count: messages.length,
        preview: messages.at(-1)!.text.split("\n")[0]!.slice(0, 120),
        blocker: false,
        promptIds: messages.map((m) => m.promptId!),
        fromSession: session,
      },
    ],
  };
}

function Stage({ kind, look = "inline", open = false, whole = false }: Props) {
  const session = `gallery-inbox-thread-${kind}-${look}-${open}-${whole}`;
  const rowId = `row-${kind}`;
  const [notice] = useState(() => {
    configureInboxThreadLook(look);
    const key = inboxThreadKey(rowId, THREADS[kind].threadId);
    setMessageOpened(session, key, open);
    setMessageOpened(session, newestWholeKey(key), whole);
    return noticeOf(kind);
  });
  const readThread = async () => THREADS[kind].messages;
  return (
    <PromptMarksSession.Provider value={session}>
      <div className="acpmux-shell" style={{ padding: 16, maxWidth: 800, alignItems: "flex-start" }}>
        <div className="cv-incoming" style={{ width: "100%", minWidth: 0 }}>
          <InboxNoticeCard rowId={rowId} notice={notice} onOpen={() => undefined} readThread={readThread} />
        </div>
      </div>
    </PromptMarksSession.Provider>
  );
}

/// The line has read its thread: the card holds the newest message's words, not its preview alone.
const read: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cv-agentmsg__card .cv-md"));
};

export default componentEntry<Props>({
  id: "agent-pane.inbox-thread",
  title: "An inbox thread read in place",
  area: "Agent pane",
  pane: true,
  height: 460,
  widths: { narrow: 420, normal: 760 },
  covers: [
    "agent-session/acpmux/conversation/InboxNoticeCard.tsx#InboxNoticeCard",
    "agent-session/acpmux/conversation/ClampedText.tsx#ClampedText",
  ],
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  load: async () => Stage,
  variants: {
    short: {
      props: { kind: "short" },
      note: "Shut, a short message: the sender's line, and under it the whole message, with no first line repeated on the line and nothing to open.",
      play: read,
    },
    long: {
      props: { kind: "long" },
      note: "Shut, a long message: its first eight lines whole, cut between lines, with Show more under them as a sent message's card has.",
      play: read,
    },
    "long-shown": {
      props: { kind: "long", whole: true },
      note: "The long message after Show more: every line, Show less under it; the line above has not moved.",
      play: read,
    },
    several: {
      props: { kind: "several" },
      note: 'Shut, a thread of three from two senders: the newest message whole, "+2 more" after the label as a control that opens the thread.',
      play: read,
    },
    "several-open": {
      props: { kind: "several", open: true },
      note: '"+2 more" (or the line) opened: every message in the same card, oldest first and newest last, each under its sender and age. Picked as the default: one click shows all the words.',
      play: read,
    },
    "drill-several": {
      props: { kind: "several", look: "drill", open: true },
      note: "Gallery version (theme inboxThreadLook drill): opened, as the Background tasks panel drills in, a back control and the thread's name over a row per message (sender, age, first line).",
      play: read,
    },
    "drill-message": {
      props: { kind: "several", look: "drill", open: true },
      note: "Gallery version (drill): a row drilled into, its message whole under a back control to the rows.",
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelectorAll(".cv-inbox__row").length === 3);
        ctx.document.querySelectorAll<HTMLButtonElement>(".cv-inbox__row")[1]?.click();
        await ctx.waitFor(() => ctx.document.querySelector(".cv-inbox__drill .cv-inbox__message"));
      },
    },
  },
});
