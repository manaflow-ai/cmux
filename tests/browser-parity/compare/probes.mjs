// Structure-fidelity probes on the fixture pages. Each probe finds a line by
// text and tests what the tool shows next to it: the line, its child lines,
// and (when the line has no address) its parent line, where browser-use puts
// an element's attributes. A probe fails when the tool omits the fact.
import { REF_RE, parseItems, norm } from "./metrics.mjs";

const indentOf = (l) => /^[~+]?([\t ]*)/.exec(l)[1].replace(/\t/g, "  ").length;

function windows(tool, text, find) {
  const lines = (text ?? "").split("\n");
  const re = REF_RE[tool];
  const out = [];
  lines.forEach((line, i) => {
    if (!(find instanceof RegExp ? find.test(line) : line.includes(find))) return;
    const ind = indentOf(line);
    const w = [line];
    for (let j = i + 1; j < lines.length && indentOf(lines[j]) > ind && j <= i + 4; j++) w.push(lines[j]);
    if (!(re && re.test(line))) {
      for (let j = i - 1; j >= 0 && j >= i - 3; j--) {
        if (indentOf(lines[j]) < ind) {
          w.unshift(lines[j]);
          break;
        }
      }
    }
    out.push(w.join("\n"));
  });
  return out;
}

const near = (find, test) => (tool, text) => windows(tool, text, find).some((w) => test.test(w));
const whole = (test) => (_tool, text) => test.test(text ?? "");
const absent = (test) => (_tool, text) => !test.test(text ?? "");
const addr = (name, count = 1, role = null) => (tool, text) => {
  const key = norm(name);
  return parseItems(tool, text).items.filter((it) => ` ${norm(it.block)} `.includes(` ${key} `) && (!role || role.test(it.line))).length >= count;
};

// [category, id, description, page, test]
export const structureProbes = [
  ["structure", "heading-level", "heading level (h3)", "aria", near("Level three", /level[=: ]*3|Value: 3\b|\bh3\b/i)],
  ["structure", "heading-role", "heading role", "aria", near("Level four", /heading|\bh4\b/i)],
  ["structure", "landmark-nav", "navigation landmark with name", "aria", near("Breadcrumb", /navigation|<nav\b/i)],
  ["structure", "landmark-main", "main landmark", "aria", whole(/(^[\s-]*|\] |\t)main\b(?!\.swift)/m)],
  ["structure", "landmark-footer", "contentinfo (footer)", "aria", whole(/contentinfo|<footer/i)],
  ["structure", "table", "table with caption", "aria", near("Scores", /table|caption/i)],
  ["structure", "table-cell", "table cells kept as cells", "aria", near(/\bAda\b/, /cell|<td|\brow\b/i)],
  ["structure", "table-header", "column header", "states", near(/\bUser\b(?!s)/, /columnheader|<th\b|header/i)],
  ["structure", "list", "list items", "index", near(/\bOne\b/, /listitem|<li\b|\blist\b/i)],
  ["structure", "dialog", "dialog role", "aria", near("Inline dialog", /dialog/i)],
  ["structure", "alert", "alert role", "aria", near("Heads up", /alert/i)],
  ["states", "checked", "radio checked", "aria", near("Small", /\[checked(=true)?\]|checked="?true|Value: 1\b/i)],
  ["states", "mixed", "checkbox mixed", "states", near("Some selected", /mixed|Value: 2\b/i)],
  ["states", "expanded", "expanded=false on a disclosure button", "aria", near("Menu", /expanded|collapsed/i)],
  ["states", "selected", "selected tab", "aria", near("First", /\[selected\]|selected="?true|\(selected/i)],
  ["states", "pressed", "pressed toggle button", "aria", near("Bold", /pressed(?!=false)|Value: 1\b/i)],
  ["states", "disabled", "disabled button", "surface", near(/\bOff\b/, /disabled/i)],
  ["states", "required", "required field", "states", near(/\bName\b/, /required/i)],
  ["states", "invalid", "invalid field", "states", near("Code", /invalid/i)],
  ["states", "readonly", "readonly field", "states", near("Account", /read-?only|read only/i)],
  ["states", "value", "textarea value", "index", near("Bio", /\bhi\b/)],
  ["states", "placeholder", "placeholder text", "index", near("Email", /you@x\.com/)],
  ["states", "slider-value", "slider value", "aria", near("Volume", /\b3\b/)],
  ["states", "select-options", "collapsed select lists its options", "index", whole(/\bTeam\b/)],
  ["links", "link-target", "link URL available", "states", near("relative", /aria\.html\?x=1/)],
  ["frames", "frames-both", "same- and cross-origin iframe content addressable", "frames", addr("Inside frame", 2)],
  ["frames", "frame-deep", "3 levels of alternating-origin iframes", "nest", addr("Deep button")],
  ["frames", "frame-srcdoc", "srcdoc iframe", "nest", addr("Srcdoc button")],
  ["frames", "frame-nested-srcdoc", "srcdoc inside srcdoc", "surface", addr("Inner-ph")],
  ["shadow", "shadow-open", "open shadow root", "shadow", addr("Shadow button")],
  ["shadow", "shadow-closed", "closed shadow root", "nest", addr("Closed shadow button")],
  ["widgets", "contenteditable", "contenteditable marked editable", "input", near("Rich editor", /textbox|editable|settable|text ?area/i)],
  ["widgets", "onclick-div", "div with a click handler addressable", "aria", addr("Clickable div")],
  ["widgets", "scrollable", "scroll container marked", "input", near("Scroller", /scroll/i)],
  ["security", "password", "password value not shown", "states", absent(/hunter2/)],
  ["security", "hidden-details", "closed <details> body not shown", "aria", absent(/Hidden details text/)],
];

export function scoreStructure(page, outputs) {
  const res = {};
  for (const [category, id, , p, test] of structureProbes) {
    if (p !== page) continue;
    for (const [tool, o] of Object.entries(outputs)) {
      if (!o || o.error || o.text == null) continue;
      (res[tool] ??= {})[id] = { category, pass: !!test(tool, o.text) };
    }
  }
  return res;
}

// Focus is only visible after an action; checked on the change scenario.
export function focusProbe(tool, afterText) {
  if (!afterText) return null;
  if (/The focused UI element is [^\n]*Email/.test(afterText)) return true;
  return windows(tool, afterText, "Email").some((w) => /focused|\[active\]|focus=true/i.test(w));
}
