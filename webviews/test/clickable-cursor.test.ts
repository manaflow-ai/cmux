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
  // build-agent-pane-web.sh derives the page's sheets from the dev server's entry: dev.tsx imports
  // the base sheets in the page's order (the components' own sheets follow, after them).
  const entry = join(src, "agent-session/acpmux");
  const dev = readFileSync(join(entry, "dev.tsx"), "utf8");
  const paths = [...dev.matchAll(/^import "(\.{1,2}\/[^"]+\.css)";$/gm)].map(([, path]) => join(entry, path!));
  expect(paths.map((path) => relative(src, path))).toContain("pages/shared/desktop.css");
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
  <!-- An image thumbnail's button shows zoom-in, and so does the image in it. -->
  <div class="cv-user__images"><button data-expect="zoom-in" data-name="sent image thumbnail" type="button"><img data-expect="zoom-in" data-name="sent image" alt="" /></button></div>
  <button data-expect="zoom-in" data-name="queued image thumbnail" type="button" class="acpmux-queued-image"><img data-expect="zoom-in" data-name="queued image" alt="" /></button>
  <div class="cv-md selectable"><button data-expect="zoom-in" data-name="reply image" type="button" class="cv-img-open"><img data-expect="zoom-in" data-name="reply image picture" class="cv-img" alt="" /></button></div>
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
  <fieldset>
    <label data-expect="pointer" data-name="size choice"><input type="radio" name="size" /><span data-expect="pointer" data-name="size choice text">8 GB</span></label>
    <label data-expect="default" data-name="locked size choice"><input type="radio" name="size" disabled /><span data-expect="default" data-name="locked size choice text">32 GB</span></label>
    <!-- A label for an enabled control keeps the hand beside a disabled one, after it or before it.
         CSS cannot follow \`for\` to a disabled control, so such a label keeps the hand too. -->
    <input type="checkbox" disabled /><label data-expect="pointer" data-name="label after a disabled box, for an enabled one" for="fixture-on-a"><span data-expect="pointer" data-name="its text">On</span></label><input id="fixture-on-a" type="checkbox" />
    <input id="fixture-on-b" type="checkbox" /><label data-expect="pointer" data-name="label before a disabled box, for an enabled one" for="fixture-on-b">On</label><input type="checkbox" disabled />
    <label>Model <select data-expect="pointer" data-name="enabled select with a disabled placeholder, in a label"><option disabled>Pick one</option><option>A</option></select></label>
    <label data-expect="pointer" data-name="for label around an enabled select with a disabled option" for="fixture-select">Model <select id="fixture-select"><option disabled>Pick one</option><option>A</option></select></label>
  </fieldset>
  <div>
    <input data-expect="pointer" data-name="checkbox" type="checkbox" />
    <input data-expect="pointer" data-name="radio" type="radio" />
    <input data-expect="pointer" data-name="input button" type="button" value="Go" />
    <input data-expect="pointer" data-name="submit" type="submit" />
    <input data-expect="pointer" data-name="reset" type="reset" />
    <input data-expect="pointer" data-name="colour well" type="color" />
    <input data-expect="pointer" data-name="file picker" type="file" />
    <input data-expect="default" data-name="disabled checkbox" type="checkbox" disabled />
  </div>
  <!-- A disabled fieldset's first legend stays enabled (HTML); a link inside the fieldset still opens. -->
  <fieldset disabled>
    <legend><input data-expect="pointer" data-name="checkbox in a disabled fieldset's legend" type="checkbox" /><label data-expect="pointer" data-name="legend label" for="fixture-legend-box">All</label><input id="fixture-legend-box" type="checkbox" /></legend>
    <input data-expect="default" data-name="checkbox in a disabled fieldset" type="checkbox" />
    <span data-expect="default" data-name="text in a disabled fieldset">Off</span>
    <a data-expect="pointer" data-name="link in a disabled fieldset" href="/help"><span data-expect="pointer" data-name="its words">Help</span></a>
  </fieldset>
  <!-- What is disabled on its own inside that legend keeps the arrow, and so does an aria-disabled group. -->
  <fieldset disabled>
    <legend><button data-expect="default" data-name="disabled button in an enabled legend" type="button" disabled><span data-expect="default" data-name="its label">Off</span></button>
      <fieldset disabled><input data-expect="default" data-name="box in a disabled fieldset in the legend" type="checkbox" /><span data-expect="default" data-name="text there">Off</span><a data-expect="pointer" data-name="link there" href="/help">Help</a></fieldset></legend>
  </fieldset>
  <div role="group" aria-disabled="true"><button data-expect="default" data-name="button in an aria-disabled group" type="button"><span data-expect="default" data-name="its words, too">Off</span></button></div>
  <!-- Inert content takes no pointer input (a sheet's background, a closing popup), so it keeps the arrow. -->
  <button data-expect="default" data-name="inert button" type="button" inert><span data-expect="default" data-name="inert button's words">Off</span></button>
  <div inert><a data-expect="default" data-name="link in an inert subtree" href="/help"><span data-expect="default" data-name="its words, inert">Help</span></a><div data-expect="default" data-name="menu row in an inert subtree" role="menuitem">Copy</div><input data-expect="default" data-name="checkbox in an inert subtree" type="checkbox" /></div>
  <!-- A locked choice keeps the arrow, but a link in its label still opens. -->
  <label data-expect="default" data-name="locked choice with a link"><input type="checkbox" disabled /><span data-expect="default" data-name="locked choice words">Locked</span> <a data-expect="pointer" data-name="help link in a locked choice" href="/help"><span data-expect="pointer" data-name="help link words">Help</span></a> <button data-expect="pointer" data-name="button in a locked choice" type="button">Why</button></label>
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
/// An <input> that is a control, not a field (its `type`, in JSX or in a selector).
const CLICKABLE_INPUT = /\btype=["']?(checkbox|radio|button|submit|reset|color|file)\b/;
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
  "treeitem",
]);
/// Components that render a clickable element (Base UI's menu items and triggers, our buttons).
const CLICKABLE_COMPONENT = /(Button|MenuItem|Item|Trigger|Tab|Link|Toggle|Checkbox|Switch|Radio|Option|Summary)$/;

/// Every `className` the sources put on a clickable element (a <button>, a link, a clickable role,
/// an element with a click handler, or a component that renders one), with the file and line it
/// sits on. A component's `rowClassName` or `itemClassName` goes on its rows or items, which take
/// the click (ui/Tree's treeitem rows, a combobox's options).
function clickableClassNames(): { file: string; line: number; value: string }[] {
  const found: { file: string; line: number; value: string }[] = [];
  for (const file of new Glob("**/*.{ts,tsx}").scanSync(src)) {
    if (/\.test\.tsx?$/.test(file)) continue;
    const text = readFileSync(join(src, file), "utf8");
    // A literal, a template, or an expression (`cx("ui-menu-item", …)`), whose string parts count.
    for (const match of text.matchAll(
      /\b(className|rowClassName|itemClassName)=(?:"([^"]*)"|\{`([^`]*)`\}|\{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\})/g,
    )) {
      const value =
        match[2] ??
        match[3] ??
        [...(match[4] ?? "").matchAll(/"([^"]*)"|'([^']*)'|`([^`]*)`/g)]
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
        match[1] !== "className" ||
        // Selectable text that also takes a click (a cut message opens) keeps the I-beam.
        (/\son(Click|DoubleClick)=/.test(attributes) && !/(^|\s)selectable(\s|$)/.test(value)) ||
        CLICKABLE_TAGS.has(tag) ||
        (tag === "input" && CLICKABLE_INPUT.test(attributes)) ||
        (role !== undefined && CLICKABLE_ROLES.has(role)) ||
        (/^[A-Z]/.test(tag) && CLICKABLE_COMPONENT.test(tag.split(".").at(-1)!));
      if (!clickable) continue;
      found.push({ file, line: text.slice(0, match.index!).split("\n").length, value });
    }
  }
  return found;
}

/// Every class the sources put on a clickable element.
function clickableClasses(): Set<string> {
  const classes = new Set<string>();
  for (const { value } of clickableClassNames())
    for (const name of value.match(/[A-Za-z][\w-]*/g) ?? []) if (name.length > 2) classes.add(name);
  return classes;
}

/// `text` cut at each separator outside parentheses (a selector list at its commas, a selector at
/// its combinators), however deeply they nest: `a:not(:is(b, c)) d` has the subject `d`.
function splitTop(text: string, separator: RegExp): string[] {
  const parts: string[] = [];
  let depth = 0;
  let start = 0;
  for (let index = 0; index < text.length; index++) {
    const char = text[index]!;
    if (char === "(" || char === "[") depth++;
    else if (char === ")" || char === "]") depth--;
    else if (depth === 0 && separator.test(char)) {
      parts.push(text.slice(start, index));
      start = index + 1;
    }
  }
  parts.push(text.slice(start));
  return parts.map((part) => part.trim()).filter(Boolean);
}

/// A selector's subject, its last compound.
const subjectOf = (selector: string) => splitTop(selector, /[\s>+~]/).at(-1) ?? selector;

/// The selector's subject (its last compound) targets a clickable element.
function targetsClickable(selector: string, classes: Set<string>): boolean {
  const subject = subjectOf(selector);
  if (/^(button|a|summary|select)(?![\w-])/.test(subject)) return true;
  if (/^input(?![\w-])/.test(subject) && CLICKABLE_INPUT.test(subject.replace(/\[type=/g, " type="))) return true;
  for (const [, inner] of subject.matchAll(/:(?:is|where)\(([^)]*)\)/g))
    if (
      /(^|[\s,])(button|a|summary|select)(?![\w-])|\[role="?(button|link|menuitem\w*|tab|option|treeitem)/.test(inner!)
    )
      return true;
  for (const [, role] of subject.matchAll(/\[role="?(\w+)/g)) if (CLICKABLE_ROLES.has(role!)) return true;
  for (const [, name] of subject.matchAll(/\.([A-Za-z][\w-]*)/g)) if (classes.has(name!)) return true;
  return false;
}

const DISABLED_STATE = /:disabled|\[disabled|aria-disabled|data-disabled|\[inert/;
/// The selector with every `:not(…)` removed, however deeply its parentheses nest.
function withoutNot(selector: string): string {
  let out = "";
  for (let index = 0; index < selector.length;) {
    if (!selector.startsWith(":not(", index)) {
      out += selector[index++];
      continue;
    }
    let depth = 0;
    for (index += 4; index < selector.length; index++) {
      if (selector[index] === "(") depth++;
      else if (selector[index] === ")" && --depth === 0) break;
    }
    index++;
  }
  return out;
}
/// The selector matches only a disabled element: a disabled state outside `:not(…)`
/// (`button:not(:disabled)` and `button:not(:is(:where(:disabled)))` are enabled buttons).
const DISABLED = { test: (selector: string) => DISABLED_STATE.test(withoutNot(selector)) };

/// The sheets and sources the guards hold to the rule: the agent pane, the shared ui components
/// and the shared page sheets. The other pages' cleanups follow in their own change, which holds
/// every sheet to it.
const inScope = (file: string) =>
  /^(agent-session|ui|pages\/shared)\//.test(file) || file === "markdown-task-checkbox.css";

type Rule = { file: string; line: number; selectors: string[]; body: string };

const blank = (text: string) => text.replace(/[^\n]/g, " ");

/// Every style rule of every webview stylesheet, comments and statement at-rules (`@import …;`,
/// `@layer a, b;`) blanked so line numbers hold. An unblanked `@import` would join the first rule's
/// selector and hide it (ui.css's `.ui-button` arrow went unseen so).
function styleRules(): Rule[] {
  const rules: Rule[] = [];
  for (const file of new Glob("**/*.css").scanSync(src)) {
    const text = readFileSync(join(src, file), "utf8")
      .replace(/\/\*[\s\S]*?\*\//g, blank)
      .replace(/@[\w-]+[^{};]*;/g, blank);
    for (const rule of text.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
      const selectorText = rule[1]!.trim();
      if (selectorText.startsWith("@")) continue;
      const line = text.slice(0, rule.index! + rule[0].indexOf(rule[2]!)).split("\n").length;
      const selectors = splitTop(selectorText, /,/);
      rules.push({ file: relative(src, join(src, file)), line, selectors, body: rule[2]! });
    }
  }
  return rules;
}

const SETS_A_CURSOR = /(^|[;\s{])cursor\s*:\s*(?!default\b|auto\b|inherit\b|unset\b|initial\b|revert)[a-z-]/;

test("the scan counts the clickable input types as clickable", () => {
  const none = new Set<string>();
  expect(
    ['input[type="checkbox"]', "input[type=radio]", '.x input:is([type="submit"], [type="reset"])'].map((selector) =>
      targetsClickable(selector, none),
    ),
  ).toEqual([true, true, true]);
  expect(
    ['input[type="text"]', "input", 'input[type="range"]'].map((selector) => targetsClickable(selector, none)),
  ).toEqual([false, false, false]);
});

test("only a disabled selector is exempt", () => {
  expect(["button:disabled", '.x[aria-disabled="true"]', "a:not(.y):disabled"].map(DISABLED.test)).toEqual([
    true,
    true,
    true,
  ]);
  expect(
    ["button:not(:disabled)", "button:not(:is(:where(:disabled)))", ".x:not([disabled]) span"].map(DISABLED.test),
  ).toEqual([false, false, false]);
});

/// A clickable class's variant that takes no click: a file on the machine an agent's message came
/// from is a <span> chip (LinkChips.tsx ElsewhereChip), so it keeps the arrow.
const NOT_CLICKABLE = new Set([".cv-chip.is-elsewhere"]);

test("no stylesheet sets the arrow or auto on a clickable element", () => {
  const classes = clickableClasses();
  // Sanity: the classes of the bars and buttons Leo pointed at are known clickable.
  const known = ["acpmux-pr-dock__bar", "acpmux-send", "acpmux-mic", "cv-chip", "ui-menu-item", "cv-tool", "files-row"];
  expect(known.filter((name) => !classes.has(name))).toEqual([]);
  // Sanity: the rule right after ui.css's @import lines is read (it once was not): ui.css's first
  // parsed rule is its first rule, the theme block that names .ui-button (the later arrow rule does not).
  const uiFirst = styleRules()
    .filter((rule) => rule.file === "ui/ui.css")
    .sort((a, b) => a.line - b.line)[0];
  expect(uiFirst?.selectors.join(", ")).toStartWith(":where(.ui-popup, .ui-tooltip, .ui-toolbar, .ui-button,");
  const offenders: string[] = [];
  for (const rule of styleRules().filter((rule) => inScope(rule.file))) {
    if (!/(^|[;\s{])cursor\s*:\s*(default|auto)\b/.test(rule.body)) continue;
    for (const selector of rule.selectors)
      if (!DISABLED.test(selector) && !NOT_CLICKABLE.has(selector) && targetsClickable(selector, classes))
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
  for (const rule of rules.filter((rule) => inScope(rule.file))) {
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

// A Tailwind `cursor-default` or `cursor-auto` on a clickable element beats the shared rule the same
// way (AgentIntegrations' <summary> kept the arrow so). A variant (`disabled:cursor-default`) is fine.
test("no clickable element carries a cursor-default or cursor-auto utility class", () => {
  const offenders = clickableClassNames()
    .filter(({ file }) => inScope(file))
    .filter(({ value }) => /(^|\s)cursor-(default|auto)(?![\w-])/.test(value))
    .map(({ file, line, value }) => `${file}:${line} ${value}`);
  expect(offenders).toEqual([]);
});
