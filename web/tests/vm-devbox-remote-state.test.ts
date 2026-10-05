import { describe, expect, test } from "bun:test";
import { runChild } from "./helpers/run-child";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { devboxStrandedRemoteSessionRepairCommand } from "../services/vms/images/remoteState";

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
