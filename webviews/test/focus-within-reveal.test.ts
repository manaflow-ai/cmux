// l10n-allow-file: test diagnostics.
// Hover-revealed controls never stay shown by `:focus-within`. A page in the app keeps DOM focus
// when another pane or app takes the keyboard (src/agent-session/acpmux/pageKey.ts), and a click
// leaves focus on what it pressed, so a reveal held by `:focus-within` stays drawn after the person
// has gone elsewhere (Leo, 2026-11-12, on a queued prompt's Steer, trash and ⋯: "if i click into
// the app or click into you for the workspace like focus anything the composer just the window the
// pane it should fade away"). The keyboard's reach is `:has(:focus-visible)` instead: the build
// gates every `:focus-visible` on a key having earned it (FOCUS-RING, src/ui/focusModality.ts), and
// the window's blur, a press or a scroll takes it away.
//
// Detector: every style rule whose selector holds `:focus-within` and whose block sets `opacity: 1`
// or `visibility: visible` is listed; ALLOWED names the ones that reveal on purpose, with why.
import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";

const webviews = path.resolve(import.meta.dir, "..");

/** Rules that show a control on focus by design, and why a stale focus there is right. */
const ALLOWED: Record<string, string> = {
  // A chief card is picked by focusing it (a click or a key); its actions are the picked card's.
  ".acpmux-chief-card:focus-within .acpmux-chief-card-actions": "the focused card is the picked one",
  ".acpmux-chief-card:focus-within .acpmux-chief-card-dismiss": "the focused card is the picked one",
};

/** Reveals made before this detector, each to move to `:has(:focus-visible)` (or into ALLOWED with
 * its reason); the list only shrinks. */
const KNOWN = new Set([
  "src/agent-session/acpmux/TaskGoalStrip.css: .acpmux-goal[data-look]:is(:focus-within, [data-open]) .acpmux-goal-actions",
  "src/agent-session/acpmux/chips/chips.css: .cv-media__actions:focus-within",
  "src/agent-session/acpmux/composerAttachments.css: .acpmux-attachment:focus-within .acpmux-attachment-remove",
  "src/agent-session/acpmux/composerLook.css: .acpmux-look-dots:focus-within",
  "src/agent-session/acpmux/conversation/AgentMessageRow.css: .cv-agentmsg__line:is(:hover, :focus-within) .cv-command__ok",
  "src/agent-session/acpmux/conversation/AgentMessageRow.css: .cv-sent-msg.look-hover .cv-agentmsg__open:focus-within .cv-sent__raw > .cv-received__more",
  "src/agent-session/acpmux/conversation/CardCopy.css: .cv-card-copy:focus-within",
  "src/agent-session/acpmux/conversation/conversation.css: .cv-user__actions:focus-within",
  "src/agent-session/acpmux/conversation/conversation.css: .cv-received-actions:focus-within",
  "src/agent-session/acpmux/conversation/conversation.css: .cv-table-tools:focus-within",
  "src/agent-session/acpmux/conversation/conversation.css: .cv-codeblock--corner:focus-within .cv-codeblock__header",
  'src/agent-session/acpmux/conversation/conversation.css: :root[data-code-actions="block-hover"] .cv-codeblock:focus-within .cv-codeblock__actions',
  'src/agent-session/acpmux/conversation/conversation.css: :root[data-code-actions="block-hover"] .cv-edit-diff:focus-within .cv-edit-diff__header > .cv-iconbtn',
  'src/agent-session/acpmux/conversation/conversation.css: :root[data-code-actions="block-hover"] .cv-shell:focus-within .cv-shell__actions',
  "src/agent-session/acpmux/conversation/conversation.css: .cv-shell:focus-within .cv-shell__wrap",
  'src/agent-session/acpmux/conversation/conversation.css: :is(.cv-steps > .cv-step, .cv-steps > .cv-step > .cv-tool-with-visual) > .cv-tool:is(:focus-within, [aria-expanded="true"], [data-popup-open], :has([aria-expanded="true"])) > .cv-tool__chevron',
  "src/agent-session/acpmux/conversation/conversation.css: .cv-sent-actions:focus-within",
  "src/agent-session/acpmux/conversation/conversation.css: .cv-received__hover:focus-within",
  "src/agent-session/acpmux/conversation/conversation.css: .cv-tool-output__actions:focus-within",
  "src/agent-session/acpmux/conversation/conversation.css: .acpmux-turnSummary .cv-turn-actions:focus-within",
  "src/agent-session/acpmux/conversation/conversation.css: .acpmux-turnSummary .cv-turn-actions:focus-within .cv-turn-time",
  "src/agent-session/acpmux/conversation/conversation.css: .cv-reply-actions:focus-within .cv-turn-time",
  "src/agent-session/acpmux/conversation/conversation.css: .cv-reply-actions:focus-within",
  "src/agent-session/acpmux/conversation/conversation.css: .cv-user__pending:focus-within .cv-user__queued-hover",
  "src/agent-session/acpmux/conversation/conversation.css: .cv-received:focus-within .cv-received__reply",
  "src/agent-session/acpmux/markdownField.css: .acpmux-md-inline-chip:focus-within .acpmux-md-inline-remove",
  "src/agent-session/acpmux/needsYou/needsYou.css: .acpmux-needs-you-item:is(:hover, :focus-within) .acpmux-needs-you-tools",
  "src/agent-session/acpmux/prototype/prototype.css: .proto-tab:focus-within .proto-tab-close",
  "src/agent-session/acpmux/session-info/sessionInfo.css: .acpmux-session-info-pr:is(:hover, :focus-within) .acpmux-session-info-pr__more",
  "src/agent-session/acpmux/session-info/sessionInfo.css: .acpmux-session-info-source:is(:hover, :focus-within) .acpmux-session-info-source__more",
  "src/agent-session/acpmux/session-info/sessionInfo.css: .acpmux-session-info-source:is(:has([data-popup-open]), :focus-within) .acpmux-session-info-source__more",
  "src/agent-session/acpmux/session-info/sessionInfo.css: .acpmux-session-info-task--command:is(:hover, :focus-within) > .acpmux-session-info-stop",
  "src/agent-session/acpmux/session-info/sessionInfo.css: .acpmux-session-info-task--command:is(:has([data-popup-open]), :focus-within) > .acpmux-session-info-stop",
  "src/agent-session/acpmux/subagents/subagents.css: .cv-subagent-stoppable:is(:hover, :focus-within) > .cv-subagent__stop",
  "src/agent-session/acpmux/subagents/subagents.css: .cv-subagent-done__actions:focus-within",
  "src/pages/home-channels/styles.css: .hc-msg:focus-within .hc-msg-hover-time",
  "src/pages/keybindings/styles.css: .keys-row:focus-within .keys-icon-button",
  "src/pages/machines/styles.css: .machines-row:focus-within .machines-action",
  "src/pages/settings/layout.css: .channel-build:focus-within .channel-switch",
  "src/pages/settings/styles.css: .menu-row:focus-within .menu-row-actions",
  "src/styles.css: .comment-card:focus-within .comment-card-actions",
  'src/ui/dismiss.css: [data-dismiss-host]:is(:hover, :focus-within) .ui-dismiss[data-reveal="hover"]',
  'src/ui/dismiss.css: [data-dismiss-host]:is(:has([data-popup-open]), :focus-within) .ui-dismiss[data-reveal="hover"]',
  "src/ui/motion/motion.css: .ui-reveal-host:focus-within .ui-reveal",
]);

/// The selectors of a rule's prelude, split at its top-level commas (not those inside `:is(...)`).
function selectors(prelude: string): string[] {
  const parts: string[] = [];
  let depth = 0;
  let start = 0;
  for (let at = 0; at < prelude.length; at += 1) {
    const char = prelude[at];
    if (char === "(") depth += 1;
    else if (char === ")") depth -= 1;
    else if (char === "," && depth === 0) {
      parts.push(prelude.slice(start, at));
      start = at + 1;
    }
  }
  parts.push(prelude.slice(start));
  return parts.map((part) => part.trim().replace(/\s+/g, " ")).filter(Boolean);
}

/// Each selector that reveals by `:focus-within`, from the innermost blocks of `css`.
export function focusWithinReveals(css: string): string[] {
  const source = css.replace(/\/\*[\s\S]*?\*\//g, "");
  const found: string[] = [];
  for (const [, prelude, body] of source.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    if (!/opacity\s*:\s*1(?![\d.])|visibility\s*:\s*visible/.test(body!)) continue;
    for (const selector of selectors(prelude!)) if (selector.includes(":focus-within")) found.push(selector);
  }
  return found;
}

test("the scanner finds a reveal held by :focus-within and leaves the keyboard's form alone", () => {
  expect(focusWithinReveals(".row:is(:hover, :focus-within) .act { opacity: 1; }")).toEqual([
    ".row:is(:hover, :focus-within) .act",
  ]);
  expect(focusWithinReveals(".row:focus-within .pr { visibility: visible; }")).toEqual([".row:focus-within .pr"]);
  expect(focusWithinReveals(".row:is(:hover, :has(:focus-visible)) .act { opacity: 1; }")).toEqual([]);
  // A focus rim or a partial fade is no reveal.
  expect(focusWithinReveals(".box:focus-within { border-color: red; opacity: 0.6; }")).toEqual([]);
  expect(focusWithinReveals("/* .a:focus-within { opacity: 1 } */")).toEqual([]);
});

test("no webview stylesheet keeps a hover-revealed control shown by :focus-within", () => {
  const files = execFileSync("git", ["ls-files", "src/**/*.css", "src/*.css"], { cwd: webviews, encoding: "utf8" })
    .split("\n")
    .filter((file) => file && !file.includes(".gallery."));
  expect(files).toContain("src/agent-session/acpmux/styles.css");
  const found = files.flatMap((file) =>
    focusWithinReveals(readFileSync(path.join(webviews, file), "utf8"))
      .filter((selector) => !(selector in ALLOWED))
      .map((selector) => `${file}: ${selector}`),
  );
  expect(found.filter((entry) => !KNOWN.has(entry))).toEqual([]);
  // A fixed one leaves KNOWN too, so the list never holds a reveal that is gone.
  expect([...KNOWN].filter((entry) => !found.includes(entry))).toEqual([]);
});
