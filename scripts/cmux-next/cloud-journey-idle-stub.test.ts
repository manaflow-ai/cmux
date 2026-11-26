import { afterAll, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { JOURNEY_STUB_SCRIPT, MODEL_STUB_PY, modelStubRestart, modelStubStop } from "./cloud-journey";

// RFD 0144: the idle walk's model stub was the guest's only workload listener (run 45772305511, port 39735), so the
// machine never paused. The walk stops it for the wait and starts it again, on the same port, with the next message.
const dir = mkdtempSync(join(tmpdir(), "journey-idle-stub-"));
const d = join(dir, "journey-model-stub");
const sh = (cmd: string) => spawnSync("bash", ["-c", cmd], { encoding: "utf8", timeout: 30_000 });
const info = (port: number) => sh(`curl -fsS -m 2 http://127.0.0.1:${port}/__stub/info`);
afterAll(() => {
  sh(`p=$(cat ${d}.pid 2>/dev/null); [ -n "$p" ] && kill "$p" 2>/dev/null; true`);
  rmSync(dir, { recursive: true, force: true });
});

describe("idle walk and the model stub", () => {
  test("the stub is stopped for the wait and back on its port with the next message", () => {
    copyFileSync(MODEL_STUB_PY, `${d}.py`);
    writeFileSync(`${d}.json`, JSON.stringify(JOURNEY_STUB_SCRIPT));
    writeFileSync(`${d}.log`, '{"before":"pause"}\n');
    // As the journey's "model stub on the machine" step launches it: port 0, the pid it records.
    const up = sh(
      `(nohup python3 ${d}.py --port 0 --script ${d}.json --nonce n0nce --log ${d}.log --ready-file ${d}.ready >${d}.log.out 2>&1 & echo $! >${d}.pid); ` +
        `for i in $(seq 50); do [ -s ${d}.ready ] && break; sleep 0.2; done; cat ${d}.ready`,
    );
    const port = JSON.parse(up.stdout).port as number;
    expect(info(port).stdout).toContain("n0nce");

    const stop = sh(modelStubStop(dir));
    expect(stop.status).toBe(0);
    expect(stop.stdout).toContain(`@@stopped ${port}`);
    // Nothing listens on the stub's port during the wait, so it is no workload.
    expect(sh(`ss -ltnH "sport = :${port}"`).stdout.trim()).toBe("");
    expect(info(port).status).not.toBe(0);

    const back = sh(`${modelStubRestart(port, "n0nce", dir)}echo sent`);
    expect(back.status).toBe(0);
    expect(back.stdout).toContain("sent");
    expect(info(port).stdout).toContain("n0nce");
    // The log is appended to: the turns before the pause still count.
    expect(readFileSync(`${d}.log`, "utf8")).toContain('{"before":"pause"}');
  });

  test("no recorded stub: the stop says so instead of reporting a port", () => {
    const empty = mkdtempSync(join(tmpdir(), "journey-idle-nostub-"));
    const r = sh(modelStubStop(empty));
    rmSync(empty, { recursive: true, force: true });
    expect(r.status).not.toBe(0);
    expect(r.stdout).toContain("@@nostub");
  });
});
