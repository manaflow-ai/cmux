// l10n-allow-file: gallery fixtures (sample chats and prompts), not shipped UI.
// The composer's trailing glyphs (Send's ↵, Stop's square, the mic), sized and weighted against
// Claude Code desktop's (Leo 2026-11-02: "our icons should be a tiny bit bigger at least our send
// button i think can be nicer lokoing ... compared to claude code"). Three designs on the same chat:
// `current` (the 16 px glyph with a 1.25 line and the old ↵, as before this change), `matched` (the
// trailing glyph tokens at Claude Code's 18 px and 1.5 px line, the old ↵) and `nicer-send` (the pick:
// matched, with ↵ redrawn in Claude Code's proportions). The first two are gallery-only CSS over the
// shipped tokens (composerLocation.css `--acpmux-composer-trail-*`) and glyph (ComposerPickers.tsx).
import { agentPaneEntry } from "../../gallery/format";
import type { PlayContext } from "../../gallery/play";
import { assistant, chat, CWD, manySessions, noChat, user } from "../../gallery/fixtures/acpmux";
import { setComposerLook, type ComposerLook } from "./composerLook";

const startedChat = () =>
  chat([
    user("Add retries to the fetch helper, with a backoff.", 12),
    assistant(
      "Added `withRetry` to `fetchJson`: three tries with jittered backoff, only for network errors and 5xx answers.",
      11,
    ),
  ]);
const runningChat = () => ({ ...startedChat(), isWorking: true });
const DRAFT = { draft: "Also cover the 503 path" };

/// The ↵ before this change, kept here so the gallery can draw the old glyph beside the new one.
const OLD_RETURN = "M12.6 3.6v4.1a1.8 1.8 0 0 1-1.8 1.8H3.6M6.6 6.4 3.4 9.5l3.2 3.1";
const OLD_SIZE = `
html .acpmux-composer { --acpmux-composer-trail-glyph: 16px; --acpmux-composer-trail-stroke: 1.25; }`;
const OLD_GLYPH = `
.acpmux-composer .acpmux-send:not(.acpmux-cancel) > .acpmux-icon > path { d: path("${OLD_RETURN}"); }`;

const ALT_ID = "composer-trailing-glyphs-alt";
async function draw(ctx: PlayContext, which: ComposerLook, altCSS = "") {
  ctx.document.getElementById(ALT_ID)?.remove();
  if (altCSS) {
    const style = ctx.document.createElement("style");
    style.id = ALT_ID;
    style.textContent = altCSS;
    ctx.document.head.append(style);
  }
  setComposerLook(which, { remember: false });
  await ctx.waitFor(() =>
    which === "codex"
      ? ctx.document.querySelector('[data-composer-look="codex"]')
      : !ctx.document.querySelector('[data-composer-look="codex"]'),
  );
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-composer .acpmux-mic"));
}

export default agentPaneEntry({
  id: "agent-pane.composer-trailing-glyphs",
  title: "Composer trailing glyphs (Send, Stop, mic)",
  area: "Agent pane",
  height: 240,
  widths: { narrow: 420, normal: 760 },
  covers: ["agent-session/acpmux/ComposerPickers.tsx#ReturnIcon", "agent-session/acpmux/ComposerPickers.tsx#MicIcon"],
  variants: {
    "current-claude": {
      note: "Before: a 16 px glyph with a 1.25 px line and the old ↵, Claude's look, a typed prompt.",
      snapshot: startedChat(),
      ready: DRAFT,
      play: (ctx) => draw(ctx, "claude", OLD_SIZE + OLD_GLYPH),
    },
    "current-stop": {
      note: "Before: Stop's square while a turn runs, 16 px with a 1.25 px line.",
      snapshot: runningChat(),
      play: (ctx) => draw(ctx, "claude", OLD_SIZE + OLD_GLYPH),
    },
    "matched-claude": {
      note: "Alternate (not shipped): Claude Code's 18 px glyph and 1.5 px line, the old ↵ (narrow bar, small arrowhead).",
      snapshot: startedChat(),
      ready: DRAFT,
      play: (ctx) => draw(ctx, "claude", OLD_GLYPH),
    },
    "nicer-send-claude": {
      note: "The pick: 18 px glyphs with a 1.5 px line, and ↵ in Claude Code's proportions (a wider bar, a fuller arrowhead, a tight corner).",
      snapshot: startedChat(),
      ready: DRAFT,
      play: (ctx) => draw(ctx, "claude"),
    },
    "nicer-send-stop": {
      note: "The pick while a turn runs: Stop's square at the same size and line as the mic.",
      snapshot: runningChat(),
      play: (ctx) => draw(ctx, "claude"),
    },
    "nicer-send-codex": {
      note: "The pick in Codex's look: the same tokens and ↵.",
      snapshot: startedChat(),
      ready: DRAFT,
      play: (ctx) => draw(ctx, "codex"),
    },
    "nicer-send-newtab": {
      note: "The pick on the New Tab page: Send and the mic take the same tokens.",
      height: 520,
      ready: {
        newTab: { layout: "b", kind: "agent", cwd: CWD, home: "/Users/you", lastAgent: "claude" },
        newSession: true,
        ...DRAFT,
      },
      snapshot: noChat(manySessions(4)),
      play: async (ctx) => {
        setComposerLook("claude", { remember: false });
        await ctx.waitFor(() => ctx.document.querySelector(".nt-composer .acpmux-send"));
      },
    },
  },
});
