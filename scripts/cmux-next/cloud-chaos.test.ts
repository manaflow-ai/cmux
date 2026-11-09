import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { chaosProbeRow, dropCommand, FAULTS, NOT_INJECTED, relayCutCommand, type ChaosResult } from "./cloud-chaos.ts";

const ok = (fault: string, ms: number): ChaosResult => ({ fault, outcome: "ok", recover_ms: ms, carrier: "resumed the session", turn: "completed once", detail: "" });

describe("chaosProbeRow", () => {
  test("ok only when every fault that ran passed; ms is the slowest recovery", () => {
    const row = chaosProbeRow("p", [ok("drop 5 s", 900), ok("drop 60 s", 2400), { ...ok("vault down", 0), outcome: "not run", recover_ms: null }], undefined, new Date("2026-11-08T09:00:00.123Z"));
    expect(row.outcome).toBe("ok");
    expect(row.ms).toBe(2400);
    expect(row.at).toBe("2026-11-08T09:00:00Z");
    expect(row.error).toBeNull();
  });

  test("a failed fault fails the row and is named", () => {
    const row = chaosProbeRow("p", [ok("relay cut", 300), { ...ok("drop 60 s", 0), outcome: "fail", recover_ms: null, detail: "no answer within 120 s" }]);
    expect(row.outcome).toBe("fail");
    expect(String(row.error)).toContain("drop 60 s: no answer within 120 s");
  });

  test("a run where nothing ran is a failure, not a pass", () => {
    const row = chaosProbeRow("p", NOT_INJECTED.map((n) => ({ fault: n.name, outcome: "not run" as const, recover_ms: null, carrier: "", turn: "", detail: n.why })));
    expect(row.outcome).toBe("fail");
    expect(row.error).toBe("no fault ran");
  });
});

describe("faults", () => {
  test("a drop restores itself on the machine after its length", () => {
    const cmd = dropCommand(60);
    expect(cmd).toStartWith("sudo -n sh -c ");
    expect(cmd).toContain("sleep 60");
    expect(cmd).toContain("iptables -D OUTPUT -p tcp --dport 443 -j DROP");
    expect(cmd).toContain("nft delete table inet cmuxchaos");
  });

  test("a drop arms its restore before any rule goes in, and says ok only once every rule is in", () => {
    const cmd = dropCommand(5);
    expect(cmd.indexOf("sleep 5")).toBeLessThan(cmd.indexOf("iptables -I OUTPUT"));
    expect(cmd).toContain("then echo @@ok iptables; else iptables -D OUTPUT");
    expect(cmd).toContain("then echo @@ok nft; else nft delete table inet cmuxchaos");
  });

  test("the session host is found without matching the shell that looks for it", () => {
    const restart = FAULTS.find((f) => f.name === "session host restart")!;
    expect(restart.command).toContain("'--relay-slo[t]'");
  });

  test("a relay cut says ok only when ss -K exits 0 and closed a socket", () => {
    // Fake sudo and ss on PATH: ss prints what SSMODE says, as `ss -K -H` lists the sockets it closed.
    const bin = mkdtempSync(join(tmpdir(), "chaos-ss-"));
    try {
      writeFileSync(join(bin, "sudo"), "#!/bin/sh\nshift\nexec \"$@\"\n");
      writeFileSync(join(bin, "ss"), [
        "#!/bin/sh",
        'case "$SSMODE" in',
        '  closed) echo "ESTAB 0 0 10.0.0.2:5555 1.2.3.4:443"; echo "ESTAB 0 0 10.0.0.2:5556 1.2.3.4:443";;',
        "  nothing) ;;",
        '  refused) echo "SOCK_DESTROY answers: Operation not supported" >&2; exit 1;;',
        "esac",
        "",
      ].join("\n"));
      chmodSync(join(bin, "sudo"), 0o755);
      chmodSync(join(bin, "ss"), 0o755);
      const run = (mode: string) =>
        spawnSync("sh", ["-c", relayCutCommand()], { env: { ...process.env, SSMODE: mode, PATH: `${bin}:${process.env.PATH}` }, encoding: "utf8" }).stdout.trim();
      expect(run("closed")).toBe("@@ok 2");
      // A kernel without SOCK_DESTROY closes nothing and still exits 0: not a cut.
      expect(run("nothing")).toBe("@@failed rc=0 closed=0");
      expect(run("refused")).toBe("@@failed rc=1 closed=0");
      expect(FAULTS.find((f) => f.name === "relay cut")!.command).toBe(relayCutCommand());
    } finally {
      rmSync(bin, { recursive: true, force: true });
    }
  });

  test("Leo's 5 s and 60 s drops are both in the leg", () => {
    expect(FAULTS.map((f) => f.name)).toEqual(expect.arrayContaining(["drop 5 s", "drop 60 s", "relay cut", "session host restart"]));
  });
});
