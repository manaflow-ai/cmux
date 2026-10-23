// The composer pill guard (scripts/cmux-next/check-composer-pills.py; Leo 2026-10-22,
// ask-d4eed794c9): every composer control is the `.acpmux-pill` primitive. A computed className is
// checked arm by arm, so a control that drops the primitive in one branch of a ternary, a template or
// a `cond && "acpmux-pill"` fails, not only one that never names it. The one non-control form, a
// transcript row (`<article className="acpmux-row acpmux-plan">`), is exempt only on a plain element:
// a Plan or access-trigger button without the primitive fails. Runs the real script on temp trees and
// on this checkout.
import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const script = path.resolve(import.meta.dir, "../../scripts/cmux-next/check-composer-pills.py");
setDefaultTimeout(30_000);
const roots: string[] = [];
afterAll(() => roots.forEach((root) => rmSync(root, { recursive: true, force: true })));

/** `view` is a whole JSX element, or a className attribute put on a <button>. */
function run(view: string) {
  const root = mkdtempSync(path.join(tmpdir(), "composer-pills-"));
  roots.push(root);
  const folder = path.join(root, "webviews/src/agent-session/acpmux");
  mkdirSync(folder, { recursive: true });
  writeFileSync(
    path.join(folder, "View.tsx"),
    `export const View = (ok: boolean) => ${view.startsWith("<") ? view : `<button ${view} />`};\n`,
  );
  const result = spawnSync("python3", ["-I", script, root], { encoding: "utf8" });
  return { status: result.status, out: `${result.stdout}${result.stderr}` };
}

describe("check-composer-pills: a control's className, branch by branch", () => {
  const passing = [
    'className="acpmux-send acpmux-pill acpmux-pill-icon"',
    'className={ok ? "acpmux-send acpmux-pill" : "acpmux-send acpmux-pill acpmux-pill-icon"}',
    'className={`acpmux-mic acpmux-pill ${ok ? "is-on" : ""}`}',
    'className={cx("acpmux-plan acpmux-pill", ok && "is-on")}',
    '<article className="acpmux-row acpmux-plan" />',
    // A literal role other than button leaves the row a plain element.
    '<article role="listitem" className="acpmux-row acpmux-plan" />',
    "<article className=\"acpmux-row acpmux-plan\" role={'article'} />",
    '<article data-role="button" className="acpmux-row acpmux-plan" />',
    '<span className="acpmux-picker-button acpmux-pill acpmux-access-trigger" />',
  ];
  const failing = [
    'className="acpmux-send"',
    'className={ok ? "acpmux-send acpmux-pill" : "acpmux-send"}',
    'className={`acpmux-mic ${ok ? "acpmux-pill" : ""}`}',
    'className={["acpmux-fast", ok && "acpmux-pill"].join(" ")}',
    'className={ok ? (ok ? "acpmux-plan acpmux-pill" : "acpmux-plan") : "other"}',
    // A Plan button is the control, whatever other classes it carries.
    'className="acpmux-plan"',
    'className="acpmux-row acpmux-plan"',
    // A button role in any spelling, a role decided at run time, or spread props (which may carry
    // one) make the row a control.
    '<div role="button" className="acpmux-row acpmux-plan" />',
    '<div role = "button" className="acpmux-row acpmux-plan" />',
    "<div role='button' className=\"acpmux-row acpmux-plan\" />",
    "<div role={'button'} className=\"acpmux-row acpmux-plan\" />",
    '<div role={"button"} className="acpmux-row acpmux-plan" />',
    '<div role={ "button" } className="acpmux-row acpmux-plan" />',
    '<div role={`button`} className="acpmux-row acpmux-plan" />',
    '<div role="Button" className="acpmux-row acpmux-plan" />',
    '<div className="acpmux-row acpmux-plan" role="button" />',
    '<div role={role} className="acpmux-row acpmux-plan" />',
    '<div role={ok ? "button" : "listitem"} className="acpmux-row acpmux-plan" />',
    '<div role="" className="acpmux-row acpmux-plan" />',
    '<div {...props} className="acpmux-row acpmux-plan" />',
    '<div className="acpmux-row acpmux-plan" {...rest} />',
    '<PlanButton className="acpmux-row acpmux-plan" />',
    // The permission mode's trigger is a control too, as a button or as the span that draws it.
    'className="acpmux-access-trigger"',
    '<span className="acpmux-access-trigger" />',
  ];
  for (const view of passing)
    test(`passes: ${view}`, () => {
      const result = run(view);
      expect(result.out).toContain("composer pills:");
      expect(result.status).toBe(0);
    });
  for (const view of failing)
    test(`fails: ${view}`, () => {
      const result = run(view);
      expect(result.out).toContain("without the pill primitive");
      expect(result.status).toBe(1);
    });
});

test("this checkout passes", () => {
  const result = spawnSync("python3", ["-I", script, path.resolve(import.meta.dir, "../..")], { encoding: "utf8" });
  expect(`${result.stdout}${result.stderr}`).toContain("composer pills:");
  expect(result.status).toBe(0);
});
