// An eval's agent cannot open pages on the Mac that runs it: `open <url>` and a connection to
// the person's cmux app fail inside both sandbox profiles; the sample's own socket stays
// reachable. Run: `bun test tests/tool-evals/live-guard.test.mjs` (macOS; skipped elsewhere).
import { afterAll, describe, expect, test } from "bun:test";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";

import { join } from "node:path";
import { agentProfile, shellProfile } from "./live-guard.mjs";

const mac = process.platform === "darwin";
const scratch = mkdtempSync("/tmp/lg-") // short: a unix socket path is at most 104 bytes;
// A stand-in home: the guard blocks `<home>/.local/state/cmux`, where the app puts its socket.
const home = join(scratch, "home");

const profiles = {
  agent: agentProfile(home),
  shell: shellProfile({ sessionName: `te${process.pid}-guard`, work: scratch, dir: scratch, home }),
};

// Listening sockets the probes connect to (the sandbox answers ENOENT before EPERM for a path
// with nothing on it, so each probe needs a listener). They are this test's own, never the app's.
const listeners = [];
// The per-user temp dir the app puts its socket in (`$TMPDIR` of an agent can differ).
const userTemp = mac ? realpathSync(execFileSync("getconf", ["DARWIN_USER_TEMP_DIR"]).toString().trim()) : "/tmp";
async function listen(path) {
  mkdirSync(join(path, ".."), { recursive: true });
  rmSync(path, { force: true });
  const server = createServer();
  await new Promise((resolve, reject) => server.once("error", reject).listen(path, resolve));
  listeners.push([server, path]);
  return path;
}
afterAll(() => {
  for (const [server, path] of listeners) { server.close(); rmSync(path, { force: true }); }
  rmSync(join(userTemp, `cmux-lg${process.pid}`), { recursive: true, force: true });
  rmSync(scratch, { recursive: true, force: true });
});

function sandboxed(profile, argv) {
  const file = join(scratch, `${Math.random().toString(36).slice(2)}.sb`);
  writeFileSync(file, profile);
  const r = spawnSync("sandbox-exec", ["-f", file, ...argv], { encoding: "utf8", timeout: 20_000 });
  return { code: r.status, out: `${r.stdout}${r.stderr}` };
}

// Connects to a listening unix socket: EPERM when the sandbox refuses, CONNECTED when not.
function connectErrno(profile, path) {
  const py = "import socket,sys,errno\ns=socket.socket(socket.AF_UNIX)\ntry:\n s.connect(sys.argv[1]); print('CONNECTED')\nexcept OSError as e:\n print(errno.errorcode.get(e.errno, e))";
  return sandboxed(profile, ["/usr/bin/python3", "-I", "-c", py, path]).out.trim();
}

describe.skipIf(!mac)("eval sandboxes keep agents off the live machine", () => {
  for (const [name, profile] of Object.entries(profiles)) {
    // A scheme no app claims: without the guard LaunchServices answers "No application
    // knows how to open URL", so the probe never opens a real page either way.
    test(`${name}: /usr/bin/open is refused`, () => {
      const r = sandboxed(profile, ["/usr/bin/open", "cmuxliveguardprobe://x"]);
      expect(r.out).toContain("Operation not permitted");
    });

    test(`${name}: osascript is refused`, () => {
      const r = sandboxed(profile, ["/usr/bin/osascript", "-e", "return 1"]);
      expect(r.out).toContain("Operation not permitted");
    });

    test(`${name}: an open from a shell (as an agent's Bash runs it) is refused`, () => {
      const r = sandboxed(profile, ["/bin/bash", "-c", "PATH=/usr/bin:/bin open cmuxliveguardprobe://x"]);
      expect(r.out).toContain("Operation not permitted");
      expect(r.out).not.toContain("No application knows");
    });

    test(`${name}: the person's cmux app sockets are refused`, async () => {
      const state = await listen(join(home, ".local/state/cmux", `${name}-probe.sock`));
      const tmp = await listen(`/tmp/cmux-live-guard-${process.pid}-${name}.sock`);
      expect(connectErrno(profile, state)).toBe("EPERM");
      expect(connectErrno(profile, tmp)).toBe("EPERM");
      // The app's own socket sits in $TMPDIR/cmux-tui-<uid>/; probe a sibling, never the app's.
      const perUser = await listen(join(userTemp, `cmux-lg${process.pid}`, `${name[0]}.sock`));
      expect(connectErrno(profile, perUser)).toBe("EPERM");
    });

    test(`${name}: the sample's own socket under /tmp/cte stays reachable`, async () => {
      const own = await listen(`/tmp/cte/te${process.pid}-guard.sock`);
      expect(connectErrno(profile, own)).toBe("CONNECTED");
    });
  }
});
