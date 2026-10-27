import { afterEach, describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

import { runChild } from "./helpers/run-child";

// The devbox image's root-run sync keeps the machine's kind record (an
// informational record of the kind cmux assigned) current from the reflection
// route. It writes only an answer it fetched, so a failed fetch never replaces
// the record the Cloud backend wrote at create (services/vms/guestVmKind.ts).

type VmGuestKind = "owner" | "team";

const roots: string[] = [];
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function guestRoot(): string {
  const root = mkdtempSync(path.join(tmpdir(), "cmux-vm-kind-sync-"));
  roots.push(root);
  mkdirSync(path.join(root, "etc/cmux"), { recursive: true, mode: 0o755 });
  return root;
}

const kindDir = (root: string) => path.join(root, "etc/cmux");
const kindFile = (root: string) => path.join(kindDir(root), "vm-kind");
describe("the image's cmux-vm-kind-sync", () => {
  const SYNC = path.join(import.meta.dirname, "../services/vms/images/devbox/cmux-vm-kind-sync");

  /** Runs the sync against root with a curl that answers `answer` (or fails when null). */
  async function sync(root: string, answer: VmGuestKind | null, extraEnv: Record<string, string> = {}) {
    const bin = path.join(root, "sync-bin");
    mkdirSync(bin, { recursive: true });
    writeFileSync(path.join(bin, "curl"), answer ? `#!/bin/sh\nprintf '{"kind":"${answer}"}'\n` : "#!/bin/sh\nexit 22\n");
    chmodSync(path.join(bin, "curl"), 0o755);
    const env = path.join(root, "model-plane.env");
    writeFileSync(env, "export CMUX_CODEROUTER_URL='https://cmux.example'\n");
    const result = await runChild("/bin/sh", [SYNC], {
      env: { PATH: `${bin}:${process.env.PATH}`, CMUX_VM_KIND_FILE: kindFile(root), CMUX_VM_MODEL_ENV_FILE: env, ...extraEnv },
    });
    expect(result.status).toBe(0);
  }

  test("a failed fetch keeps the record the create wrote", async () => {
    const root = guestRoot();
    writeFileSync(kindFile(root), "owner\n");
    await sync(root, null);
    expect(readFileSync(kindFile(root), "utf8")).toBe("owner\n");
  });

  test("a failed fetch writes nothing where there is no record", async () => {
    const root = guestRoot();
    await sync(root, null);
    expect(readdirSync(kindDir(root)).filter((name) => name.startsWith(".vm-kind") || name === "vm-kind")).toEqual([]);
  });

  test("an answer replaces the record", async () => {
    const root = guestRoot();
    writeFileSync(kindFile(root), "team\n");
    await sync(root, "owner");
    expect(readFileSync(kindFile(root), "utf8")).toBe("owner\n");
  });

  test("the boot's clone reset writes team without fetching", async () => {
    const root = guestRoot();
    writeFileSync(kindFile(root), "owner\n");
    await sync(root, "owner", { CMUX_VM_KIND_RESET: "team" });
    expect(readFileSync(kindFile(root), "utf8")).toBe("team\n");
    const boot = readFileSync(path.join(import.meta.dirname, "../services/vms/images/devbox/cmux-devbox-boot"), "utf8");
    expect(boot).toContain("CMUX_VM_KIND_RESET=team /usr/local/bin/cmux-vm-kind-sync");
  });
});
