// l10n-allow-file: gallery fixtures (sample prompts and suggestions), not shipped UI.
// Claude Code's suggested next prompt in the composer (Leo, 2026-11-03: "i know there's suggested
// prompts that you can right arrow/tab to do stuff with... maybe we can expose it in cmux-next too";
// "we ought to make these all accessibly toggle-able ofc"). After a turn acpmux sends the agent's
// guess (`prompt_suggestion`); the empty prompt shows it as ghost text, Tab or Right-arrow writes it
// without sending, and typing spends it. acpmux's per-chat switch stays out of the composer; the
// global one is cmux.json `agents.promptSuggestions`. Compare arms (`prompt-suggestion-look`) for the look.
import { agentPaneEntry, type AgentPaneVariant } from "../../gallery/format";
import { assistant, chat, summary, user } from "../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../gallery/play";
import type { AcpmuxSnapshot } from "./model";
import { PROMPT_SUGGESTIONS_OPTION } from "./mockFixture";
import { promptSuggestionLook } from "./promptSuggestionLook.experiment";

const SUGGESTION = "Add a test for the retry backoff";

const withSuggestion = (text: string | undefined, fields: Partial<AcpmuxSnapshot> = {}): AcpmuxSnapshot => {
  const base = chat(
    [
      user("Why do uploads fail on the fleet?", 12),
      assistant("The uploader gives up on the first 503 from the artifact store.", 11),
      summary(11, { status: "completed" }),
      user("Retry 5xx with backoff", 6),
      assistant("Done: the uploader retries 5xx with backoff, up to five tries.", 5),
      summary(5, { status: "completed" }),
    ],
    fields,
  );
  return {
    ...base,
    summary: { ...base.summary!, configOptions: [...(base.summary?.configOptions ?? []), PROMPT_SUGGESTIONS_OPTION] },
    ...(text ? { promptSuggestion: { text, seq: 40 } } : {}),
  };
};

const PROMPT = ".acpmux-composer-prompt [contenteditable='true']";

/** Focuses the empty prompt and presses `key`, then waits for the suggestion to be written. */
async function take(ctx: PlayContext, key: string) {
  await ctx.focus({ selector: PROMPT });
  await ctx.press(key);
  await ctx.waitFor(() => ctx.document.querySelector(PROMPT)?.textContent?.includes(SUGGESTION));
}

const variant = (note: string, snapshot: AcpmuxSnapshot, play?: AgentPaneVariant["play"]): AgentPaneVariant => ({
  note,
  snapshot,
  ...(play ? { play } : {}),
});

export default agentPaneEntry({
  id: "agent-pane.composer-prompt-suggestion",
  title: "Composer prompt suggestion",
  area: "Agent pane",
  height: 560,
  widths: { narrow: 400, normal: 760, wide: 760 },
  covers: ["agent-session/acpmux/Composer.tsx#Composer"],
  keywords: ["suggestion", "ghost text", "tab", "next prompt", "prompt suggestions"],
  variants: {
    suggested: variant(
      "After a turn, the empty prompt shows Claude Code's suggested next prompt as ghost text; Tab or Right-arrow takes it.",
      withSuggestion(SUGGESTION),
    ),
    "long-suggestion": variant(
      "A long suggestion truncates on one line; the Tab keycap stays in a narrow pane.",
      withSuggestion(
        "Add a test that fails the first two uploads with a 503 and checks the third try lands after the backoff",
      ),
    ),
    taken: variant(
      "Play: Tab wrote the suggestion into the prompt (not sent); the caret is at its end.",
      withSuggestion(SUGGESTION),
      (ctx) => take(ctx, "Tab"),
    ),
    "no-suggestion": variant(
      "No suggestion (an older acpmux, suggestions off, or the first turn): the usual placeholder.",
      withSuggestion(undefined),
    ),
  },
  experiment: {
    definition: promptSuggestionLook,
    script: [{ name: "Take it with Tab", run: (ctx) => take(ctx, "Tab") }],
  },
});
