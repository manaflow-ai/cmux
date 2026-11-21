// l10n-allow-file: public-safe gallery chat fixtures.
// A chat in acpmux's cold archive (hub/cold_archive.rs): before it is archived its card reads the
// live log's last reply; after, the same card reads its kept preview's last message, with a muted
// Compressed badge. Nothing else on the card moves.
import type { ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import type { ChatCards } from "./ChatCards";
import type { ChatCard } from "./screenModel";

const live: ChatCard[] = [
  {
    sessionId: "s-1",
    title: "Review the settings",
    age: "2m",
    state: "idle",
    harness: "codex",
    message: "Ready for the next step.",
  },
  {
    sessionId: "s-2",
    title: "Tune the build cache",
    age: "41d",
    state: "idle",
    harness: "claude",
    message: "The cache now hits on every target, and the cold build is under four minutes.",
  },
  { sessionId: "s-3", title: "Update the docs", age: "3h", state: "idle", harness: "claude", message: "Docs updated." },
];
const archived: ChatCard[] = live.map((card) => (card.sessionId === "s-2" ? { ...card, archived: true } : card));
const allArchived: ChatCard[] = live.map((card, index) => ({
  ...card,
  age: `${40 + index}d`,
  archived: true,
}));
const base = { onOpen: () => undefined, onColdArchive: () => undefined };

export default componentEntry<ComponentProps<typeof ChatCards>>({
  id: "agent-pane.chat-cards-archive",
  title: "Recent chat cold archive",
  area: "Agent pane",
  covers: ["agent-session/acpmux/newtab/ChatCards.tsx#ChatCards"],
  styles: () => Promise.all([import("../styles.css"), import("./screen.css")]),
  load: () => import("./ChatCards").then((module) => module.ChatCards),
  widths: { narrow: 320, normal: 620, wide: 820 },
  height: 320,
  anchors: [{ selector: ".nt-chats" }],
  variants: {
    "before-cards": {
      props: { ...base, cards: live },
      note: "Before Compress Chat: the middle card reads its live log.",
    },
    "after-cards": {
      props: { ...base, cards: archived },
      note: "After Compress Chat: the same card, badged Compressed, reads its kept preview.",
    },
    "before-list": { props: { ...base, cards: live, variant: "list" }, note: "Before, in the list layout." },
    "after-list": {
      props: { ...base, cards: archived, variant: "list" },
      note: "After, in the list layout: the badge sits before the agent mark.",
    },
    "all-archived": { props: { ...base, cards: allArchived }, note: "Every recent chat compressed." },
  },
});
