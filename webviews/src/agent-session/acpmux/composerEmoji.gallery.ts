// l10n-allow-file: gallery fixtures (sample prompts), not shipped UI.
// Emoji by shortcode in the prompt (Leo, 2026-11-03: "yo wtf i want this kind of feature in
// cmux-next too", of Claude desktop's `:` popover). `:` and two letters at a word start list emoji
// whose GitHub shortcode matches; a text emoticon lists its face. The first row is always
// highlighted and Return or Tab writes it (Leo, 2026-11-20: "i click enter and it should do it");
// Esc or typing on keeps the text. Compare arms (`emoji-shortcode-look`) for the look; `caret` ships.
import { agentPaneEntry, type AgentPaneVariant } from "../../gallery/format";
import { assistant, chat, summary, user } from "../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../gallery/play";
import { emojiShortcodeLook } from "./emojiShortcodeLook.experiment";
import { COMPOSER_EDITOR } from "./composerSelectors";

const PROMPT = COMPOSER_EDITOR;
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

/** Leo's draft shape: two lines, then `:plead` on the third (it opened no menu before). */
async function typeToLaterLine(ctx: PlayContext) {
  await ctx.focus({ selector: PROMPT });
  await ctx.type("1. perfect it.");
  await ctx.press("Shift+Enter");
  await ctx.type("2. such a nice animation");
  await ctx.press("Shift+Enter");
  await typeToMenu(ctx, ":plead");
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
    tedd: variant(
      "Play: `:tedd` lists the teddy bear first, letters bold, over the typed `:`; the first row highlighted.",
      (ctx) => typeToMenu(ctx, "Ship it :tedd"),
    ),
    pleading: variant(
      "Play: Leo's `:plead` (2026-11-20): 🥺 :pleading_face: first, highlighted as Claude Code draws it.",
      (ctx) => typeToMenu(ctx, "aw :plead"),
    ),
    "emoticon-dd": variant(
      "Play: the emoticon `:DD` lists a laughing face first (Claude desktop offered a middle finger), highlighted.",
      (ctx) => typeToMenu(ctx, "That fixed it :DD"),
    ),
    heart: variant("Play: `<3` lists the red heart first.", (ctx) => typeToMenu(ctx, "Thanks <3")),
    // `:sm` lists several rows (`:tedd` lists one, where ↓ wraps back to it).
    "arrow-return": variant("Play: ↓ chooses the second row on `:sm`; Return writes it and a space.", async (ctx) => {
      await typeToMenu(ctx, "Ship it :sm");
      const prompt = ctx.document.querySelector(PROMPT)!;
      const second = ctx.document.querySelectorAll(`${ROW} .acpmux-emoji-glyph`)[1]?.textContent ?? "";
      await ctx.press("ArrowDown");
      await ctx.waitFor(() => prompt.getAttribute("aria-activedescendant") === "acpmux-emoji-1");
      await ctx.press("Enter");
      await ctx.waitFor(() => ctx.document.querySelector(ROW) === null);
      if (!second || !promptText(ctx).includes(`Ship it ${second}`))
        throw new Error(`pick did not write the second emoji ${second}: ${promptText(ctx)}`);
    }),
    "return-picks": variant("Play: `:plead` then Return writes the highlighted 🥺 and never sends.", async (ctx) => {
      await typeToMenu(ctx, "aw :plead");
      await ctx.press("Enter");
      await ctx.waitFor(() => ctx.document.querySelector(ROW) === null);
      if (!promptText(ctx).includes("aw 🥺")) throw new Error(`Return did not write 🥺: ${promptText(ctx)}`);
    }),
    "emoticon-tab": variant("Play: Tab on `:DD` writes the highlighted first row, 😆.", async (ctx) => {
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
    "escape-retype": variant(
      "Play: Esc on `:smi`, then Backspace and `i` again: the list is back, its first row highlighted.",
      async (ctx) => {
        await typeToMenu(ctx, "Hey :smi");
        await ctx.press("Escape");
        await ctx.waitFor(() => ctx.document.querySelector(ROW) === null);
        // Backspace as the editor takes it (a synthetic key event deletes nothing).
        // eslint-disable-next-line @typescript-eslint/no-deprecated -- the DOM's own edit path for a contenteditable.
        ctx.document.execCommand("delete", false);
        await ctx.waitFor(() => promptText(ctx).endsWith(":sm"));
        await ctx.type("i");
        await ctx.waitFor(() => ctx.document.querySelector(ROW) !== null);
        const prompt = ctx.document.querySelector(PROMPT)!;
        if (prompt.getAttribute("aria-activedescendant") !== "acpmux-emoji-0")
          throw new Error(`no row highlighted after typing back: ${prompt.getAttribute("aria-activedescendant")}`);
      },
    ),
    // Leo, 2026-11-22: "we need to actually improve the ergonomics and lifecycle of that".
    "escape-sticky": variant(
      "Play: Esc on `:smi`, then `l`: the list stays closed for that token; Esc never changes the text.",
      async (ctx) => {
        await typeToMenu(ctx, "Hey :smi");
        await ctx.press("Escape");
        await ctx.waitFor(() => ctx.document.querySelector(ROW) === null);
        await ctx.type("l");
        await ctx.waitFor(() => promptText(ctx).endsWith(":smil"));
        if (ctx.document.querySelector(ROW)) throw new Error("the list came back on the token Esc closed");
      },
    ),
    "caret-away": variant(
      "Play: the caret moved to the line's start closes the list; End brings it back.",
      async (ctx) => {
        await typeToMenu(ctx, "aw :plead");
        await ctx.press("Home");
        await ctx.waitFor(() => ctx.document.querySelector(ROW) === null);
        await ctx.press("End");
        await ctx.waitFor(() => ctx.document.querySelector(ROW) !== null);
      },
    ),
    "focus-away": variant(
      "Play: focus leaving the prompt closes the list; back in it, the list shows again.",
      async (ctx) => {
        await typeToMenu(ctx, "aw :plead");
        (ctx.document.activeElement as HTMLElement | null)?.blur();
        await ctx.waitFor(() => ctx.document.querySelector(ROW) === null);
        await ctx.focus({ selector: PROMPT });
        await ctx.type("i");
        await ctx.waitFor(() => ctx.document.querySelector(ROW) !== null);
      },
    ),
    "type-past": variant("Play: typing on past `:pl` (a space) closes the menu and keeps the text.", async (ctx) => {
      await typeToMenu(ctx, "aw :pl");
      await ctx.type(" ok");
      await ctx.waitFor(() => ctx.document.querySelector(ROW) === null);
      if (!promptText(ctx).includes("aw :pl ok")) throw new Error(`typing on changed the text: ${promptText(ctx)}`);
    }),
    // Leo, 2026-11-22: "for some reason i can't do :pleading_face: with the emoji here": his
    // `:plead` sat on a later line of the draft, where the menu read no caret.
    "later-line": variant("Play: Leo's draft of 2026-11-22: `:plead` on the third line lists 🥺 over it.", (ctx) =>
      typeToLaterLine(ctx),
    ),
    "later-line-return": variant(
      "Play: `:plead` on the third line, then Return writes 🥺 and a space and never sends.",
      async (ctx) => {
        await typeToLaterLine(ctx);
        await ctx.press("Enter");
        await ctx.waitFor(() => ctx.document.querySelector(ROW) === null);
        if (!promptText(ctx).includes("🥺")) throw new Error(`Return on a later line wrote no 🥺: ${promptText(ctx)}`);
      },
    ),
    "closing-colon": variant(
      "Play: typing the closing `:` of `:pleading_face:` writes 🥺 at once, no menu left.",
      async (ctx) => {
        // The list showing first: the table is in (it loads at an idle moment after focus).
        await typeToMenu(ctx, "aw :pleading_face");
        await ctx.type(":");
        await ctx.waitFor(() => promptText(ctx).includes("aw 🥺"));
        if (ctx.document.querySelector(ROW)) throw new Error("the menu stayed after the closing colon");
      },
    ),
    "skin-tone": variant("Play: Slack's `:wave::skin-tone-4:` writes 👋🏽.", async (ctx) => {
      await typeToMenu(ctx, "hi :wav");
      await ctx.type("e::skin-tone-4:");
      await ctx.waitFor(() => promptText(ctx).includes("hi 👋🏽"));
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
