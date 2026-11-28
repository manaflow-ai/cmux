// l10n-allow-file: gallery fixtures (sample chat names), not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { ManagedBannerDesignsProps } from "./ManagedBannerDesigns";
import type { PromptRow } from "./managedBy";

const manager = { kind: "agent", name: "claude-sr2-coord", sessionId: "s-coord" } as const;
const chief = { kind: "chief" } as const;
const now = Date.UTC(2026, 10, 3, 0, 5);
const minutes = (count: number) => now - count * 60_000;
const fromCoord = {
  kind: "message",
  message: { name: "claude-sr2-coord", sessionId: "s-coord", text: "", raw: "" },
} as const;
/** A lane the coordinator dispatched an hour ago and never prompted again. */
const dispatched: PromptRow[] = [
  { kind: "user", at: minutes(60), incoming: fromCoord },
  { kind: "assistant", at: minutes(59) },
];
/** The same lane, steered by the coordinator two minutes ago. */
const steered: PromptRow[] = [...dispatched, { kind: "user", at: minutes(2), incoming: fromCoord }];

export default componentEntry<ManagedBannerDesignsProps>({
  id: "agent-pane.managed-banner-designs",
  title: "A chat another agent is driving (designs)",
  area: "Agent pane",
  experimental: true,
  pane: true,
  height: 200,
  covers: ["agent-session/acpmux/ManagedBannerDesigns.tsx#ManagedBannerDesigns"],
  styles: () => import("./styles.css"),
  load: () => import("./ManagedBannerDesigns").then((module) => module.ManagedBannerDesigns),
  variants: {
    "pill": {
      note: "Jump to latest's glass pill with the sentence and Hide.",
      props: { design: "pill", manager: chief },
    },
    "pill-dot": {
      note: "The Needs you dot in the accent colour while the Chief sends; close icon.",
      props: { design: "pill-dot", manager: chief },
    },
    "pill-avatar": {
      note: "No lead mark; the pill opens the Chief's chat, x hides.",
      props: { design: "pill-avatar", manager: chief },
    },
    "pill-straddle": {
      note: "Pill sitting on the composer's top edge, half over the card.",
      props: { design: "pill-straddle", manager: chief },
    },
    "pill-glass": {
      note: "The same glass, thinner tint.",
      props: { design: "pill-glass", manager: chief },
    },
    "pill-accent": {
      note: "Accent rim and wash; the pill opens the chat, Hide hides.",
      props: { design: "pill-accent", manager: chief },
    },
    "pill-left": {
      note: "Pill anchored to the composer's left edge, like a reply chip.",
      props: { design: "pill-left", manager: chief },
    },
    "pill-mini": {
      note: "Shortest: 'Chief is sending', x.",
      props: { design: "pill-mini", manager: chief },
    },
    "round-pill": {
      note: "1. Round: the pill is a capsule and the bar's chips are capsules (13 px on 26), the card concentric with them (25). On Lucas's one card (+, permissions, model, mic, Send in the input).",
      props: { design: "round-pill", manager: chief },
    },
    "round-soft": {
      note: "2. Soft: the card's 22 px corner (New Tab's --nt-box-radius, 10 px chips + 12 px padding) on the pill too, 48 px tall so 22 reads as a corner.",
      props: { design: "round-soft", manager: chief },
    },
    "round-chip": {
      note: "3. Chip: the pill takes the chips' 7 px corner (--ds-radius-control) and reads as one more chip; the card is 19, concentric.",
      props: { design: "round-chip", manager: chief },
    },
    "round-tab": {
      note: "4. Tab: the pill sits on the card's top edge as a tab (13 px top corners, square foot), one outline with the card.",
      props: { design: "round-tab", manager: chief },
    },
    sending: {
      note: "Picked, and the one that ships: who is sending messages here, that your typing still sends as you, and Hide.",
      props: { design: "sending", manager },
    },
    driving: {
      note: "Shorter, but 'driving' says as little as 'managing' did about what it means for you.",
      props: { design: "driving", manager },
    },
    placeholder: {
      note: "No line at all: the composer's placeholder says it, but it goes the moment you type.",
      props: { design: "placeholder", manager },
    },
    "driving-now": {
      note: "The rule: the coordinator steered this lane two minutes ago, so the line shows.",
      props: { design: "sending", manager, rows: steered, now },
    },
    "dispatched-idle": {
      note: "The rule: the coordinator only dispatched this lane an hour ago, so no line shows.",
      props: { design: "sending", manager, rows: dispatched, now },
    },
    "went-quiet": {
      note: "The rule: the coordinator's last follow-up was 25 minutes ago, past the 10-minute window, so no line shows.",
      props: {
        design: "sending",
        manager,
        rows: [...dispatched, { kind: "user", at: minutes(25), incoming: fromCoord }],
        now,
      },
    },
  },
});
