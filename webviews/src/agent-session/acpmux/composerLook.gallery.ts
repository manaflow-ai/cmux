// l10n-allow-file: gallery fixtures (sample chats and prompts), not shipped UI.
// The composer's two looks (composerLook.ts, composerLook.css; Leo 2026-10-22: "first dot claude,
// second dot codex. since it's just all looks anyways. first 2 dots minimal on the new tab page, and
// then when you're in a chat you can also switch the dots if you hover on that bottom area"). The
// same chat and the same New Tab page in Claude's look (the first dot, the default: the composer as
// it was) and Codex's (the second dot), and the dots on hover in a chat's bottom area. The
// `codex-*-alt-*` variants are the other Codex layouts drawn for the pick (gallery-only CSS over the
// shipped one): the shipped one, `codex-chat`, tucks the folder strip under the box as Codex does.
import { agentPaneEntry } from "../../gallery/format";
import type { PlayContext } from "../../gallery/play";
import { assistant, chat, CWD, manySessions, noChat, user } from "../../gallery/fixtures/acpmux";
import { setComposerLook, type ComposerLook } from "./composerLook";

/// A started Claude Code chat in a project: the transcript over the composer.
const startedChat = () =>
  chat([
    user("Add retries to the fetch helper, with a backoff.", 12),
    assistant(
      "Added `withRetry` to `fetchJson`: three tries with jittered backoff, and only for network errors and 5xx answers. The tests cover a 503 that recovers and a 404 that does not retry.",
      11,
    ),
  ]);

/// A new chat before its first send: the folder and computer strip heads the composer.
const newChat = () => noChat(manySessions(4), { summary: { sessionId: "", cwd: CWD, harness: "codex" } });

const newTab = (fields: Record<string, unknown> = {}) => ({
  newTab: { layout: "b", kind: "agent", cwd: CWD, home: "/Users/you", lastAgent: "claude", ...fields },
  newSession: true,
});

/// The look the variant draws (the choice is the page's, kept in storage, so every variant sets its
/// own), and an alternate layout's gallery-only rules.
const ALT_ID = "composer-look-alt";
async function look(ctx: PlayContext, which: ComposerLook, altCSS?: string) {
  ctx.document.getElementById(ALT_ID)?.remove();
  if (altCSS) {
    const style = ctx.document.createElement("style");
    style.id = ALT_ID;
    style.textContent = altCSS;
    ctx.document.head.append(style);
  }
  // Shown, not remembered: the stage never changes the look of the gallery's other entries.
  setComposerLook(which, { remember: false });
  await ctx.waitFor(() =>
    which === "codex"
      ? ctx.document.querySelector('[data-composer-look="codex"]')
      : !ctx.document.querySelector('[data-composer-look="codex"]'),
  );
}

/// Alternate B: the strip stays plain text over the box, as Claude's look draws it; only the row moves.
const ALT_PLAIN_STRIP = `
.acpmux-composer[data-composer-look="codex"] > .acpmux-composer-strip,
.nt-composer[data-composer-look="codex"] .nt-above .acpmux-composer-strip { all: revert-layer; }`;
/// Alternate C: the tray, and the row's controls as quiet text with no mode glyph (Codex's model text).
const ALT_TEXT_ROW = `
:is(.acpmux-composer, .nt-composer)[data-composer-look="codex"] .acpmux-access .acpmux-icon { display: none; }
:is(.acpmux-composer, .nt-composer)[data-composer-look="codex"] :is(.acpmux-model, .acpmux-effort) .acpmux-picker-button { color: var(--agent-soft); }`;

const chatHeight = 360;

export default agentPaneEntry({
  id: "agent-pane.composer-look",
  title: "Composer looks (Claude, Codex)",
  area: "Agent pane",
  height: chatHeight,
  widths: { narrow: 420, normal: 760, wide: 1100 },
  covers: [
    "agent-session/acpmux/composerLook.ts",
    "agent-session/acpmux/LookSwitch.tsx#LookSwitch",
    "agent-session/acpmux/newtab/PageDots.tsx#PageDots",
    "agent-session/acpmux/newtab/StyleSwitch.tsx#DotSwitch",
  ],
  variants: {
    "claude-chat": {
      note: "The first dot, Claude's look (the default): the composer as it was, the mode, model and effort in the quiet row under the box.",
      snapshot: startedChat(),
      play: (ctx) => look(ctx, "claude"),
    },
    "claude-chat-dots": {
      note: "Claude's look with the pointer in the quiet row's empty middle: the two dots show there, Claude marked.",
      snapshot: startedChat(),
      play: async (ctx) => {
        await look(ctx, "claude");
        await ctx.hover({ selector: ".acpmux-composer-foot" });
      },
    },
    "codex-chat": {
      note: "The second dot, Codex's look (the pick): one row in the box under the prompt, + and the mode left, the context ring, the model and effort, the mic and Send right.",
      snapshot: startedChat(),
      play: (ctx) => look(ctx, "codex"),
    },
    "codex-chat-dots": {
      note: "Codex's look with the pointer in the band under the box (the dead space Codex leaves): the two dots show there, Codex marked.",
      snapshot: startedChat(),
      play: async (ctx) => {
        await look(ctx, "codex");
        await ctx.hover({ selector: ".acpmux-composer-under" });
      },
    },
    "codex-new-chat": {
      note: "Codex's look on a new chat (the pick): the folder and computer strip a tray tucked under the box's top edge, as Codex's.",
      ready: { newSession: true, cwd: CWD },
      snapshot: newChat(),
      play: (ctx) => look(ctx, "codex"),
    },
    "codex-new-chat-alt-plain-strip": {
      note: "Alternate B (not shipped): Codex's row, but the strip stays plain text over the box as in Claude's look.",
      ready: { newSession: true, cwd: CWD },
      snapshot: newChat(),
      play: (ctx) => look(ctx, "codex", ALT_PLAIN_STRIP),
    },
    "codex-new-chat-alt-text-row": {
      note: "Alternate C (not shipped): the tray, and the row as quiet text with no mode glyph.",
      ready: { newSession: true, cwd: CWD },
      snapshot: newChat(),
      play: (ctx) => look(ctx, "codex", ALT_TEXT_ROW),
    },
    "newtab-claude": {
      note: "New Tab, the first dot (Claude Minimal, the default): the Minimal page as it was, with the three dots under it.",
      height: 520,
      ready: newTab(),
      snapshot: noChat(manySessions(6)),
      play: (ctx) => look(ctx, "claude"),
    },
    "newtab-codex": {
      note: "New Tab, the third dot (Codex Minimal): the same page with Codex's composer, the third dot marked.",
      height: 520,
      ready: newTab(),
      snapshot: noChat(manySessions(6)),
      play: (ctx) => look(ctx, "codex"),
    },
    "newtab-classic-codex": {
      note: "Classic New Tab with Codex's look: the page stays Classic (its dot marked among the styles), its box's row in Codex's order, the mode first and the model by Send.",
      height: 520,
      ready: newTab({ template: "classic" }),
      snapshot: noChat(manySessions(4)),
      play: (ctx) => look(ctx, "codex"),
    },
    "newtab-cards-codex": {
      note: "Cards New Tab with Codex's look: the project strip is Codex's tray over the box, the model in the box's row, the chat cards under it.",
      height: 560,
      ready: newTab({ template: "cards" }),
      snapshot: noChat(manySessions(6)),
      play: (ctx) => look(ctx, "codex"),
    },
  },
});
