// l10n-allow-file: public-safe gallery chat fixtures.
import type { ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play, PlayContext } from "../../../gallery/play";
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

// A chat whose agent started two others: its count opens them under it (CardFamily, foldMotion.ts).
const family: ChatCard[] = [
  {
    ...cards[0]!,
    children: ["Read the settings schema", "Draft the copy"].map((title, index) => ({
      sessionId: `sample-child-${index}`,
      title,
      age: `${index + 2}m`,
      state: "idle" as const,
      harness: "claude",
    })),
  },
  ...cards.slice(1),
];
const TOGGLE = ".nt-card-children-toggle";
const settled = (ctx: PlayContext) => ctx.document.getAnimations().length === 0;
const openChildren: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(TOGGLE));
  await ctx.click({ selector: TOGGLE });
  await ctx.waitFor(() => ctx.document.querySelector(".nt-card-children") && settled(ctx), { capMs: 3000 });
  if (ctx.document.querySelector("[data-folding]")) throw new Error("The children's box ended still clipped");
};
const childrenMidFold: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(TOGGLE));
  await ctx.click({ selector: TOGGLE });
  await ctx.waitFor(() => ctx.document.getAnimations().length > 0);
  for (const animation of ctx.document.getAnimations()) {
    animation.pause();
    animation.currentTime = 60;
  }
};

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
    "family-closed": {
      props: { ...base, cards: family, variant: "list" },
      note: "A chat with the two chats its agent started, folded under its count.",
    },
    "family-open-settle": {
      props: { ...base, cards: family, variant: "list" },
      note: 'Chosen. The count opens its chats under it: the box grows and its rows fade in on the settle (--cmux-ease-settle over --cmux-motion-settle, 265 ms) while the cards under it move down on the same frames, fast at first and decelerating into the end (Leo, 2026-11-07: "they dont overshoot but they decelerate at the end. i think that might be the key").',
      play: openChildren,
    },
    "family-mid-fold": {
      props: { ...base, cards: family, variant: "list" },
      note: "The same opening held 60 ms in, on the settle's long soft tail.",
      play: childrenMidFold,
    },
    refreshing: { props: { ...base, cards, pending: true }, note: "Existing cards stay visible during refresh." },
    empty: { props: { ...base, cards: [], pending: false }, note: "A settled empty list keeps its existing message." },
  },
});
