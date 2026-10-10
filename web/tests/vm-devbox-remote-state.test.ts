import { describe, expect, test } from "bun:test";
import { runChild } from "./helpers/run-child";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { devboxForkDaemonReadyCommand, devboxForkReadinessStage, devboxStrandedRemoteSessionRepairCommand } from "../services/vms/images/remoteState";

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
  // The guest command runs with PATH set to the fixture's bin dir only, so no
  // host tool answers for the guest (a Linux runner has a real systemctl and
  // pgrep). Guest-specific commands are stubs; the POSIX text tools the
  // script pipes through are linked in explicitly. `date` is a fake clock
  // that advances one second per call and `sleep` returns at once, so the
  // loop's deadline is counted in clock reads, never in wall time.
  const HOST_TOOLS = ["cat", "grep", "head", "rm", "tr"] as const;
  const stub = (bin: string, name: string, body: string) =>
    writeFileSync(path.join(bin, name), `#!/bin/sh\n${body}\n`, { mode: 0o755 });
  const withFakeGuest = async (
    bound: string,
    run: (env: Record<string, string>, root: string, boundFile: string) => Promise<void>,
  ) => {
    const root = mkdtempSync(path.join(tmpdir(), "cmux-fork-ready-"));
    try {
      const bin = path.join(root, "bin");
      mkdirSync(bin);
      for (const tool of HOST_TOOLS) {
        const hostPath = ["/usr/bin", "/bin"].map((dir) => path.join(dir, tool)).find((candidate) => existsSync(candidate));
        if (!hostPath) throw new Error(`fixture needs ${tool}`);
        symlinkSync(hostPath, path.join(bin, tool));
      }
      // Metadata answers this clone's id; a daemon is listening on 1337; no
      // supervisor unit answers; no daemon process runs.
      stub(bin, "curl", "echo vm-clone");
      stub(bin, "ss", "echo 'LISTEN 0 128 *:1337 *:*'");
      stub(bin, "systemctl", "exit 1");
      stub(bin, "pgrep", "exit 1");
      stub(bin, "sleep", "exit 0");
      const clock = path.join(root, "clock");
      writeFileSync(clock, "1000\n");
      stub(bin, "date", `t=$(cat '${clock}'); echo "$t"; echo $((t + 1)) > '${clock}'`);
      const boundFile = path.join(root, "daemon-instance-id");
      writeFileSync(boundFile, `${bound}\n`);
      await run({ PATH: bin }, root, boundFile);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  };

  test("does not accept the source daemon's listener before the clone is bound", async () => {
    await withFakeGuest("vm-source", async (env, root, boundFile) => {
      const command = devboxForkDaemonReadyCommand(1, { homes: [path.join(root, "home")], boundInstanceFile: boundFile });
      const result = await runChild("/bin/sh", ["-c", command], { env });
      expect(result.status).toBe(1);
      expect(result.stderr.split("\n")[0]).toBe("cmux fork daemon did not become ready: stage=unbound supervisor=unknown");
    });
  });

  // The first stderr line names the stalled stage from a fixed vocabulary, so
  // the provider error (stored and alerted on) carries it without guest text.
  test("names the metadata stage when the clone cannot read its instance id", async () => {
    await withFakeGuest("vm-source", async (env, root, boundFile) => {
      const bin = env.PATH.split(":")[0];
      writeFileSync(path.join(bin, "curl"), "#!/bin/sh\nexit 7\n", { mode: 0o755 });
      const command = devboxForkDaemonReadyCommand(1, { homes: [path.join(root, "home")], boundInstanceFile: boundFile });
      const result = await runChild("/bin/sh", ["-c", command], { env });
      expect(result.status).toBe(1);
      expect(result.stderr.split("\n")[0]).toBe("cmux fork daemon did not become ready: stage=metadata-unavailable supervisor=unknown");
    });
  });

  test("names the listener stage when the clone is bound but nothing listens", async () => {
    await withFakeGuest("vm-clone", async (env, root, boundFile) => {
      const bin = env.PATH.split(":")[0];
      writeFileSync(path.join(bin, "ss"), "#!/bin/sh\nexit 0\n", { mode: 0o755 });
      writeFileSync(path.join(bin, "systemctl"), "#!/bin/sh\ncase \"$*\" in *is-active*) echo active; exit 0;; esac\nexit 0\n", { mode: 0o755 });
      // No cmux-tui server process: the stub answers for the guest, not the host.
      writeFileSync(path.join(bin, "pgrep"), "#!/bin/sh\nexit 1\n", { mode: 0o755 });
      writeFileSync(path.join(bin, "journalctl"), "#!/bin/sh\necho 'cmux-tui: some guest log line'\n", { mode: 0o755 });
      const command = devboxForkDaemonReadyCommand(1, { homes: [path.join(root, "home")], boundInstanceFile: boundFile });
      const result = await runChild("/bin/sh", ["-c", command], { env });
      expect(result.status).toBe(1);
      // The report is the one classified line; no guest log text follows it.
      expect(result.stderr).toBe("cmux fork daemon did not become ready: stage=daemon-absent supervisor=active\n");
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

  // Metadata reads that each run to their 1 s timeouts must not stretch the
  // loop past its deadline: the report has to land inside the exec budget.
  test("reports within its deadline when every metadata read times out", async () => {
    await withFakeGuest("vm-source", async (env, root, boundFile) => {
      const bin = env.PATH;
      const calls = path.join(root, "curl-calls");
      writeFileSync(path.join(bin, "curl"), `#!/bin/sh\necho x >> '${calls}'\nexit 28\n`, { mode: 0o755 });
      const command = devboxForkDaemonReadyCommand(3, { homes: [path.join(root, "home")], boundInstanceFile: boundFile });
      const result = await runChild("/bin/sh", ["-c", command], { env });
      expect(result.status).toBe(1);
      expect(result.stderr).toBe("cmux fork daemon did not become ready: stage=metadata-unavailable supervisor=unknown\n");
      // The fake clock advances one second per read: the deadline (start + 3)
      // ends the loop after exactly 3 passes of two metadata calls each,
      // however long each call would take on a real guest.
      expect(readFileSync(calls, "utf8").trim().split("\n")).toHaveLength(6);
    });
  });

  test("the stage parser accepts only the fixed stage and supervisor sets", () => {
    const line = (stage: string, supervisor: string) => `cmux fork daemon did not become ready: stage=${stage} supervisor=${supervisor}\nmore`;
    expect(devboxForkReadinessStage(line("unbound", "active"))).toBe("stage=unbound supervisor=active");
    expect(devboxForkReadinessStage(line("daemon-not-listening", "failed"))).toBe("stage=daemon-not-listening supervisor=failed");
    expect(devboxForkReadinessStage(line("token-abc", "active"))).toBe("stage=unknown");
    expect(devboxForkReadinessStage(line("unbound", "secret-value"))).toBe("stage=unknown");
    expect(devboxForkReadinessStage("cmux fork daemon did not become ready")).toBe("stage=unknown");
    expect(devboxForkReadinessStage(undefined)).toBe("stage=unknown");
  });

  test("names the supervisor state when the supervisor never binds the clone", async () => {
    await withFakeGuest("vm-source", async (env, root, boundFile) => {
      const bin = env.PATH.split(":")[0];
      writeFileSync(path.join(bin, "systemctl"), "#!/bin/sh\ncase \"$*\" in *is-active*) echo failed; exit 3;; esac\nexit 1\n", { mode: 0o755 });
      const command = devboxForkDaemonReadyCommand(1, { homes: [path.join(root, "home")], boundInstanceFile: boundFile });
      const result = await runChild("/bin/sh", ["-c", command], { env });
      expect(result.status).toBe(1);
      expect(result.stderr.split("\n")[0]).toBe("cmux fork daemon did not become ready: stage=unbound supervisor=failed");
    });
  });
});
