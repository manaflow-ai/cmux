import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { changedFiles, guestInstallScript, guestRestoreScript, PIECE_BYTES, remotePrepareScript, uploadPieces } from "./cloud-devloop";
import { keyedHoldProblem } from "./cloud-journey";

const bashParses = (script: string) => spawnSync("bash", ["-n"], { input: script, encoding: "utf8" });

describe("cloud devloop", () => {
  test("changed files: modified, added, renamed and untracked are copied; deleted and renamed-from are removed", () => {
    const files = changedFiles("M\tcmux-tui/a.rs\nA\tcmux-tui/b.rs\nD\tcmux-tui/c.rs\nR087\tcmux-tui/old.rs\tcmux-tui/new.rs\n", "scripts/x.ts\n\n");
    expect(files.copy).toEqual(["cmux-tui/a.rs", "cmux-tui/b.rs", "cmux-tui/new.rs", "scripts/x.ts"]);
    expect(files.removed).toEqual(["cmux-tui/c.rs", "cmux-tui/old.rs"]);
  });

  test("a file both deleted and untracked again is copied, not removed", () => {
    expect(changedFiles("D\tf.rs\n", "f.rs\n")).toEqual({ copy: ["f.rs"], removed: [] });
  });

  test("the build host, guest install and restore scripts are valid bash and quote what they are given", () => {
    for (const s of [
      remotePrepareScript("0123456789abcdef0123456789abcdef01234567", ["it's gone.rs"]),
      guestInstallScript("a".repeat(64), "patch", ["host", "acpmux"]),
      guestInstallScript("b".repeat(64), "full", []),
      guestRestoreScript(["host"]),
    ]) {
      const r = bashParses(s);
      expect(r.stderr).toBe("");
      expect(r.status).toBe(0);
    }
    expect(remotePrepareScript("abc", ["it's gone.rs"])).toContain(`rm -f -- 'it'\\''s gone.rs'`);
  });

  test("install checks the build's SHA-256 before anything moves, flips current in one rename, restarts only what it is told", () => {
    const s = guestInstallScript("c".repeat(64), "patch", ["acpmux"]);
    expect(s.indexOf("sha256sum -c")).toBeLessThan(s.indexOf("mv -f new.bin"));
    expect(s).toContain("--patch-from=current.bin");
    expect(s).toContain("mv -Tf /opt/cmux/current.devloop /opt/cmux/current");
    expect(s).toContain("systemctl --user restart acpmux.service");
    expect(s).not.toContain("cmux-host.service");
    // cp -a keeps the image profile's old mtime: the new profile is touched, and the prune never takes it.
    expect(s).toContain(`sudo -n touch "$P"`);
    expect(s).toContain(`{ grep -vxF "$P" || true; }`);
  });

  test("uploads in pieces under the 768 KiB machine write limit, in order, retrying a failed piece", async () => {
    const data = new Uint8Array(PIECE_BYTES * 2 + 10).map((_, i) => i % 251);
    const seen = new Map<string, number>();
    let failOnce = true;
    const cloud = {
      write: async (_m: string, file: string, bytes: Uint8Array) => {
        if (failOnce && file.endsWith("00001")) { failOnce = false; throw new Error("HTTP 502"); }
        expect(bytes.byteLength).toBeLessThan(768 * 1024);
        seen.set(file, bytes.byteLength);
      },
    };
    expect(await uploadPieces(cloud, "vm_x", "/d", data, 2)).toBe(3);
    expect([...seen.keys()].sort()).toEqual(["/d/00000", "/d/00001", "/d/00002"]);
    expect(seen.get("/d/00002")).toBe(10);
  });

  test("keyed hold: an unkeyed daemon, another keyed run or none at all is named; the start's own daemon passes", () => {
    expect(keyedHoldProblem("i1", { pid: 7, personKey: true, personInstance: "i1" })).toBeNull();
    expect(keyedHoldProblem("i1", { pid: 8, personInstance: "i2" })).toContain("unkeyed daemon took the socket");
    expect(keyedHoldProblem("i1", { pid: 8, personKey: true, personInstance: "i2" })).toContain("another keyed daemon");
    expect(keyedHoldProblem("i1", { running: false })).toContain("no daemon serves");
  });
});
