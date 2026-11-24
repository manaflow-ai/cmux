import { describe, expect, test } from "bun:test";
import { acpmuxMachineVerbs, cloudVerbs, helpRows, judge, remoteVerbs, shortVerbs } from "./cloud-command-matrix";

describe("cloud-command-matrix", () => {
  test("reads the verb lists from the source", () => {
    const cloud = cloudVerbs();
    for (const v of ["list-machines", "pause-machine", "exec", "start-session", "start-chat", "env"]) expect(cloud).toContain(v);
    const short = shortVerbs();
    for (const v of ["ls", "status", "pause", "resume", "rm", "exec", "ssh", "move"]) expect(short).toContain(v);
  });

  test("remote and acpmux machine rows come from their parsers, not a hand list", () => {
    const remote = remoteVerbs();
    for (const v of ["connect", "ssh", "exec", "cp", "stop", "disconnect", "reconnect"]) expect(remote).toContain(v);
    for (const v of ["doctor", "trust"]) expect(remote).not.toContain(v);
    const machine = acpmuxMachineVerbs();
    for (const v of ["add", "ls", "enroll-self", "tunnel", "consent"]) expect(machine).toContain(v);
    // Nested verbs are rows too (Greptile on #52473: a one-word regex dropped them).
    for (const v of ["ticket new", "consent grant", "vault keep"]) expect(machine).toContain(v);
  });

  test("every row asks for help and short verbs are checked under vm and cloud", () => {
    const rows = helpRows();
    expect(rows.every((r) => r.words.at(-1) === "--help")).toBe(true);
    const cmds = rows.map((r) => `${r.bin} ${r.words.join(" ")}`);
    expect(cmds).toContain("cmux vm status --help");
    expect(cmds).toContain("cmux cloud status --help");
    expect(cmds).toContain("acpmux machine enroll-self --help");
    const nested = rows.find((r) => r.words.join(" ") === "machine ticket new --help");
    expect(nested?.parent).toEqual(["machine", "ticket", "--help"]);
  });

  test("judges the parent's text as the overview, not the verb's help", () => {
    const row = { bin: "cmux" as const, words: ["vm", "pause", "--help"], cls: "pause", parent: ["vm", "--help"] };
    expect(judge(row, 0, "overview text pause", "overview text pause", false)).toBe("overview");
    expect(judge(row, 0, "usage: cmux vm pause NAME", "overview", false)).toBe("ok");
    expect(judge(row, 2, "usage", "overview", false)).toBe("error");
    expect(judge(row, 0, "usage: something else", "overview", false)).toBe("unnamed");
    expect(judge(row, null, "", "overview", true)).toBe("timeout");
  });
});

describe("cloud-command-matrix spawn", () => {
  test("a binary that cannot start stops the run instead of filling it with error rows", async () => {
    const { runRows, SpawnError } = await import("./cloud-command-matrix");
    const row = { bin: "cmux" as const, words: ["--help"], cls: "help" };
    expect(() => runRows([row], { cmux: "/nonexistent/cmux", acpmux: "/nonexistent/acpmux" })).toThrow(SpawnError);
  });
});
