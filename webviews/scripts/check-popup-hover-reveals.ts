#!/usr/bin/env bun
/**
 * Menu-capable hover controls stay visible while their popup is open.
 *
 * A row owns a hidden action strip while each popup opener owns the `data-popup-open` marker (the
 * shared Menu and ContextMenu triggers both set it). The pointer can leave the row for the popup,
 * so a `:hover` reveal without a matching `:has([data-popup-open])` selector hides the trigger
 * before the menu can be used. This checker scans every webview stylesheet and only exempts
 * controls that are documented as non-popup reveals (keyboard hints, status text, and similar
 * affordances).
 */

import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";

export type HoverRevealViolation = {
  line: number;
  selector: string;
  expected: string;
  file?: string;
};

type Rule = { selector: string; body: string; line: number; context: string };

// These reveal a visual affordance, not a control that can own a popup. Keep each exemption
// exact and named so a new row/action cannot silently skip the popup contract.
const NON_POPUP_REVEALS = new Map<string, string>([
  ["agent-session/acpmux/conversation/conversation.css|.cv-table-block:hover .cv-table-tools", "table tools"],
  ["agent-session/acpmux/conversation/conversation.css|.cv-worked:hover .cv-command__bg", "command status"],
  ["agent-session/acpmux/conversation/conversation.css|.cv-activity:hover .cv-command__bg", "command status"],
  [
    "agent-session/acpmux/conversation/conversation.css|:is(.cv-worked, .cv-activity):hover .cv-command__bg",
    "command status",
  ],
  ["agent-session/acpmux/conversation/conversation.css|.cv-message:hover .cv-sent-actions", "copy affordance"],
  ["agent-session/acpmux/conversation/conversation.css|.cv-sent:hover .cv-sent-actions", "copy affordance"],
  ["agent-session/acpmux/conversation/CardCopy.css|.cv-disclosure__panel:hover > .cv-card-copy", "copy affordance"],
  [
    "agent-session/acpmux/conversation/conversation.css|.cv-tool-output__box:hover .cv-tool-output__actions",
    "copy affordance",
  ],
  ["agent-session/acpmux/conversation/conversation.css|.cv-received:hover .cv-received__reply", "reply affordance"],
  // Only the strip's own menu keeps it shown (.cv-received-actions:has([aria-haspopup="menu"][data-popup-open]),
  // #27064); another popup in the row does not (message-actions-menu-reveal.test.ts).
  ["agent-session/acpmux/conversation/conversation.css|.cv-received:hover .cv-received-actions", "own-menu rule"],
  ["agent-session/acpmux/styles.css|.acpmux-file-header:hover .acpmux-fh-chevron", "disclosure chevron"],
  // The ⋯ keeps itself shown while its menu is open (.acpmux-session-info-pr__more:is([data-popup-open], …)).
  [
    "agent-session/acpmux/session-info/sessionInfo.css|.acpmux-session-info-pr:is(:hover, :focus-within) .acpmux-session-info-pr__more",
    "own-menu rule",
  ],
  // A grant's Revoke is a plain button that revokes on click (EnvironmentSection.tsx); it opens no menu.
  [
    "agent-session/acpmux/session-info/sessionInfo.css|.acpmux-session-info-row--grant:is(:hover, :focus-within) > .acpmux-session-info-link",
    "revoke affordance",
  ],
  // A running subagent's Stop (SubagentGroup.tsx StopButton) stops it on the click; it opens no menu.
  [
    "agent-session/acpmux/subagents/subagents.css|.cv-subagent-stoppable:is(:hover, :focus-within) > .cv-subagent__stop",
    "stop button",
  ],
  [
    "agent-session/acpmux/subagents/subagents.css|.cv-subagent-stoppable:is(:hover, :focus-within) > .cv-subagent__stop:disabled",
    "stop button",
  ],
  // A Shell block's Wrap lines is a pressed toggle (BlockParts.tsx WrapButton); it opens no menu.
  ["agent-session/acpmux/conversation/conversation.css|.cv-shell:hover .cv-shell__wrap", "wrap toggle"],
  // The model star is a pressed toggle (QuickModelMenu.tsx); it opens no menu.
  [
    "agent-session/acpmux/modelPicker.css|.acpmux-quick-model-effort:is(:hover, :has([data-highlighted])) .acpmux-quick-star",
    "favourite toggle",
  ],
  // Suggestion rows sit in .nt-popover, which the New Tab page's ContextMenu ignores: no menu opens from them.
  ["agent-session/acpmux/newtab/screen.css|.nt-row:hover .nt-row-action", "suggestion row hint"],
  [
    "agent-session/acpmux/styles.css|.acpmux-permission-ask .acpmux-permission-buttons button:hover .acpmux-permission-action-shortcut",
    "keyboard shortcut",
  ],
  [
    "agent-session/acpmux/composerAttachments.css|.acpmux-attachment:hover .acpmux-attachment-remove",
    "remove affordance",
  ],
  // An inline attachment chip's ×, Retry and Expand are plain buttons (composer/inlineAttachments.tsx).
  ["agent-session/acpmux/markdownField.css|.acpmux-md-inline-chip:hover .acpmux-md-inline-remove", "remove affordance"],
  [
    "agent-session/acpmux/composerLook.css|.acpmux-composer:has(.acpmux-composer-foot:hover) .acpmux-look-dots",
    "look affordance",
  ],
  ["agent-session/acpmux/composerLook.css|.acpmux-composer-under:hover .acpmux-look-dots", "look affordance"],
  ["pages/changelog/updateSurfaces.css|.wn-card:is(:hover, :focus-within) .wn-card-close", "close affordance"],
  [
    "agent-session/acpmux/needsYou/needsYou.css|.acpmux-needs-you-item:is(:hover, :focus-within) .acpmux-needs-you-tools",
    "needs-you actions",
  ],
  [
    "agent-session/acpmux/conversation/conversation.css|.cv-tool:is(:hover, :focus-visible) :is(.cv-command__ok, .cv-command__time)",
    "command status",
  ],
  [
    "agent-session/acpmux/conversation/AgentMessageRow.css|.cv-agentmsg__line:is(:hover, :focus-within) .cv-command__ok",
    "command status",
  ],
  ["agent-session/acpmux/newtab/screen.css|.nt-all-row:hover .nt-all-glyph", "state glyph"],
  ["agent-session/acpmux/changes/changes.css|.acpmux-file-header:hover .acpmux-fh-chevron", "disclosure chevron"],
  ["agent-session/acpmux/chips/chips.css|.cv-media:hover .cv-media__actions", "media controls"],
  [
    "agent-session/acpmux/subagents/subagents.css|.cv-subagent-done-row:hover .cv-subagent-done__actions",
    "copy affordance",
  ],
  ["agent-session/acpmux/prototype/prototype.css|.proto-tab:hover .proto-tab-close", "close affordance"],
  ["pages/settings/styles.css|.backdrop-pending:hover .backdrop-thumb", "pending wallpaper brightness"],
  ["pages/settings/styles.css|.backdrop-own:hover .backdrop-remove:not(:disabled)", "remove affordance"],
  ["gallery/fixtures/VisualMediaBoard.css|.cmux-gallery-media-stage:hover img", "gallery preview brightness"],
  [
    "gallery/fixtures/VisualMediaBoard.css|.cmux-gallery-media-stage:hover .cmux-gallery-media-stage-hint",
    "gallery preview hint",
  ],
  ["pages/keybindings/styles.css|.keys-row:hover .keys-icon-button", "keybinding controls"],
  ["pages/changelog/styles.css|.cl-group li:hover .cl-row-actions", "release links"],
  ["pages/changelog/styles.css|.cln-fixed li:hover .cl-row-actions", "release links"],
  ["pages/home-channels/styles.css|.hc-msg:hover .hc-msg-hover-time", "message timestamp"],
  ["pages/home-channels/ledger.css|.hc-att-file:hover .hc-att-download", "download affordance"],
  ["pages/home-channels/ledger.css|.hc-att-video:hover .hc-att-download", "download affordance"],
  ["pages/home-channels/ledger.css|.hc-tray-item:hover .hc-tray-remove", "remove affordance"],
  ["styles.css|.comment-card:hover .comment-card-actions", "comment affordance"],
  ["optchat-inspector/styles.css|.term:hover .tip", "inspector tooltip"],
  ["agent-session/acpmux/styles.css|.acpmux-omni-row:hover .acpmux-omni-action", "new-tab affordance"],
  [
    "agent-session/acpmux/session-info/sessionInfo.css|.acpmux-session-info-section:hover > .acpmux-session-info-section__handle",
    "drag handle",
  ],
  [
    "agent-session/acpmux/subagents/DisclosureRow.css|.cv-disclosure__line:hover .cv-disclosure__open",
    "open affordance",
  ],
]);

function withoutComments(source: string): string {
  return source.replace(/\/\*[^]*?\*\//g, (comment) => comment.replace(/[^\n]/g, " "));
}

function matchingBrace(source: string, open: number): number {
  let depth = 1;
  for (let index = open + 1; index < source.length; index += 1) {
    if (source[index] === "{") depth += 1;
    else if (source[index] === "}" && --depth === 0) return index;
  }
  return source.length;
}

function parseRules(source: string, start = 0, end = source.length, context = ""): Rule[] {
  const rules: Rule[] = [];
  let cursor = start;
  while (cursor < end) {
    const open = source.indexOf("{", cursor);
    if (open < 0 || open >= end) break;
    const close = Math.min(matchingBrace(source, open), end - 1);
    const prelude = source.slice(cursor, open).trim();
    if (prelude.startsWith("@")) rules.push(...parseRules(source, open + 1, close, `${context}${prelude};`));
    else if (prelude)
      rules.push({
        selector: prelude,
        body: source.slice(open + 1, close),
        line: source.slice(0, cursor).split("\n").length,
        context,
      });
    cursor = close + 1;
  }
  return rules;
}

function splitSelectorList(selector: string): string[] {
  const parts: string[] = [];
  let depth = 0;
  let start = 0;
  for (let index = 0; index < selector.length; index += 1) {
    const char = selector[index];
    if (char === "(") depth += 1;
    else if (char === ")") depth = Math.max(0, depth - 1);
    else if (char === "," && depth === 0) {
      parts.push(selector.slice(start, index).trim());
      start = index + 1;
    }
  }
  parts.push(selector.slice(start).trim());
  return parts.filter(Boolean);
}

function normalized(selector: string): string {
  return selector.replace(/\s+/g, " ").trim();
}

function revealDeclarations(body: string): Set<string> {
  const declarations = new Set<string>();
  for (const match of body.matchAll(/(?:^|[;\s])(opacity|visibility|display)\s*:\s*([^;}]*)/g)) {
    const property = match[1];
    const value = match[2]?.trim().replace(/\s*!important\s*$/i, "");
    if (!property || !value) continue;
    const opacity = property === "opacity" && /^(?:\d*\.)?\d+$/.test(value) && Number(value) > 0;
    if (
      opacity ||
      (property === "visibility" && value === "visible") ||
      (property === "display" && /^(?:block|flex|inline(?:-flex)?|grid)$/.test(value))
    )
      declarations.add(`${property}:${value}`);
  }
  return declarations;
}

function cssRules(source: string): Rule[] {
  return parseRules(withoutComments(source));
}

/** Returns every hover reveal that has no matching popup-open reveal. */
export function findHoverRevealViolations(source: string, file = ""): HoverRevealViolation[] {
  const rules = cssRules(source);
  const all = rules.flatMap((rule) =>
    splitSelectorList(rule.selector).map((selector) => `${rule.context}|${normalized(selector)}`),
  );
  const revealed = new Map<string, Set<string>>();
  for (const rule of rules) {
    const declarations = revealDeclarations(rule.body);
    if (declarations.size === 0) continue;
    for (const selector of splitSelectorList(rule.selector))
      revealed.set(`${rule.context}|${normalized(selector)}`, declarations);
  }

  const violations: HoverRevealViolation[] = [];
  for (const rule of rules) {
    const declarations = revealDeclarations(rule.body);
    if (declarations.size === 0) continue;
    for (const selector of splitSelectorList(rule.selector)) {
      // A reveal is a :hover with a descendant or sibling somewhere after it. The search is not
      // anchored, so a nested :is(:hover, :focus-within) .actions counts too (its test covers it).
      const hoverIndex = selector.indexOf(":hover");
      if (hoverIndex < 0 || !/\s+(?:[>+~]\s*)?\S/.test(selector.slice(hoverIndex + ":hover".length))) continue;
      const normalizedSelector = normalized(selector);
      if (NON_POPUP_REVEALS.has(`${file}|${normalizedSelector}`)) continue;
      const expected = normalized(selector.replace(/:hover\b/g, ":has([data-popup-open])"));
      const popupDeclarations = revealed.get(`${rule.context}|${expected}`);
      if (
        !all.includes(`${rule.context}|${expected}`) ||
        !popupDeclarations ||
        [...declarations].some((declaration) => !popupDeclarations.has(declaration))
      )
        violations.push({ line: rule.line, selector: normalizedSelector, expected, file });
    }
  }
  return violations;
}

function cssFiles(root: string): string[] {
  const files: string[] = [];
  const visit = (directory: string) => {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const full = path.join(directory, entry.name);
      if (entry.isDirectory()) visit(full);
      else if (entry.name.endsWith(".css")) files.push(full);
    }
  };
  visit(root);
  return files;
}

export function main(): number {
  const sourceRoot = path.resolve(import.meta.dir, "../src");
  const violations = cssFiles(sourceRoot).flatMap((file) => {
    const relative = path.relative(sourceRoot, file);
    return findHoverRevealViolations(readFileSync(file, "utf8"), relative).map((violation) => ({
      ...violation,
      file: relative,
    }));
  });
  if (violations.length === 0) {
    console.log("popup hover reveals: all reveals keep their controls open");
    return 0;
  }
  for (const violation of violations)
    console.error(`${violation.file}:${violation.line}: ${violation.selector} must also match ${violation.expected}`);
  return 1;
}

if (import.meta.main) process.exit(main());
