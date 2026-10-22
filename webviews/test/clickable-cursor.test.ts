// Everything clickable shows the pointing hand (Leo 2026-10-21: "links when i hover them in the chat
// esp the pr things i need to have the cursor switch to the clickable look"; "STOP BUTTON, I HOVER
// OVER IT, MY CURSOR SHOULD ALSO SEE IT AS CLICKABLE.. LOTS OF AREAS LIKE THAT SHOULD BE CHANGING MY
// CURSOR INDICATOR TO CLICKABLE"). desktop.css, the first layer of every first-party page, gives a
// clickable element and everything in it `cursor: pointer`, and a disabled one the arrow, at zero
// specificity. Before, desktop.css gave buttons and links the arrow (R139), surfaces repeated it
// (the pull request bars over the composer, the composer's Stop and Mic, menu rows, the needs-you
// link), and `.selectable *` put `auto` on a button chip's label.
//
// 1. The agent pane's own stylesheet, in build-agent-pane-web.sh's order, cascaded by jsdom over the
//    pane's clickable things: each computes `pointer`, its label and icon too, and a disabled one
//    `default`. Text that is not a link keeps the I-beam.
// 2. No rule in any webview stylesheet sets `cursor: default` or `auto` on a clickable element: a
//    button, a link, a summary, a select, a clickable role, or a class the sources put on one.
//    Disabled states may.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { Glob } from "bun";
import { JSDOM } from "jsdom";

const repo = join(import.meta.dir, "../..");
const src = join(repo, "webviews/src");

/// The sheets the bundled pane's <style> is written from, in order (build-agent-pane-web.sh).
function paneSheets(): string[] {
  const script = readFileSync(join(repo, "scripts/cmux-next/build-agent-pane-web.sh"), "utf8");
  const paths = [...script.matchAll(/"\$(SRC|ROOT)\/([^"$]+\.css)"/g)].map(([, base, path]) =>
    base === "SRC" ? join(src, "agent-session", path) : join(repo, path),
  );
  return [...new Set(paths)];
}

const PANE = `
<div class="acpmux-shell">
  <div class="cv-md selectable">
    <p data-expect="auto">Reply text, and a file named <span class="cv-link is-file" data-expect="auto">notes.md</span>.</p>
    <a data-expect="pointer" data-name="pull request chip" class="cv-link cv-chip is-web is-ref" href="https://github.com/manaflow-ai/cmux/pull/1"><svg data-expect="pointer" data-name="chip icon" class="cv-chip__icon"></svg><span data-expect="pointer" data-name="chip label" class="cv-chip__label">manaflow-ai/cmux#1</span><span class="cv-chip__title">Title</span></a>
    <a data-expect="pointer" data-name="web link" class="cv-link cv-chip is-web" href="https://example.com"><span class="cv-chip__label">example.com</span></a>
    <button data-expect="pointer" data-name="path chip" type="button" class="cv-chip is-path"><span data-expect="pointer" data-name="path chip label" class="cv-chip__label">App.tsx</span></button>
    <a data-expect="pointer" data-name="app link" class="cv-link is-app" href="cmux://open">open</a>
    <button data-expect="pointer" data-name="needs-you link" type="button" class="cv-link is-needs-you"><span class="acpmux-needs-you-dot"></span>Needs you</button>
    <button data-expect="pointer" data-name="started chat chip" type="button" class="acpmux-started-chip">a chat</button>
    <sup class="cv-fnref"><button data-expect="pointer" data-name="footnote mark" type="button">1</button></sup>
  </div>
  <button data-expect="pointer" data-name="tool row" type="button" class="cv-tool is-toggle">Ran a command</button>
  <div class="cv-tools">
    <button data-expect="pointer" data-name="Subagent finished row" type="button" class="cv-tool cv-bgtask cv-subagent-done" data-state="completed"><span class="cv-tool__icon"><svg data-expect="pointer" data-name="Subagent finished icon"></svg></span><span data-expect="pointer" data-name="Subagent finished text" class="cv-tool__text">Subagent finished: Fix merge hook · 49m 38s</span></button>
    <button data-expect="default" data-name="Subagent finished row, nothing to open" type="button" class="cv-tool cv-bgtask cv-subagent-done" disabled>Subagent finished</button>
  </div>
  <button data-expect="pointer" data-name="started chat row" type="button" class="acpmux-started-row">A chat</button>
  <div class="ui-glass cv-link-preview acpmux-pr-card"><button data-expect="pointer" data-name="hover card Open" type="button" class="cv-link-preview__open">Open</button></div>
  <a data-expect="pointer" data-name="inspector pull request" class="acpmux-chat-inspector-pr__link" href="https://github.com/o/r/pull/3">PR</a>
  <a data-expect="pointer" data-name="summary link" class="acpmux-summary-row acpmux-summary-link" href="https://example.com/doc">Doc</a>
  <section class="acpmux-pr-dock">
    <div class="acpmux-pr-dock__chip">
      <a data-expect="pointer" data-name="pull request bar" class="acpmux-pr-dock__bar" href="https://github.com/o/r/pull/2"><span data-expect="pointer" data-name="pull request bar number" class="acpmux-pr-dock__number">#2</span></a>
      <button data-expect="pointer" data-name="pull request bar dismiss" type="button" class="cv-iconbtn cv-iconbtn--compact acpmux-pr-dock__dismiss"></button>
    </div>
    <button data-expect="pointer" data-name="pull request dock more" type="button" class="acpmux-pr-dock__more">2 more</button>
  </section>
  <form class="acpmux-composer"><div class="acpmux-composer-box">
    <button data-expect="pointer" data-name="composer Stop" type="button" class="acpmux-send acpmux-cancel"><svg data-expect="pointer" data-name="Stop icon"></svg></button>
    <button data-expect="pointer" data-name="composer Mic" type="button" class="acpmux-mic"></button>
    <button data-expect="pointer" data-name="composer Send" type="button" class="acpmux-send acpmux-send-ready"></button>
    <button data-expect="default" data-name="composer Send, disabled" type="button" class="acpmux-send" disabled></button>
    <button data-expect="pointer" data-name="composer plan chip" type="button" class="acpmux-plan">Plan</button>
  </div></form>
  <div class="ui-context-menu">
    <div data-expect="pointer" data-name="menu row" role="menuitem" class="ui-menu-item">Copy</div>
    <div data-expect="default" data-name="menu row, disabled" role="menuitem" aria-disabled="true" class="ui-menu-item">Paste</div>
  </div>
  <div data-expect="pointer" data-name="slash command row" role="option" class="acpmux-slash-row">/review</div>
</div>`;

test("every clickable thing in the agent pane shows the pointing hand, a disabled one the arrow", () => {
  const css = paneSheets()
    .map((path) => readFileSync(path, "utf8").replace(/^@import .*$/gm, ""))
    .join("\n");
  const dom = new JSDOM(`<!doctype html><html><head></head><body>${PANE}</body></html>`);
  const { document } = dom.window;
  const style = document.createElement("style");
  style.textContent = css;
  document.head.append(style);
  const checked = [...document.querySelectorAll<HTMLElement>("[data-expect]")];
  expect(checked.length).toBeGreaterThan(20);
  const cursors = Object.fromEntries(
    checked.map((element, index) => [
      element.dataset.name ?? `${element.tagName.toLowerCase()} #${index}`,
      dom.window.getComputedStyle(element).cursor,
    ]),
  );
  const expected = Object.fromEntries(
    checked.map((element, index) => [
      element.dataset.name ?? `${element.tagName.toLowerCase()} #${index}`,
      element.dataset.expect ?? "",
    ]),
  );
  expect(cursors).toEqual(expected);
});

// ---- 2. No surface turns a clickable element back to the arrow ----

const CLICKABLE_TAGS = new Set(["button", "a", "summary", "select"]);
const CLICKABLE_ROLES = new Set([
  "button",
  "link",
  "menuitem",
  "menuitemcheckbox",
  "menuitemradio",
  "tab",
  "option",
  "switch",
  "checkbox",
  "radio",
]);
/// Components that render a clickable element (Base UI's menu items and triggers, our buttons).
const CLICKABLE_COMPONENT = /(Button|MenuItem|Item|Trigger|Tab|Link|Toggle|Checkbox|Switch|Radio|Option|Summary)$/;

/// Every class the sources put on a clickable element (a <button>, a link, a clickable role, or a
/// component that renders one), read from each `className` with the element it sits on.
function clickableClasses(): Set<string> {
  const classes = new Set<string>();
  for (const file of new Glob("**/*.{ts,tsx}").scanSync(src)) {
    if (/\.test\.tsx?$/.test(file)) continue;
    const text = readFileSync(join(src, file), "utf8");
    // A literal, a template, or an expression (`cx("ui-menu-item", …)`), whose string parts count.
    for (const match of text.matchAll(/className=(?:"([^"]*)"|\{`([^`]*)`\}|\{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\})/g)) {
      const value =
        match[1] ??
        match[2] ??
        [...(match[3] ?? "").matchAll(/"([^"]*)"|'([^']*)'|`([^`]*)`/g)]
          .map((part) => part.slice(1).join(" "))
          .join(" ");
      const before = text.slice(Math.max(0, match.index! - 1500), match.index!);
      const open = [...before.matchAll(/(?:^|[\s(>{,=?:&|])<([A-Za-z][\w.]*)/g)].at(-1);
      if (!open) continue;
      const tag = open[1]!;
      const head = text.slice(match.index! - (before.length - open.index!), match.index! + match[0].length + 300);
      const attributes = head.slice(0, head.search(/[^=]>/) + 1 || head.length);
      const role = /\brole="(\w+)"/.exec(attributes)?.[1];
      const clickable =
        CLICKABLE_TAGS.has(tag) ||
        (role !== undefined && CLICKABLE_ROLES.has(role)) ||
        (/^[A-Z]/.test(tag) && CLICKABLE_COMPONENT.test(tag.split(".").at(-1)!));
      if (!clickable) continue;
      for (const name of value.match(/[A-Za-z][\w-]*/g) ?? []) if (name.length > 2) classes.add(name);
    }
  }
  return classes;
}

/// The selector's subject (its last compound) targets a clickable element.
function targetsClickable(selector: string, classes: Set<string>): boolean {
  const subject = selector.split(/\s*[>+~]\s*|\s+(?![^()]*\))/).at(-1) ?? selector;
  if (/^(button|a|summary|select)(?![\w-])/.test(subject)) return true;
  for (const [, inner] of subject.matchAll(/:(?:is|where)\(([^)]*)\)/g))
    if (/(^|[\s,])(button|a|summary|select)(?![\w-])|\[role="?(button|link|menuitem\w*|tab|option)/.test(inner!))
      return true;
  for (const [, role] of subject.matchAll(/\[role="?(\w+)/g)) if (CLICKABLE_ROLES.has(role!)) return true;
  for (const [, name] of subject.matchAll(/\.([A-Za-z][\w-]*)/g)) if (classes.has(name!)) return true;
  return false;
}

const DISABLED = /:disabled|\[disabled|aria-disabled|data-disabled|\[inert/;

type Rule = { file: string; line: number; selectors: string[]; body: string };

/// Every style rule of every webview stylesheet, comments blanked so line numbers hold.
function styleRules(): Rule[] {
  const rules: Rule[] = [];
  for (const file of new Glob("**/*.css").scanSync(src)) {
    const text = readFileSync(join(src, file), "utf8").replace(/\/\*[\s\S]*?\*\//g, (comment) =>
      comment.replace(/[^\n]/g, " "),
    );
    for (const rule of text.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
      const selectorText = rule[1]!.trim();
      if (selectorText.startsWith("@")) continue;
      const line = text.slice(0, rule.index! + rule[0].indexOf(rule[2]!)).split("\n").length;
      const selectors = selectorText.split(/,(?![^()]*\))/).map((part) => part.trim());
      rules.push({ file: relative(src, join(src, file)), line, selectors, body: rule[2]! });
    }
  }
  return rules;
}

const subjectOf = (selector: string) => selector.split(/\s*[>+~]\s*|\s+(?![^()]*\))/).at(-1) ?? selector;
const SETS_A_CURSOR = /(^|[;\s{])cursor\s*:\s*(?!default\b|auto\b|inherit\b|unset\b|initial\b|revert)[a-z-]/;

test("no stylesheet sets the arrow or auto on a clickable element", () => {
  const classes = clickableClasses();
  // Sanity: the classes of the bars and buttons Leo pointed at are known clickable.
  const known = ["acpmux-pr-dock__bar", "acpmux-send", "acpmux-mic", "cv-chip", "ui-menu-item", "cv-tool"];
  expect(known.filter((name) => !classes.has(name))).toEqual([]);
  const offenders: string[] = [];
  for (const rule of styleRules()) {
    if (!/(^|[;\s{])cursor\s*:\s*(default|auto)\b/.test(rule.body)) continue;
    for (const selector of rule.selectors)
      if (!DISABLED.test(selector) && targetsClickable(selector, classes))
        offenders.push(`${rule.file}:${rule.line} ${selector}`);
  }
  expect(offenders).toEqual([]);
});

// `all: unset` resets the cursor to inherit, the page's arrow, and a class rule beats the shared
// zero-specificity one: "Subagent finished" (.cv-tool) showed the arrow that way. A clickable class
// reset so sets a cursor again, in that rule or in one whose subject is that class alone (as
// `:is(button, a[href]).cv-tool`; `.cv-tool.is-toggle` covers only the toggles).
test("a clickable element whose rule resets every property sets its cursor again", () => {
  const classes = clickableClasses();
  const rules = styleRules();
  const restores = (name: string) =>
    rules.some(
      (rule) =>
        SETS_A_CURSOR.test(rule.body) &&
        rule.selectors.some((selector) => {
          const subject = subjectOf(selector);
          const named = [...subject.matchAll(/\.([A-Za-z][\w-]*)/g)].map((match) => match[1]);
          return !DISABLED.test(subject) && named.length === 1 && named[0] === name;
        }),
    );
  const offenders: string[] = [];
  for (const rule of rules) {
    if (!/(^|[;\s{])all\s*:\s*(unset|initial|revert)/.test(rule.body) || SETS_A_CURSOR.test(rule.body)) continue;
    for (const selector of rule.selectors) {
      if (DISABLED.test(selector) || !targetsClickable(selector, classes)) continue;
      const subject = subjectOf(selector);
      const named = [...subject.matchAll(/\.([A-Za-z][\w-]*)/g)].map((match) => match[1]!);
      if (!named.some(restores)) offenders.push(`${rule.file}:${rule.line} ${selector}`);
    }
  }
  expect(offenders).toEqual([]);
});
