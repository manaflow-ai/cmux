// l10n-allow-file: gallery fixtures, not shipped UI.
// Reconvene item `link-chips`: links pasted into the composer (composer/deeplinkTitles.ts, the chip
// drawn by markdownField.css `.is-titled`). Leo, 2026-11-09: "when I do these links that I copy, the
// caret sort of disappears on it, and then after I paste in another thing, it just becomes
// unformatted again, and I can't, like, sort of, like, return it back to the formatted view of it.
// Although ... doing Enter on it works, but it's just weird that it doesn't have a caret."
// In flight: lane `composer-chip-caret-focus` (657a92b3701, not on this base) keeps a visible caret
// beside the chip, steps the arrows over it and has Backspace/Delete take it whole: the behaviour
// half of `chip-caret` below.
// Spec: leo-workspace design/composer.md "Attachments and pasted text"; design/grid.md 5.5 (inline
// chips are text, not boxes: their metrics follow the type).
// Refs: claude/live/transcript-markdown-rendering (an inline session chip on the line's own size, a
// soft wash, no box), cmux/live/transcript-agent-link-chip-blue-default (Leo: the chip in the app's
// tokens, never a hard-coded blue).
// Every variant draws a draft with two named links, the caret right after the first.
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import type { MarkdownFieldHandle } from "../MarkdownField";
import { arms, showArm, type Arm } from "./arm";

const WORKSPACE_ID = "ws_cca525bafd4d2b969dad8fdb549b0c61";
const WORKSPACE = `cmux-nightly://workspace/${WORKSPACE_ID}`;
const TAB_ID = "tab_0123456789abcdef0123456789abcdef";
const TAB = `cmux-nightly://tab/${TAB_ID}`;
const DRAFT = `Compare ${WORKSPACE} with ${TAB} before the review.`;
/// The caret right after the first link, in the draft's first paragraph.
const AFTER_FIRST = DRAFT.indexOf(WORKSPACE) + WORKSPACE.length;

const snapshot = () =>
  chat([
    user("Where did the retry fix land?", 6),
    assistant("In the Retry fix workspace; its tests run in the zsh tab.", 5),
    summary(5, { status: "completed" }),
  ]);

const CHIP = ".acpmux-md .is-titled[data-title]";

export const ARMS: Record<string, Arm> = arms({
  /// The chip is one atom with the link's characters kept at the line's size, in a zero-width track
  /// at its end: the caret beside it is a full line tall. Backspace selecting it first is behaviour
  /// (the in-flight lane), not drawn here.
  "chip-caret": {
    css: `
${CHIP}[data-icon] {
  display: inline-grid;
  grid-template-columns: auto auto 0;
  align-items: center;
  justify-items: end;
  vertical-align: bottom;
  font-size: inherit;
  line-height: inherit;
  letter-spacing: inherit;
  overflow: clip;
  overflow-clip-margin: 4px;
}
${CHIP}[data-icon]::before,
${CHIP}[data-icon]::after {
  order: -1;
  justify-self: start;
}
${CHIP}[data-icon]::before { vertical-align: 0; }`,
    ready: `${CHIP}[data-icon]`,
  },
  /// No atom: the link stays its text in the link token, and what it names follows in the muted
  /// token. The caret and every edit are plain text's.
  "inline-link": {
    css: `
${CHIP} {
  color: var(--agent-link, var(--agent-accent));
  font-size: inherit;
  line-height: inherit;
  letter-spacing: inherit;
  white-space: normal;
  text-decoration: underline;
  text-decoration-color: color-mix(in srgb, var(--agent-link, var(--agent-accent)) 45%, transparent);
}
${CHIP}[data-icon]::before { content: none; }
${CHIP}::after,
${CHIP}[data-icon]::after {
  content: " " attr(data-title);
  margin: 0;
  padding: 0;
  background: none;
  color: var(--cv-text-muted, var(--agent-muted));
  text-decoration: none;
  display: inline-block;
  white-space: pre;
}`,
    ready: CHIP,
  },
  /// The chip shows its link in place of its title while it is pointed at or edited, on the same
  /// wash, so it never drops to bare text; at rest it is the shipped chip. The still points at the
  /// first chip.
  "chip-edit": {
    css: `
${CHIP}:hover {
  font-size: var(--text-content);
  line-height: var(--text-content--line-height);
  letter-spacing: var(--text-content--letter-spacing, normal);
  color: var(--cv-text, var(--agent-text));
  white-space: normal;
  padding: var(--cmux-link-chip-pad-block) var(--cmux-link-chip-pad-inline);
  border-radius: var(--ds-radius-sm);
  background: color-mix(in srgb, var(--cv-text, var(--agent-text)) 9%, transparent);
  -webkit-box-decoration-break: clone;
  box-decoration-break: clone;
}
${CHIP}:hover::after { content: none; }
${CHIP}[data-icon]:hover::before { margin-inline: 0 var(--ds-space-1, 4px); }`,
    ready: CHIP,
  },
});

/// The app names the draft's workspace and tab (its `linkPlaces` push), so both draw as chips; then
/// the caret goes right after the first.
async function twoChipsCaretAfterFirst(ctx: PlayContext) {
  const doc = ctx.document;
  await ctx.waitFor(() => doc.querySelector(".acpmux-md")?.textContent?.includes(TAB));
  const view = doc.defaultView as unknown as { cmuxAcpmuxBridge?: { applyLinkPlaces?(places: unknown): void } };
  view.cmuxAcpmuxBridge?.applyLinkPlaces?.([
    { id: WORKSPACE_ID, kind: "workspace", title: "Retry fix" },
    { id: TAB_ID, kind: "tab", title: "zsh", workspace: "cmux next" },
  ]);
  await ctx.waitFor(() => doc.querySelectorAll(CHIP).length === 2);
  const field = doc.querySelector(".acpmux-composer-box .acpmux-md-field") as
    | (HTMLElement & { acpmuxMarkdownField?: MarkdownFieldHandle })
    | null;
  field?.acpmuxMarkdownField?.focus();
  field?.acpmuxMarkdownField?.setCaret(AFTER_FIRST);
  await ctx.waitFor(
    () => field?.acpmuxMarkdownField?.caret() === AFTER_FIRST && doc.querySelectorAll(CHIP).length === 2,
  );
}

const variant = (arm: keyof typeof ARMS | "now", note: string): AgentPaneVariant => ({
  note,
  ready: { draft: DRAFT },
  snapshot: snapshot(),
  play: async (ctx) => {
    await twoChipsCaretAfterFirst(ctx);
    await showArm(ctx, arm === "now" ? { css: "" } : ARMS[arm]!);
    if (arm === "chip-edit") await ctx.hover({ selector: CHIP });
  },
});

export default agentPaneEntry({
  id: "agent-pane.reconvene-link-chips",
  title: "Reconvene: pasted links in the composer",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 420, normal: 760 },
  covers: [
    "agent-session/acpmux/composer/deeplinkTitles.ts",
    "agent-session/acpmux/composer/deeplinkTokens.ts",
    "agent-session/acpmux/markdownField.css",
  ],
  keywords: ["reconvene", "link", "chip", "caret", "paste", "deeplink"],
  variants: {
    now: variant(
      "now",
      "Shipped: each named link is a chip (icon and title on a wash) over the link's characters drawn at no size, so the caret right after the first chip has no height and is not seen (Leo's report); a caret inside turns it back to bare text.",
    ),
    "chip-caret": variant(
      "chip-caret",
      "The chip is one atom and the caret beside it is a full line tall; with the in-flight lane, the arrows step over it and Backspace takes it whole. Keeps the chip Leo asked for on 2026-11-08; editing the link means deleting and pasting again.",
    ),
    "inline-link": variant(
      "inline-link",
      "No atom: the link stays text in the link token, its title muted after it. Caret, paste and undo are plain text's and nothing changes form under the caret; a long link takes a line's width.",
    ),
    "chip-edit": variant(
      "chip-edit",
      "The chip shows its link on the same wash while pointed at or edited, and its title again at rest, so it never drops to bare text. The richest; the edit state needs a decoration class that the shipped plugin does not set yet.",
    ),
  },
});
