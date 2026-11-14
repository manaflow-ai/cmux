import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PNG } from "pngjs";
import { loadSurfaces, validateSurface } from "./expectations";
import { judge, runGate, updateBaselines } from "./gate";
import { parseJustifications } from "./justification";

const solid = (w: number, h: number, rgb: [number, number, number], paint?: { x: number; y: number; w: number; h: number; rgb: [number, number, number] }) => {
  const png = new PNG({ width: w, height: h });
  for (let y = 0; y < h; y++)
    for (let x = 0; x < w; x++) {
      const inside = paint && x >= paint.x && x < paint.x + paint.w && y >= paint.y && y < paint.y + paint.h;
      const [r, g, b] = inside ? paint.rgb : rgb;
      png.data.set([r, g, b, 255], (y * w + x) * 4);
    }
  return PNG.sync.write(png);
};

/** A repo-shaped fixture: expectations, base baselines and head captures for one web surface with two states. */
function fixture(head: { open?: Buffer; closed?: Buffer | null }, keep = [{ name: "rows", why: "row contract", box: [0, 0, 10, 10] }]) {
  const root = mkdtempSync(join(tmpdir(), "vg-"));
  const exp = join(root, "exp");
  mkdirSync(join(exp, "web"), { recursive: true });
  writeFileSync(
    join(exp, "web", "ui.menu.json"),
    JSON.stringify({
      id: "ui.menu",
      title: "Menu",
      schemes: ["light"],
      captures: [
        { state: "open", entry: "ui.menu", variant: "open" },
        { state: "closed", entry: "ui.menu", variant: "closed" },
      ],
      keep,
    }),
  );
  const base = join(root, "base");
  const cap = join(root, "cap");
  for (const dir of [base, cap]) {
    mkdirSync(join(dir, "web", "ui.menu"), { recursive: true });
    writeFileSync(join(dir, "web", "renderer.json"), JSON.stringify({ id: "chrome 156.0; linux; fonts x" }));
  }
  writeFileSync(join(base, "web", "ui.menu", "open-light.png"), solid(40, 40, [255, 255, 255]));
  writeFileSync(join(base, "web", "ui.menu", "closed-light.png"), solid(40, 40, [255, 255, 255]));
  writeFileSync(join(cap, "web", "ui.menu", "open-light.png"), head.open ?? solid(40, 40, [255, 255, 255]));
  if (head.closed !== null) writeFileSync(join(cap, "web", "ui.menu", "closed-light.png"), head.closed ?? solid(40, 40, [255, 255, 255]));
  return { root, exp, base, cap, out: join(root, "out") };
}

const gate = (f: ReturnType<typeof fixture>, body = "") =>
  runGate({ expectations: f.exp, baselines: f.base, captures: f.cap, body, out: f.out, head: "abcdef1234567", mediaBase: "https://example.test/m" });

describe("justification block", () => {
  test("reads refs, states, verdicts and reasons under a Visual changes heading only", () => {
    const parsed = parseJustifications(
      [
        "- web/ui.menu: better — not in the block",
        "## Visual changes",
        "- web/ui.menu: better — adopts the shared veil",
        "- `ios/team-appearance#sheet` (intentional): translucent per the spec",
        "- mac/settings: meh — unknown verdict here",
        "- web/ui.dialog: worse",
        "## Testing",
        "- web/ui.tooltip: better — after the block",
      ].join("\n"),
    );
    expect(parsed.justifications.map((j) => [j.ref, j.state, j.verdict])).toEqual([
      ["web/ui.menu", undefined, "better"],
      ["ios/team-appearance", "sheet", "intentional"],
    ]);
    expect(parsed.problems).toHaveLength(2);
  });
});

describe("expectations", () => {
  test("keep regions need exactly one of selector or box, and a why", () => {
    const base = { id: "x", title: "X", captures: [{ state: "a", entry: "e", variant: "v" }] };
    expect(() => validateSurface({ ...base, keep: [{ name: "k", why: "w" }] }, "f", "web")).toThrow(/exactly one/);
    expect(() => validateSurface({ ...base, keep: [{ name: "k", why: "", box: [0, 0, 1, 1] }] }, "f", "web")).toThrow(/why/);
    expect(() => validateSurface({ id: "x", title: "X", captures: [{ state: "a", stateFile: "s.json" }], keep: [{ name: "k", why: "w", selector: "a" }] }, "f", "mac")).toThrow(/selectors only/);
  });

  test("the checked-in expectations validate", () => {
    const surfaces = loadSurfaces(join(import.meta.dir, "../../../design/visual-expectations"));
    expect(surfaces.length).toBeGreaterThan(0);
  });
});

describe("judging", () => {
  test("an unchanged head passes", () => {
    const report = gate(fixture({}));
    expect(report.verdict).toBe("pass");
    expect(report.counts.ok).toBe(2);
  });

  test("a change in a keep region without a justification fails, and a justification explains it", () => {
    const changed = solid(40, 40, [255, 255, 255], { x: 2, y: 2, w: 6, h: 6, rgb: [0, 0, 0] });
    expect(gate(fixture({ open: changed })).verdict).toBe("fail");
    const f = fixture({ open: changed });
    const report = gate(f, "## Visual changes\n- web/ui.menu#open: better — the rows read clearer");
    expect(report.verdict).toBe("pass");
    expect(report.results[0]).toMatchObject({ state: "open", severity: "explained" });
    expect(readFileSync(join(f.out, "comment.md"), "utf8")).toContain("![web/ui.menu open](https://example.test/m/vg-abcdef1-web-ui.menu-open.png)");
    expect(readFileSync(join(f.out, "media.txt"), "utf8")).toBe("images/vg-abcdef1-web-ui.menu-open.png\n");
  });

  test("a change outside keep regions only warns; one inside tolerance is ok", () => {
    const outside = solid(40, 40, [255, 255, 255], { x: 30, y: 30, w: 6, h: 6, rgb: [0, 0, 0] });
    const report = gate(fixture({ open: outside }));
    expect(report.verdict).toBe("warn");
    expect(report.results[0]).toMatchObject({ status: "changed", severity: "warn" });
    const tiny = solid(40, 40, [255, 255, 255], { x: 30, y: 30, w: 1, h: 1, rgb: [0, 0, 0] });
    const f = fixture({ open: tiny });
    writeFileSync(join(f.exp, "web", "ui.menu.json"), readFileSync(join(f.exp, "web", "ui.menu.json"), "utf8").replace('"title"', '"tolerance":{"ratio":0.01},"title"'));
    expect(gate(f).results.find((r) => r.state === "open")).toMatchObject({ status: "within", severity: "ok" });
  });

  test("a baselined state that stops rendering fails unless justified as removed", () => {
    expect(gate(fixture({ closed: null })).verdict).toBe("fail");
    expect(gate(fixture({ closed: null }), "## Visual changes\n- web/ui.menu#closed: removed — the closed state is gone").verdict).toBe("pass");
  });

  test("a surface the run did not attempt is listed, not failed", () => {
    const f = fixture({});
    rmSync(join(f.cap, "web", "ui.menu"), { recursive: true });
    const report = gate(f);
    expect(report.verdict).toBe("pass");
    expect(report.notCaptured).toEqual(["web/ui.menu"]);
  });

  test("a changed renderer turns a keep failure into a warning", () => {
    expect(judge("changed", true, undefined, true).severity).toBe("warn");
    expect(judge("changed", true, undefined, false).severity).toBe("fail");
    expect(judge("flaky", true, undefined, false).severity).toBe("warn");
  });

  test("--update copies explained states into the baselines", () => {
    const changed = solid(40, 40, [255, 255, 255], { x: 2, y: 2, w: 6, h: 6, rgb: [0, 0, 0] });
    const f = fixture({ open: changed });
    const report = gate(f, "## Visual changes\n- web/ui.menu: intentional — new rows");
    const written = updateBaselines(report, f.cap, f.base);
    expect(written).toEqual([join(f.base, "web", "ui.menu", "open-light.png")]);
    expect(gate(f).verdict).toBe("pass");
  });
});
