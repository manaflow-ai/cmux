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
  height: 150,
  covers: ["agent-session/acpmux/ManagedBannerDesigns.tsx#ManagedBannerDesigns"],
  styles: () => import("./styles.css"),
  load: () => import("./ManagedBannerDesigns").then((module) => module.ManagedBannerDesigns),
  variants: {
    "pill": {
      note: "Floating pill, centered over the composer, with the reassurance after a dot.",
      props: { design: "pill", manager: chief },
    },
    "pill-dot": {
      note: "Pill with a live dot that pulses while the Chief is sending; × hides it.",
      props: { design: "pill-dot", manager: chief },
    },
    "pill-avatar": {
      note: "Pill led by the Chief's monogram badge; × hides it.",
      props: { design: "pill-avatar", manager: chief },
    },
    "pill-straddle": {
      note: "Pill sitting on the composer's top edge, half over the card.",
      props: { design: "pill-straddle", manager: chief },
    },
    "pill-glass": {
      note: "Translucent blurred pill floating over the transcript.",
      props: { design: "pill-glass", manager: chief },
    },
    "pill-accent": {
      note: "Accent-tinted pill, louder, with the badge and Hide.",
      props: { design: "pill-accent", manager: chief },
    },
    "pill-left": {
      note: "Pill anchored to the composer's left edge, like a reply chip.",
      props: { design: "pill-left", manager: chief },
    },
    "pill-mini": {
      note: "Smallest: badge, 'Chief is sending', ×.",
      props: { design: "pill-mini", manager: chief },
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
