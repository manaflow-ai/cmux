// l10n-allow-file: gallery fixtures, not shipped UI.
// A started Claude chat's pick of a Codex model, after the send (Leo, 2026-11-11: "you select a
// different model ... That's implicitly you're forking it, right? So all it should be is like ...
// there's a line, and it's like, you know, forked from previous"). "before" is the new chat
// Continue In… made: its first message the transcript capsule, after a review. Picked: "forked",
// acpmux's fork onto the other harness (`Hub::fork_onto`): the chat's history above the fork's
// "Forked from" line, then the message on Codex. "scrolled-up" is the same chat read from the top.
// "card" is an alternate, not shipped: the history folded into one card above the line, which
// hides the chat the person came from instead of letting them scroll it.
import { agentPaneEntry } from "../../gallery/format";
import { assistant, chat, row, summary, user } from "../../gallery/fixtures/acpmux";
import type { Play } from "../../gallery/play";
import type { AcpmuxRow } from "./model";

const TITLE = "Release asset step";
const history: AcpmuxRow[] = [
  user("Find why the release build skips the asset step", 9),
  assistant(
    "The asset step is gated on `CI_RELEASE`, which the release job never sets: the workflow exports `RELEASE` instead. Renaming the check fixes it; I left the old name working for a release so no pipeline breaks.",
    8,
  ),
  summary(8, { durationMs: 74_000, toolCount: 6 }),
];
const forkedLine = row("notice", 2, { text: `Forked from ${TITLE}` });
const onCodex: AcpmuxRow[] = [
  user("Double-check that rename against the nightly workflow too", 1),
  assistant(
    "The nightly workflow exports `CI_RELEASE` itself, so it keeps the asset step either way. Only the release job needed the rename.",
    0,
  ),
  summary(0, { durationMs: 31_000, toolCount: 3 }),
];
const codex = { title: `${TITLE} (fork)`, harness: "codex", model: "gpt-6.1-sol" };

const capsule = [
  "Continuing from claude session release-asset-step (01a1…) in ~/src/app. The conversation so far is below; carry on from where it ended.",
  "",
  "<transcript>",
  "User: Find why the release build skips the asset step",
  "",
  "Assistant: The asset step is gated on `CI_RELEASE`, which the release job never sets…",
  "</transcript>",
  "",
  "Double-check that rename against the nightly workflow too",
].join("\n");

const before = chat([user(capsule, 1), ...onCodex.slice(1)], codex);
const forked = chat([...history, forkedLine, ...onCodex], codex);

const hasLine: Play = async (ctx) => {
  await ctx.waitFor(() =>
    [...ctx.document.querySelectorAll(".acpmux-scroll *")].find((node) => node.textContent === `Forked from ${TITLE}`),
  );
  if ([...ctx.document.querySelectorAll(".acpmux-scroll *")].some((node) => node.textContent?.includes("<transcript>")))
    throw new Error("The fork drew the transcript capsule as a message");
};
const fromTop: Play = async (ctx) => {
  await hasLine(ctx);
  const scroll = ctx.document.querySelector(".acpmux-scroll");
  if (scroll) scroll.scrollTop = 0;
};

const card = chat([row("notice", 2, { text: `Forked from ${TITLE} · 1 earlier message, folded` }), ...onCodex], codex);

export default agentPaneEntry({
  id: "agent-pane.model-switch-fork",
  title: "Another harness's model forks the chat",
  area: "Agent pane",
  height: 620,
  widths: { narrow: 400, normal: 760, wide: 960 },
  covers: ["agent-session/acpmux/forkHold.ts"],
  variants: {
    before: {
      snapshot: before,
      note: "Before: Continue In…'s new chat, after a review form; its first message is the transcript capsule.",
    },
    forked: {
      snapshot: forked,
      play: hasLine,
      note: "Picked. The chat's history, the Forked from line, then the message on Codex.",
    },
    "scrolled-up": {
      snapshot: forked,
      play: fromTop,
      note: "Picked, read from the top: the earlier chat scrolls up as it was.",
    },
    card: {
      snapshot: card,
      note: "Alternate, not shipped: the history folded into the line. Hides the chat the person came from.",
    },
  },
});
