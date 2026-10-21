// l10n-allow-file: gallery fixtures (variant notes), not shipped UI.
// The composer's states as gallery variants, one set for each composer (the chat's in
// composer.gallery.ts, the New Tab page's in newtab/NewTabScreen.gallery.ts), so the gallery's
// captures show the two side by side: rest, hover, a menu open, the field focused, a button under
// keyboard focus, and the field focused while the page is not the key one (pageKey.ts).
// test/composer-caret-focus.test.ts asserts the same states.
import type { Play, PlayContext } from "../../gallery/play";

const MODEL = { selector: ".acpmux-model .acpmux-picker-button" };

const blur = (ctx: PlayContext) => (ctx.document.activeElement as HTMLElement | null)?.blur();

/// The page as a background window's: the field keeps DOM focus, the document has none.
function asBackground(ctx: PlayContext) {
  Object.defineProperty(ctx.document, "hasFocus", { configurable: true, value: () => false });
  ctx.document.defaultView?.dispatchEvent(new FocusEvent("blur"));
}

export type ComposerStateName = "rest" | "hover" | "open" | "focus" | "keyboard" | "background";

/// One play per state for the composer whose prompt is `field`.
export function composerStatePlays(field: string): Record<ComposerStateName, { note: string; play: Play }> {
  const ready = (ctx: PlayContext) => ctx.waitFor(() => ctx.document.querySelector(field));
  return {
    rest: {
      note: "At rest: every button is its icon or label, no pill, no fill, no edge; the box draws its resting rim and no caret.",
      play: async (ctx) => {
        await ready(ctx);
        blur(ctx);
      },
    },
    hover: {
      note: "The pointer over the model chip: that chip alone takes the soft pill; the box itself does not change.",
      play: async (ctx) => {
        await ready(ctx);
        blur(ctx);
        await ctx.hover(MODEL);
      },
    },
    open: {
      note: "The model button's menu open (Leo 2026-10-20: one button for the model and its effort): the button holds the soft pill with no ring while the menu shows.",
      play: async (ctx) => {
        await ready(ctx);
        blur(ctx);
        await ctx.click(MODEL);
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-quick-menu [role="menuitemradio"]'));
      },
    },
    focus: {
      note: "The prompt focused in the key window: the caret shows with the focused rim, together.",
      play: async (ctx) => {
        await ready(ctx);
        await ctx.click({ selector: field });
      },
    },
    keyboard: {
      note: "Keyboard focus on the model chip: the soft pill and the bar's outline on the pill's edge.",
      play: async (ctx) => {
        await ready(ctx);
        await ctx.press("Shift");
        await ctx.focus(MODEL);
      },
    },
    background: {
      note: "The prompt holds focus while the window is in the background: no caret and the resting rim, so the two never disagree.",
      play: async (ctx) => {
        await ready(ctx);
        await ctx.click({ selector: field });
        asBackground(ctx);
      },
    },
  };
}
