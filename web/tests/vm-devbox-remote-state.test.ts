import { describe, expect, test } from "bun:test";
import { runChild } from "./helpers/run-child";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { devboxForkDaemonReadyCommand, devboxStrandedRemoteSessionRepairCommand } from "../services/vms/images/remoteState";

// A fork of a machine from an image whose boot supervisor deleted only
// sessions/<session>/auth resumes with the session's lifecycle fence still in
// place, and cmux-tui refuses to start on a fence without auth. The repair
// runs here against real directories laid out as that clone holds them.
describe("stranded remote session repair (services/vms/images/remoteState.ts)", () => {
  const session = (home: string, name: string) => path.join(home, ".local/state/cmux/remote/sessions", name);

  test("removes a fenced session without auth and keeps a live one", async () => {
    const root = mkdtempSync(path.join(tmpdir(), "cmux-remote-state-"));
    try {
      const user = path.join(root, "home-cmux");
      const admin = path.join(root, "root");
      const stranded = session(user, "Y2xvdWQ");
      mkdirSync(stranded, { recursive: true });
      writeFileSync(path.join(stranded, "lifecycle-fence.json"), "{\"version\":1}");
      writeFileSync(path.join(stranded, "shutdown.json"), "{}");
      writeFileSync(path.join(stranded, "link.sock.lock"), "");
      const live = session(admin, "Y2xvdWQ");
      mkdirSync(path.join(live, "auth"), { recursive: true });
      writeFileSync(path.join(live, "lifecycle-fence.json"), "{\"version\":1}");
      const unfenced = session(user, "b3RoZXI");
      mkdirSync(unfenced, { recursive: true });

      const result = await runChild("/bin/sh", ["-c", devboxStrandedRemoteSessionRepairCommand([user, admin, path.join(root, "missing")])]);

      expect(result.status).toBe(0);
      expect(existsSync(stranded)).toBe(false);
      expect(existsSync(path.join(live, "auth"))).toBe(true);
      expect(existsSync(path.join(live, "lifecycle-fence.json"))).toBe(true);
      expect(existsSync(unfenced)).toBe(true);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});

// When create returns, a clone may still run the source's resumed daemon on
// port 1337 before its supervisor has noticed the clone. Readiness must wait
// for the supervisor's bind to this machine, not take that stale listener.
describe("fork daemon readiness (services/vms/images/remoteState.ts)", () => {
  const withFakeGuest = async (
    bound: string,
    run: (env: Record<string, string>, root: string, boundFile: string) => Promise<void>,
  ) => {
    const root = mkdtempSync(path.join(tmpdir(), "cmux-fork-ready-"));
    try {
      const bin = path.join(root, "bin");
      mkdirSync(bin);
      // Metadata answers this clone's id; a daemon is listening on 1337.
      writeFileSync(path.join(bin, "curl"), "#!/bin/sh\necho vm-clone\n", { mode: 0o755 });
      writeFileSync(path.join(bin, "ss"), "#!/bin/sh\necho 'LISTEN 0 128 *:1337 *:*'\n", { mode: 0o755 });
      const boundFile = path.join(root, "daemon-instance-id");
      writeFileSync(boundFile, `${bound}\n`);
      await run({ PATH: `${bin}:/usr/bin:/bin` }, root, boundFile);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  };

  test("does not accept the source daemon's listener before the clone is bound", async () => {
    await withFakeGuest("vm-source", async (env, root, boundFile) => {
      const command = devboxForkDaemonReadyCommand(1, { homes: [path.join(root, "home")], boundInstanceFile: boundFile });
      const result = await runChild("/bin/sh", ["-c", command], { env });
      expect(result.status).toBe(1);
      expect(result.stderr).toBe("cmux fork daemon did not become ready\n");
    });
  });

  test("repairs the stranded session and accepts the listener once bound", async () => {
    await withFakeGuest("vm-clone", async (env, root, boundFile) => {
      const home = path.join(root, "home");
      const stranded = path.join(home, ".local/state/cmux/remote/sessions/Y2xvdWQ");
      mkdirSync(stranded, { recursive: true });
      writeFileSync(path.join(stranded, "lifecycle-fence.json"), "{\"version\":1}");
      const command = devboxForkDaemonReadyCommand(1, { homes: [home], boundInstanceFile: boundFile });
      const result = await runChild("/bin/sh", ["-c", command], { env });
      expect(result.status).toBe(0);
      expect(existsSync(stranded)).toBe(false);
    });
  });
  // A user snapshot of a machine whose supervisor unit was stopped resumes
  // with no supervisor at all: a memory image never re-runs boot, so nothing
  // binds the clone or starts its daemon. Readiness starts the enabled unit,
  // which is what a boot of that machine would have done.
  test("starts a stopped supervisor unit so the clone binds and listens", async () => {
    await withFakeGuest("vm-source", async (env, root, boundFile) => {
      const bin = env.PATH.split(":")[0];
      const started = path.join(root, "started");
      writeFileSync(path.join(bin, "systemctl"), [
        "#!/bin/sh",
        `case "$*" in`,
        `  *is-active*) [ -e '${started}' ] && exit 0; echo inactive; exit 3;;`,
        `  *start*cmux-tui-daemon.service*) : > '${started}'; echo vm-clone > '${boundFile}'; exit 0;;`,
        "esac",
        "exit 1",
      ].join("\n") + "\n", { mode: 0o755 });
      const command = devboxForkDaemonReadyCommand(2, { homes: [path.join(root, "home")], boundInstanceFile: boundFile });
      const result = await runChild("/bin/sh", ["-c", command], { env });
      expect(result.stderr).toBe("");
      expect(result.status).toBe(0);
      expect(existsSync(started)).toBe(true);
    });
  });

  test("returns a generic failure when the daemon never listens", async () => {
    await withFakeGuest("vm-source", async (env, root, boundFile) => {
      const bin = env.PATH.split(":")[0];
      writeFileSync(path.join(bin, "systemctl"), "#!/bin/sh\ncase \"$*\" in *is-active*) echo failed; exit 3;; esac\nexit 1\n", { mode: 0o755 });
      const command = devboxForkDaemonReadyCommand(1, { homes: [path.join(root, "home")], boundInstanceFile: boundFile });
      const result = await runChild("/bin/sh", ["-c", command], { env });
      expect(result.status).toBe(1);
      expect(result.stderr).toBe("cmux fork daemon did not become ready\n");
    });
  });
});
