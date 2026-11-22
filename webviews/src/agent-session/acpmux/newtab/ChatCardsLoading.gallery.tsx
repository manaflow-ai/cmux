// l10n-allow-file: public-safe gallery chat fixtures.
import type { ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import type { ChatCards } from "./ChatCards";
import type { ChatCard } from "./screenModel";

const cards: ChatCard[] = ["Review the settings", "Update the docs", "Check the build"].map((title, index) => ({
  sessionId: `sample-${index}`,
  title,
  age: `${index + 1}m`,
  state: "idle",
  harness: "codex",
  message: "Ready for the next step.",
}));
const base = { onOpen: () => undefined };

export default componentEntry<ComponentProps<typeof ChatCards>>({
  id: "agent-pane.chat-cards-loading",
  title: "Recent chat loading",
  area: "Agent pane",
  covers: ["agent-session/acpmux/newtab/ChatCards.tsx#ChatCards"],
  styles: () => Promise.all([import("../styles.css"), import("./screen.css")]),
  load: () => import("./ChatCards").then((module) => module.ChatCards),
  widths: { narrow: 320, normal: 620, wide: 820 },
  height: 320,
  anchors: [{ selector: ".nt-chats" }],
  variants: {
    "pending-cards": { props: { ...base, cards: [], pending: true }, note: "First read pending in the card layout." },
    "pending-list": {
      props: { ...base, cards: [], pending: true, variant: "list" },
      note: "First read pending in the list layout.",
    },
    "loaded-cards": { props: { ...base, cards }, note: "Settled card layout." },
    "loaded-list": { props: { ...base, cards, variant: "list" }, note: "Settled list layout." },
    refreshing: { props: { ...base, cards, pending: true }, note: "Existing cards stay visible during refresh." },
    empty: { props: { ...base, cards: [], pending: false }, note: "A settled empty list keeps its existing message." },
  },
});
