// l10n-allow-file: gallery fixtures (sample drafts and chats) and comparison notes, not shipped UI.
// The composer refresh (composerV2.experiment.ts `composer-v2-look`, composerV2.css, ComposerBox.tsx):
// the round send, the edge light on focus, the accented send once the draft has text. The setting is
// off by default; the gallery's `arm` override turns the V2 look on, so the states here pin no arm
// and View Compare arms draws each of them once per look (rim, halo, hairline) side by side. With no
// arm (the plain stage) they show the shipped composer: the before.
// When V2 is on, `.acpmux-composer-box` carries `data-composer-v2=<arm>` and `data-has-text="true"`
// while the draft has text; the plays check that contract whenever the attribute is there.
import { agentPaneEntry } from "../../gallery/format";
import type { Play, PlayContext } from "../../gallery/play";
import { assistant, chat, CWD, user } from "../../gallery/fixtures/acpmux";
import { composerV2Look } from "./composerV2.experiment";
import { COMPOSER_EDITOR } from "./composerSelectors";

const BOX = ".acpmux-composer-box";
const DRAFT = "Refactor the settings loader and add tests";
const MENTION_PATH = "src/settings/loader.ts";

/// A started Claude Code chat that reports its modes, so the mode chip draws in the composer foot.
const startedChat = (currentModeId = "default") => {
  const snapshot = chat([
    user("Why does the settings loader read the file twice on launch?", 14),
    assistant(
      "`loadSettings` reads `settings.json` once to find the schema version and again to parse it. One read is enough: parse once, then branch on `version`. The migration path keeps working because it already takes the parsed object.",
      13,
    ),
  ]);
  snapshot.summary = {
    ...snapshot.summary!,
    modes: {
      currentModeId,
      availableModes: [
        { id: "default", name: "Ask before edits", description: "Review changes before they run" },
        { id: "acceptEdits", name: "Edit automatically", description: "Make edits without asking" },
        { id: "plan", name: "Plan", description: "Plan before making changes" },
      ],
    },
  };
  return snapshot;
};

const box = (ctx: PlayContext) => ctx.document.querySelector<HTMLElement>(BOX);
const promptText = (ctx: PlayContext) => ctx.document.querySelector(COMPOSER_EDITOR)?.textContent ?? "";

/// The V2 contract, whenever an arm turned the look on: the box names its arm and says whether the
/// draft has text. Without an arm (the plain stage) the composer is the shipped one and carries neither.
function checkContract(ctx: PlayContext, hasText: boolean) {
  const element = box(ctx);
  if (!element) throw new Error("no composer box");
  const arm = element.dataset.composerV2;
  if (arm === undefined) return;
  if (!(arm in composerV2Look.arms)) throw new Error(`data-composer-v2 names no arm: ${arm}`);
  if ((element.dataset.hasText === "true") !== hasText)
    throw new Error(`data-has-text is ${element.dataset.hasText ?? "absent"} with ${hasText ? "a" : "no"} draft`);
}

/// No text, not focused: the dim round send.
const idle: Play = async (ctx) => {
  await ctx.waitFor(() => box(ctx) && ctx.document.querySelector(COMPOSER_EDITOR));
  checkContract(ctx, false);
};

const focusPrompt: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(COMPOSER_EDITOR));
  await ctx.focus({ selector: COMPOSER_EDITOR });
  await ctx.waitFor(() => ctx.document.activeElement === ctx.document.querySelector(COMPOSER_EDITOR));
};

const typeDraft: Play = async (ctx) => {
  await ctx.type(DRAFT, { selector: COMPOSER_EDITOR });
  await ctx.waitFor(() => promptText(ctx).includes(DRAFT));
  await ctx.waitFor(() => box(ctx)?.dataset.composerV2 === undefined || box(ctx)?.dataset.hasText === "true");
  checkContract(ctx, true);
};

/// Focused with a draft: the edge light on, send accented.
const focusedTyped: Play = async (ctx) => {
  await focusPrompt(ctx);
  await typeDraft(ctx);
};

/// Focused, a file mention the @ picker wrote (its Return writes the path and a space), then the ask.
const mention: Play = async (ctx) => {
  await focusPrompt(ctx);
  await ctx.type("@loader", { selector: COMPOSER_EDITOR });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-mention-row[data-mention-kind='file']"));
  await ctx.waitFor(
    () => ctx.document.querySelector(COMPOSER_EDITOR)?.getAttribute("aria-activedescendant") === "acpmux-mention-0",
  );
  await ctx.press("Enter");
  await ctx.waitFor(() => ctx.document.querySelector(COMPOSER_EDITOR)?.getAttribute("aria-expanded") === "false");
  await ctx.type("create issues and assign to me", { selector: COMPOSER_EDITOR });
  await ctx.waitFor(() => promptText(ctx).includes(`@${MENTION_PATH} create issues and assign to me`));
  checkContract(ctx, true);
};

const SEND_ARRIVES = {
  layoutShiftMax: {
    value: 0.003,
    reason:
      "Send comes in after the mic with the draft's first letter, moving the mic one slot left (composer.gallery.ts measures 0.0026 for the same move).",
  },
};

export default agentPaneEntry({
  id: "agent-pane.composer-v2",
  title: "Composer refresh (V2): round send, edge light, accented send",
  area: "Agent pane",
  height: 520,
  widths: { narrow: 420, normal: 900, wide: 1400 },
  covers: [
    "agent-session/acpmux/ComposerBox.tsx",
    "agent-session/acpmux/composerV2.css",
    "agent-session/acpmux/composerV2.experiment.ts",
  ],
  keywords: ["composer", "composer v2", "send button", "edge light", "rim", "halo", "hairline"],
  experiment: {
    definition: composerV2Look,
    script: [
      { name: "Focus the prompt", run: focusPrompt },
      { name: "Type a draft", run: typeDraft },
    ],
  },
  variants: {
    empty: {
      note: "No text, not focused: the dim round send. View Compare arms draws rim, halo and hairline side by side.",
      snapshot: startedChat(),
      play: idle,
    },
    "focused-typed": {
      note: "The prompt focused with a draft: the edge light on and the send accented.",
      snapshot: startedChat(),
      play: focusedTyped,
      checks: SEND_ARRIVES,
    },
    mention: {
      note: "Focused, a file the @ picker wrote inline, then the ask: the mention reads as part of the draft.",
      snapshot: startedChat(),
      native: { "file.search": { root: CWD, results: [{ path: MENTION_PATH, matches: [13, 14, 15, 16, 17, 18] }] } },
      play: mention,
      checks: SEND_ARRIVES,
    },
    chips: {
      note: "The foot's chips with one active (Edit automatically as the mode), focused with a draft.",
      snapshot: startedChat("acceptEdits"),
      play: focusedTyped,
      checks: SEND_ARRIVES,
    },
  },
});
