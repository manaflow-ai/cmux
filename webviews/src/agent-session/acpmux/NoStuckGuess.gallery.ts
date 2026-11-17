// l10n-allow-file: gallery-only recorded chat, sample diagnoses and agent errors.
// The pane draws no "Agent may be stuck" guess and no "Nudge with hint" button (#45162): they showed
// on chats that were not stuck (a signed-out Codex chat among them) and their nudge put an
// "The agent may be stuck: …" message in the composer. The daemon may still report a loop episode or
// a silent turn in the chat's summary; the real pane, composer and bridge mounted here must ignore
// both, and a real failure must still show its error card.
import { agentPaneEntry } from "../../gallery/format";
import type { PlayContext } from "../../gallery/play";
import { assistant, CATALOG, chat, summary, user } from "../../gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "./model";

const diagnosis = "Ran cargo test 4 times; the same error in auth.rs:88 each time";
const stuckFields = {
  status: "running",
  loopEpisode: { episodeId: 1, since: 1_783_517_200_000, count: 4, diagnosis, hint: diagnosis },
  stalledSince: 1_783_517_200_000,
};
const withStuckSummary = (snapshot: AcpmuxSnapshot): AcpmuxSnapshot => ({
  ...snapshot,
  summary: { ...snapshot.summary!, ...stuckFields },
});

/// A running chat whose summary carries both of the daemon's old "stuck" signals.
const running = withStuckSummary(
  chat([user("Fix the auth tests.", 4), assistant("I am checking the failing auth test.", 3)], {
    isWorking: true,
    title: "Fix the auth tests",
  }),
);
/// The report's case: a signed-out Codex chat. Its failed turn keeps its error card.
const signedOutCodex = withStuckSummary(
  chat(
    [
      user("Run the sidebar tests and fix what fails", 6),
      summary(5.5, { status: "failed", durationMs: 4_000, error: "Not logged in · Please run /login" }),
    ],
    {
      title: "Codex chat",
      harness: "codex",
      model: "gpt-5-codex",
      catalog: CATALOG.map((entry) => (entry.id === "codex" ? { ...entry, auth: { login: "codex login" } } : entry)),
    },
  ),
);

const editor = ".acpmux-composer > .acpmux-composer-box [contenteditable='true']";

/// No stuck banner, pane ring, nudge button or injected nudge text anywhere in the pane.
const noStuckGuess = (ctx: PlayContext) => {
  const doc = ctx.document;
  if (doc.querySelector(".acpmux-stuck-banner, .acpmux-stuck-nudge, [data-stuck]"))
    throw new Error("the pane drew the removed stuck attention");
  const text = doc.body.textContent ?? "";
  for (const words of ["may be stuck", "Nudge with hint", "try a different approach", diagnosis])
    if (text.includes(words)) throw new Error(`the pane says "${words}"`);
  if (doc.querySelector(editor)?.textContent?.trim()) throw new Error("the composer holds an injected draft");
};

const ready = (ctx: PlayContext) => ctx.waitFor(() => ctx.document.querySelector(editor));

export default agentPaneEntry({
  id: "agent-pane.no-stuck-guess",
  title: "No stuck guess in a chat",
  area: "Agent pane",
  height: 620,
  widths: { narrow: 420, normal: 720, wide: 1000 },
  covers: ["agent-session/acpmux/App.tsx", "agent-session/acpmux/conversation/TurnRows.tsx#TurnFooter"],
  variants: {
    running: {
      note: "A running chat the daemon calls looping or silent shows no stuck card, ring or nudge.",
      snapshot: running,
      play: async (ctx) => {
        await ready(ctx);
        noStuckGuess(ctx);
      },
    },
    "quick-running": {
      note: "The Quick Composer chat surface shows none either.",
      ready: { surface: "quick" },
      snapshot: running,
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-shell[data-surface="quick"]'));
        noStuckGuess(ctx);
      },
    },
    "signed-out-codex": {
      note: "A signed-out Codex chat keeps its real error card and shows no stuck guess beside it.",
      snapshot: signedOutCodex,
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".cv-turn-error"));
        await ready(ctx);
        noStuckGuess(ctx);
      },
    },
  },
});
