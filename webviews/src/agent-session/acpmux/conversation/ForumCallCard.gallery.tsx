// l10n-allow-file: gallery fixture labels, not shipped UI.
// The forum tool-call card's three looks side by side (ForumCallCard.tsx): each draws a post, a
// reply, a search, one still running and one that failed. Leo, 2026-11-22 07:44Z: "i wonder if
// that's also grounds for a new type of tool call appearance in the gui". The transcript draws
// "card" (agent-pane.forum-call shows it in a chat). Under them, `agent-forum` shell commands
// (forumShellCalls.ts) in the same look: a list, a read, an answer that left the thread open and an
// ask refused as a duplicate (agent-pane.forum-shell-call shows them in a chat).
import { componentEntry } from "../../../gallery/format";
import { ForumCallCard, type ForumCardLook } from "./ForumCallCard";
import { forumCall } from "./forumCalls";
import { mcpCall } from "./mcpCalls";
import { forumShellCall } from "./forumShellCalls";
import { postCall, replyCall, searchCall, unconfiguredCall } from "./forumCalls.fixtures";
import * as shell from "./forumShellCalls.fixtures";

const ITEMS = [postCall(), replyCall(), searchCall(), postCall("in_progress"), unconfiguredCall()];
const SHELL = [shell.manyHitsCall(), shell.showCall(), shell.closeCall(), shell.askRefusedCall()];

function Stage({ look }: { look: ForumCardLook }) {
  return (
    <div className="acpmux-shell" style={{ display: "flex", flexDirection: "column", gap: 12, padding: 16 }}>
      {ITEMS.map((item) => {
        const call = forumCall(item.tool!, mcpCall(item.tool!));
        return call ? <ForumCallCard key={item.tool!.id} item={item} call={call} look={look} /> : null;
      })}
      {SHELL.map((item) => {
        const call = forumShellCall(item.tool!);
        return call ? <ForumCallCard key={item.tool!.id} item={item} call={call} look={look} /> : null;
      })}
    </div>
  );
}

export default componentEntry<{ look: ForumCardLook }>({
  id: "agent-pane.forum-call-looks",
  title: "Forum tool call: card looks",
  area: "Agent pane",
  experimental: true,
  pane: true,
  height: 1040,
  widths: { narrow: 420, normal: 640, wide: 820 },
  covers: [
    "agent-session/acpmux/conversation/ForumCallCard.tsx",
    "agent-session/acpmux/conversation/forumShellCalls.ts",
  ],
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  load: async () => Stage,
  variants: {
    "a-line": {
      note: "A: the quiet tool line, the thread's title and reply count after it on the same line. Fewest pixels; reads like any other tool row.",
      props: { look: "line" },
    },
    "b-card": {
      note: "B (recommended, the transcript's): the line, then the thread in a thin box: title as a link into the thread, its number, space, replies and state.",
      props: { look: "card" },
    },
    "c-quote": {
      note: "C: the card with the words the agent posted (or each hit's snippet) under the title, three lines at most.",
      props: { look: "quote" },
    },
  },
});
