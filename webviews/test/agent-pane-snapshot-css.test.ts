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
