// l10n-allow-file: gallery fixtures (made-up people, prompts and replies), not shipped UI.
// The whole pane on a shared chat (hq plans/cmux-next/chat-multiplayer/DESIGN.md; Leo, 2026-10-26:
// "we can still do the regular chat multiplayer", and earlier "also chief chats we need
// multiplayer"): each teammate's prompt under their face and name, the reader's own as always,
// who else is here in the header, who is typing over the composer, and who answered an ask.
// `alone` is the same chat with nobody else: it draws as every chat did before.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, row, summary, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxRow, AcpmuxSnapshot } from "../model";
import type { ChatPresence } from "./participants";
import { ANA, JORDAN, MEI, SAM } from "./people.fixtures";

const rows = (shared: boolean): AcpmuxRow[] => [
  user("Add retry with backoff to the uploader", 14, { seq: 1, ...(shared && { author: ANA }) }),
  assistant("Done: three tries, doubling from 200 ms, only on 5xx and timeouts.", 13),
  summary(13, { seq: 3, status: "completed" }),
  user("Cover it with a test that fakes two timeouts", 9, { seq: 4 }),
  row("permissionRecord", 8, {
    permission: {
      permissionId: "perm-1",
      title: "bun test src/uploader",
      pending: false,
      options: [{ id: "allow", name: "Allow once", allow: true, kind: "allow_once" }],
    },
    decision: { kind: "allowed" },
    ...(shared && { answeredBy: SAM }),
  }),
  assistant("Added `uploader.retry.test.ts`; it passes, and fails without the retry.", 7),
  summary(7, { seq: 8, status: "completed" }),
  user("Also log each retry at debug level", 3, { seq: 9, ...(shared && { author: SAM }) }),
  assistant("Each retry now logs its attempt and wait at debug level.", 2),
  summary(2, { seq: 11, status: "completed" }),
];

const sharedChat = (presence: ChatPresence | undefined, shared = true): AcpmuxSnapshot => ({
  ...chat(rows(shared), { title: "Uploader retries" }),
  ...(presence && { presence }),
});

export default agentPaneEntry({
  id: "agent-pane.shared-chat",
  title: "Agent pane: shared chat",
  area: "Agent pane",
  keywords: ["multiplayer", "presence", "typing", "author", "teammate", "answered by"],
  covers: ["agent-session/acpmux/multiplayer/Faces.tsx"],
  height: 760,
  variants: {
    shared: {
      note: "Three teammates: authors on their prompts, Sam answered the ask, Ana is typing.",
      snapshot: sharedChat({ viewing: [ANA, SAM, MEI], typing: [ANA] }),
    },
    crowded: {
      note: "Four others here (+1 past the stack), two typing at once.",
      snapshot: sharedChat({ viewing: [ANA, SAM, MEI, JORDAN], typing: [ANA, SAM] }),
    },
    alone: {
      note: "Before: the same chat with nobody else; no faces, no authors, no typing line.",
      snapshot: sharedChat(undefined, false),
    },
  },
});
