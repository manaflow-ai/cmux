import { describe, expect, test } from "bun:test";
import { execConformanceCase, execConformanceOn, execConformanceProbe, JOURNEY_ACPMUX_DIR, journeyAcpmuxAssemble, journeyAcpmuxPieces, parseCaseNames, parseRows, rowText, verdict } from "./cloud-journey-exec-conformance.ts";

const row = (c: string, o: Record<string, unknown> = {}) => ({ case: c, identical: true, diffs: [], routedRan: "fork", ...o });

describe("exec conformance on prod", () => {
  test("opt-in", () => {
    expect(execConformanceOn("1")).toBe(true);
    expect(execConformanceOn(" true ")).toBe(true);
    expect(execConformanceOn("")).toBe(false);
    expect(execConformanceOn(undefined)).toBe(false);
    expect(execConformanceOn("0")).toBe(false);
  });

  test("case names come from the suite's refusal", () => {
    expect(parseCaseNames("error: no such case: @@none (the cases: echo, cargo-build-test, git-commit)")).toEqual(["echo", "cargo-build-test", "git-commit"]);
    expect(parseCaseNames("error: unrecognized subcommand 'exec-router'")).toEqual([]);
  });

  test("rows are parsed and the summary line is not a row", () => {
    const out = [JSON.stringify(row("echo")), "noise", JSON.stringify({ summary: { identical: "1/1", ok: true } }), "@@ec exit=0"].join("\n");
    expect(parseRows(out).map((r) => r.case)).toEqual(["echo"]);
  });

  test("N/N identical, every routed side on a run VM, passes", () => {
    const v = verdict(["a", "cargo-build-test"], [row("a"), row("cargo-build-test", { exit: { local: 0, routed: 0 } })]);
    expect(v.ok).toBe(true);
    expect(v.line).toBe("identical 2/2; on a run VM 2/2");
    expect(v.cargo).toBe("cargo-build-test: identical, routed ran fork exit 0/0");
  });

  test("a routed side that ran here fails, as does a diff, a skip and a missing row", () => {
    expect(verdict(["a"], [row("a", { routedRan: "here", routedCause: "no backend" })]).ok).toBe(false);
    expect(verdict(["a"], [row("a", { identical: false, diffs: ["stdout"] })]).line).toContain("UNEXPECTED: a");
    const s = verdict(["a", "cargo-build-test"], [row("a"), row("cargo-build-test", { skipped: "needs cargo" })]);
    expect(s.ok).toBe(false);
    expect(s.line).toContain("skipped: cargo-build-test");
    expect(verdict(["a", "b"], [row("a")]).line).toContain("no row: b");
    expect(verdict([], []).ok).toBe(false);
  });

  test("row text", () => {
    expect(rowText(row("x", { identical: false, diffs: ["exit", "tree"], exit: { local: 0, routed: 1 } }) as any)).toBe("x: DIFF, routed ran fork exit 0/1 diffs exit,tree");
  });

  test("the case script carries the backend, AutoCloud on, and quotes values", () => {
    const s = execConformanceCase("echo", { api: "https://api.example", token: "t'ok", team: "team1", machine: "m-1;rm" }, "/tmp/d");
    expect(s).toContain("export CMUX_CLOUD_API_URL='https://api.example'");
    expect(s).toContain("export CMUX_CLOUD_ACCESS_TOKEN='t'\\''ok'");
    expect(s).toContain("export CMUX_CLOUD_TEAM='team1'");
    expect(s).toContain('export CMUX_VM_ID="${CMUX_VM_ID:-m-1rm}"');
    expect(s).toContain('"cloud.autoCloud": true');
    expect(s).toContain("--json exec-router conformance --case 'echo'");
    expect(execConformanceCase("e", { api: "a", token: "t", machine: "m" }, "/d")).toContain("unset CMUX_CLOUD_TEAM");
  });

  test("the journey's acpmux is cut into fs/write pieces under 8 MiB, in order", () => {
    const gz = new Uint8Array(13);
    for (let i = 0; i < gz.length; i++) gz[i] = i;
    const p = journeyAcpmuxPieces(gz, 5);
    expect(p.map((x) => x.path)).toEqual([0, 1, 2].map((i) => `${JOURNEY_ACPMUX_DIR}/acpmux.gz.000${i}`));
    expect(p.map((x) => x.data.length)).toEqual([5, 5, 3]);
    expect(Array.from(p[2].data)).toEqual([10, 11, 12]);
    expect(journeyAcpmuxPieces(new Uint8Array(0))).toEqual([]);
  });

  test("assembly checks the sum, unpacks, and prints the version", () => {
    const s = journeyAcpmuxAssemble(2, "abc");
    expect(s).toContain(`cat '${JOURNEY_ACPMUX_DIR}/acpmux.gz.0000' '${JOURNEY_ACPMUX_DIR}/acpmux.gz.0001' >`);
    expect(s).toContain(`[ "$got" = 'abc' ]`);
    expect(s).toContain("gunzip -c");
    expect(s).toContain("@@ec journey_acpmux=");
  });

  test("the journey's acpmux is first on PATH, so `$a` and the routed side's own_bin are it", () => {
    expect(execConformanceProbe()).toContain(`export PATH="${JOURNEY_ACPMUX_DIR}:$HOME/.cargo/bin:$PATH"`);
  });
});
