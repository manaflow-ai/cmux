// The composer pill guard (scripts/cmux-next/check-composer-pills.py; Leo 2026-10-22,
// ask-d4eed794c9): every composer control is the `.acpmux-pill` primitive. A computed className is
// checked arm by arm, so a control that drops the primitive in one branch of a ternary, a template or
// a `cond && "acpmux-pill"` fails, not only one that never names it. Runs the real script on temp
// trees and on this checkout.
import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const script = path.resolve(import.meta.dir, "../../scripts/cmux-next/check-composer-pills.py");
setDefaultTimeout(30_000);
const roots: string[] = [];
afterAll(() => roots.forEach((root) => rmSync(root, { recursive: true, force: true })));

function run(view: string) {
  const root = mkdtempSync(path.join(tmpdir(), "composer-pills-"));
  roots.push(root);
  const folder = path.join(root, "webviews/src/agent-session/acpmux");
  mkdirSync(folder, { recursive: true });
  writeFileSync(path.join(folder, "View.tsx"), `export const View = (ok: boolean) => <button ${view} />;\n`);
  const result = spawnSync("python3", ["-I", script, root], { encoding: "utf8" });
  return { status: result.status, out: `${result.stdout}${result.stderr}` };
}

describe("check-composer-pills: a control's className, branch by branch", () => {
  const passing = [
    'className="acpmux-send acpmux-pill acpmux-pill-icon"',
    'className={ok ? "acpmux-send acpmux-pill" : "acpmux-send acpmux-pill acpmux-pill-icon"}',
    'className={`acpmux-mic acpmux-pill ${ok ? "is-on" : ""}`}',
    'className={cx("acpmux-plan acpmux-pill", ok && "is-on")}',
    'className="acpmux-row acpmux-plan"',
  ];
  const failing = [
    'className="acpmux-send"',
    'className={ok ? "acpmux-send acpmux-pill" : "acpmux-send"}',
    'className={`acpmux-mic ${ok ? "acpmux-pill" : ""}`}',
    'className={["acpmux-fast", ok && "acpmux-pill"].join(" ")}',
    'className={ok ? (ok ? "acpmux-plan acpmux-pill" : "acpmux-plan") : "other"}',
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
