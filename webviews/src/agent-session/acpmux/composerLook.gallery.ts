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

/// Where the page's dots could sit (Leo 2026-10-23: "the dot switches thing, like it should just be,
/// like in the same kind of spot"), drawn for the pick and not shipped: a still copy of the dots in
/// the composer's row, at its right end before the model or at its left end, or the dots right
/// under the composer wherever it sits. The shipped place is the page's foot, with the composer's
/// room kept over the dots (newtab/screen.css): on the stage page that is right under the composer.
type DotsPlace = "row-end" | "row-start" | "under";
const PLACE_CSS = `
.nt-alt-dots { position: static; display: flex; flex: none; align-items: center; transform: none; }
.nt-alt-dots > .nt-style { position: relative; bottom: auto; left: auto; transform: none; }
.nt-alt-dots .nt-style-option { flex: none; width: 24px; padding: 0; }
.nt-alt-dots[data-at="row-start"] { order: -3; margin-inline-end: 6px; }
.nt-pickers > .nt-alt-dots[data-at="row-start"] { order: 0; }
.nt-alt-dots[data-at="row-end"] { margin-inline-end: 4px; }
.nt-composer[data-composer-look="codex"] .nt-alt-dots[data-at="row-end"] { order: 3; margin-inline-start: auto; }
`;
async function placeDots(ctx: PlayContext, which: ComposerLook, place: DotsPlace) {
  await look(ctx, which, PLACE_CSS);
  const doc = ctx.document;
  await ctx.waitFor(() => doc.querySelector(".nt-page-dots"));
  const dots = doc.querySelector<HTMLElement>(".nt-page-dots")!;
  const composer = doc.querySelector<HTMLElement>(".nt-composer")!;
  if (place === "under") {
    const last = (composer.querySelector(".nt-foot") ?? composer.querySelector(".nt-box"))!.getBoundingClientRect();
    const host = (dots.offsetParent ?? doc.body).getBoundingClientRect();
    dots.style.bottom = `${host.bottom - last.bottom - 2 - 24}px`;
    return;
  }
  const row = (composer.querySelector<HTMLElement>(".acpmux-composer-foot") ?? composer.querySelector(".nt-pickers"))!;
  const copy = dots.cloneNode(true) as HTMLElement;
  copy.className = "nt-alt-dots";
  copy.dataset.at = place;
  copy.inert = true;
  dots.style.visibility = "hidden";
  const model = row.querySelector(".acpmux-model");
  if (place === "row-end" && model instanceof HTMLElement) {
    model.before(copy);
    model.style.marginInlineStart = "0";
  } else row.prepend(copy);
}

/// The stage page (the project card, quick actions and chats on): the composer at the page's foot,
/// where its last row met the dots (Leo 2026-10-23).
const stagePage = () => newTab({ template: "minimal", pageWidgets: ["greeting", "projects", "actions", "chats"] });

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
      note: "Claude's look with the pointer in the quiet row: the two dots show in the band under it, Claude marked, where Codex's look has them too.",
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
      note: "Codex's look with the pointer in the band under the box (the dead space Codex leaves): the two dots show there, Codex marked, on the same line as in Claude's look.",
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
      note: "New Tab, the first dot (Claude's look, the default): the Minimal page as it was, with the two dots under it.",
      height: 520,
      ready: newTab(),
      snapshot: noChat(manySessions(6)),
      play: (ctx) => look(ctx, "claude"),
    },
    "newtab-codex": {
      note: "New Tab, the second dot: the same page with Codex's composer, the second dot marked.",
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
    "newtab-stage-claude": {
      note: "Shipped: Claude's look on the stage page is one row under the box, the folder, the computer and the mode, then the model and effort; nothing over the box. The dots keep their own line at the page's foot, clear of the row.",
      height: 520,
      ready: stagePage(),
      snapshot: noChat(manySessions(6)),
      play: (ctx) => look(ctx, "claude"),
    },
    "newtab-stage-codex": {
      note: "Shipped: Codex's look on the same page. The dots stay on the same line, clear of the box's bottom edge, where Claude's look has them.",
      height: 520,
      ready: stagePage(),
      snapshot: noChat(manySessions(6)),
      play: (ctx) => look(ctx, "codex"),
    },
    "newtab-stage-claude-alt-row-end": {
      note: "Placement A (not shipped): the dots at the right end of Claude's one row, before the model.",
      height: 520,
      ready: stagePage(),
      snapshot: noChat(manySessions(6)),
      play: (ctx) => placeDots(ctx, "claude", "row-end"),
    },
    "newtab-stage-codex-alt-row-end": {
      note: "Placement A (not shipped): the dots in Codex's row inside the box, before the model. A look's pick moves them up or down a row.",
      height: 520,
      ready: stagePage(),
      snapshot: noChat(manySessions(6)),
      play: (ctx) => placeDots(ctx, "codex", "row-end"),
    },
    "newtab-stage-claude-alt-row-start": {
      note: "Placement C (not shipped): the dots at the left end of Claude's one row, before the folder.",
      height: 520,
      ready: stagePage(),
      snapshot: noChat(manySessions(6)),
      play: (ctx) => placeDots(ctx, "claude", "row-start"),
    },
    "newtab-stage-codex-alt-row-start": {
      note: "Placement C (not shipped): the dots at the left end of Codex's row inside the box.",
      height: 520,
      ready: stagePage(),
      snapshot: noChat(manySessions(6)),
      play: (ctx) => placeDots(ctx, "codex", "row-start"),
    },
    "newtab-claude-alt-under": {
      note: "Placement B (not shipped): on the Minimal page, the dots right under the composer, mid-page.",
      height: 520,
      ready: newTab(),
      snapshot: noChat(manySessions(6)),
      play: (ctx) => placeDots(ctx, "claude", "under"),
    },
    "newtab-codex-alt-under": {
      note: "Placement B (not shipped): the same with Codex's look; the composer's height differs, so a look's pick moves the dots.",
      height: 520,
      ready: newTab(),
      snapshot: noChat(manySessions(6)),
      play: (ctx) => placeDots(ctx, "codex", "under"),
    },
  },
});
