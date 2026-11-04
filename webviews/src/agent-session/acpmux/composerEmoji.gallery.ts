// l10n-allow-file: gallery fixtures (sample prompts), not shipped UI.
// Emoji by shortcode in the prompt (Leo, 2026-11-03: "yo wtf i want this kind of feature in
// cmux-next too", of Claude desktop's `:` popover). `:` and two letters at a word start list emoji
// whose GitHub shortcode matches; a text emoticon lists its face with no row chosen, so Return
// still sends it. Compare arms (`emoji-shortcode-look`) for the look; `caret` ships.
import { agentPaneEntry, type AgentPaneVariant } from "../../gallery/format";
import { assistant, chat, summary, user } from "../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../gallery/play";
import { emojiShortcodeLook } from "./emojiShortcodeLook.experiment";

const PROMPT = ".acpmux-composer-prompt [contenteditable='true']";
const ROW = ".acpmux-emoji-row";

const snapshot = chat([
  user("Rename the release checklist and tidy its steps", 8),
  assistant("Done: it is RELEASING.md now, with the steps in the order the script runs them.", 7),
  summary(7, { status: "completed" }),
]);

/** Types `text` into the prompt and waits for the emoji menu to list a row. */
async function typeToMenu(ctx: PlayContext, text: string) {
  await ctx.focus({ selector: PROMPT });
  await ctx.type(text);
  await ctx.waitFor(() => ctx.document.querySelector(ROW) !== null);
}

const promptText = (ctx: PlayContext) => ctx.document.querySelector(PROMPT)?.textContent ?? "";

const variant = (note: string, play: AgentPaneVariant["play"]): AgentPaneVariant => ({ note, snapshot, play });

export default agentPaneEntry({
  id: "agent-pane.composer-emoji",
  title: "Composer emoji shortcodes",
  area: "Agent pane",
  height: 560,
  widths: { narrow: 400, normal: 760, wide: 760 },
  covers: ["agent-session/acpmux/EmojiMenu.tsx#EmojiMenu"],
  keywords: ["emoji", "shortcode", "emoticon", "colon", "autocomplete"],
  checks: {
    layoutShiftMax: {
      value: 0.003,
      reason:
        "The menu draws in the composer's list layer and moves nothing. The first letter of a draft brings in Send, moving the mic one slot left (composer.gallery.ts SEND_ARRIVES): 0.0002 here.",
    },
  },
  variants: {
    tedd: variant("Play: `:tedd` lists the teddy bear first, letters bold, over the typed `:`; none chosen.", (ctx) =>
      typeToMenu(ctx, "Ship it :tedd"),
    ),
    "emoticon-dd": variant(
      "Play: the emoticon `:DD` lists a laughing face first (Claude desktop offered a middle finger), with no row chosen.",
      (ctx) => typeToMenu(ctx, "That fixed it :DD"),
    ),
    heart: variant("Play: `<3` lists the red heart first.", (ctx) => typeToMenu(ctx, "Thanks <3")),
    "arrow-return": variant("Play: ↓ chooses 🧸 on `:tedd`; Return writes it and a space.", async (ctx) => {
      await typeToMenu(ctx, "Ship it :tedd");
      const prompt = ctx.document.querySelector(PROMPT)!;
      await ctx.press("ArrowDown");
      await ctx.waitFor(() => prompt.getAttribute("aria-activedescendant") === "acpmux-emoji-0");
      await ctx.press("Enter");
      await ctx.waitFor(() => ctx.document.querySelector(ROW) === null);
      if (!promptText(ctx).includes("Ship it 🧸")) throw new Error(`pick did not write the emoji: ${promptText(ctx)}`);
    }),
    "return-sends": variant("Play: Return with no row chosen sends; `:tedd` stays text.", async (ctx) => {
      await typeToMenu(ctx, "Ship it :tedd");
      await ctx.press("Enter");
      // fixed-wait: this static snapshot has no host to take the prompt, so the draft stays; the
      // assertion is that Return wrote no emoji over `:tedd` after a beat (a pick would within a frame).
      await new Promise((resolve) => setTimeout(resolve, 200));
      const typed = promptText(ctx);
      if (typed.includes("🧸")) throw new Error(`Return wrote an emoji: ${typed}`);
      if (typed.trim() !== "" && !typed.includes(":tedd")) throw new Error(`Return changed the text: ${typed}`);
    }),
    "emoticon-tab": variant("Play: Tab on `:DD` (no row chosen) writes the first row, 😆.", async (ctx) => {
      await typeToMenu(ctx, "That fixed it :DD");
      await ctx.press("Tab");
      await ctx.waitFor(() => promptText(ctx).includes("😆"));
    }),
    "arrows-escape": variant("Play: ↓ moves the choice, Esc closes the menu and keeps the text.", async (ctx) => {
      await typeToMenu(ctx, "We :sm");
      const prompt = ctx.document.querySelector(PROMPT)!;
      const before = prompt.getAttribute("aria-activedescendant");
      await ctx.press("ArrowDown");
      await ctx.waitFor(() => prompt.getAttribute("aria-activedescendant") !== before);
      await ctx.press("Escape");
      await ctx.waitFor(() => ctx.document.querySelector(ROW) === null);
      if (!promptText(ctx).includes("We :sm")) throw new Error(`Esc changed the text: ${promptText(ctx)}`);
    }),
    "no-trigger": variant("Play: a time (10:30) and a URL open no menu.", async (ctx) => {
      await ctx.focus({ selector: PROMPT });
      await ctx.type("Meet at 10:30 on https://example.com");
      // fixed-wait: a menu that never opens sends no signal; the assertion is that none shows after a beat.
      await new Promise((resolve) => setTimeout(resolve, 200));
      if (ctx.document.querySelector(ROW)) throw new Error("a time or URL opened the emoji menu");
    }),
  },
  experiment: {
    definition: emojiShortcodeLook,
    script: [{ name: "Type :tedd", run: (ctx) => typeToMenu(ctx, "Ship it :tedd") }],
  },
});
