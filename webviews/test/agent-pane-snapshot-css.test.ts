// The chat copy's extra sheet (scripts/agent-pane/snapshotCss.mjs) gives the copy's host the live page's
// value of every variable a page rule sets on `:host`. The shared Tailwind theme sets its variables on
// `:root, :host`, some as themselves; on the copy's host only that layered rule matched, the cycle left
// `--text-detail` unset, and the copy's trust ask drew 4 px taller than the live one (relaunch-shift bench;
// Leo, 2026-11-14: "too much render shift when the thing restarts to update").
import { expect, test } from "bun:test";
import { snapshotCss } from "../scripts/agent-pane/snapshotCss.mjs";

test("every variable set on :host inherits on the copy's host, unlayered and last", () => {
  const css = `@layer theme{:root,:host{--text-detail:var(--text-detail);--gap:4px}}
:root{--text-detail:12px}
:host(.other){--ring:1px;color:red}
.row{color:blue}`;
  const out = snapshotCss(css);
  expect(out.replace(/\s+/g, "")).toMatch(/:host\{--gap:inherit;--ring:inherit;--text-detail:inherit\}$/);
  // The layered rule's :host member is not carried as a rule of its own; its :root member is rewritten.
  expect(out.replace(/\s+/g, "")).not.toMatch(/:host\{--text-detail:var/);
  expect(out).not.toContain(".row");
});

test("a sheet with no :host rule gets no :host rule", () => {
  expect(snapshotCss(":root{--a:1px}.x{color:red}")).not.toContain(":host");
});

// The copy shows its last frame (chatSnapshot/paint.ts STILL), so a root flag's motion timings never
// apply there: the motion flags' timings were most of pane-copy.css (agent-pane-styles budget).
test("a root rule's motion timings are left out; its frame-picking animation and !important stay", () => {
  const css = `html[data-cmux-motion=off] .a{transition:none}
html[data-agent-motion=on] .b{transition:opacity .2s;opacity:0}
html[data-agent-motion=on] .c{animation:rise .2s both;animation-duration:.3s;animation-delay:1s}
html[data-x] .d{transition:none!important}`;
  const out = snapshotCss(css).replace(/\s+/g, "");
  expect(out).not.toContain(".a");
  expect(out).toMatch(/\.b\{opacity:0\}/);
  expect(out).toContain("animation:rise");
  expect(out).not.toContain("animation-duration");
  expect(out).not.toContain("animation-delay");
  expect(out).toMatch(/\.d\{transition:none!important\}/);
});
