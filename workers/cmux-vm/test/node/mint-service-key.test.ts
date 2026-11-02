import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, it } from "vitest";
import { parseServiceKeys } from "../../src/auth/service-keys.ts";
import { isApiKeyShaped } from "../../src/auth/credentials.ts";

// scripts/mint-service-key.sh against stand-ins for gh and wrangler that record what each got on stdin:
// the Worker gets a key the API accepts, GitHub gets an entry the Worker parses with that key's hash,
// neither appears in the output, and an existing GitHub secret is never overwritten.

const SCRIPT = join(import.meta.dirname, "../../scripts/mint-service-key.sh");
const ARGS = [
  "--id", "cloud-platform-staging", "--github-env", "cmux-vm-staging",
  "--github-secret", "CMUX_VM_SERVICE_KEYS_CLOUD_PLATFORM_STAGING",
  "--worker", "cmux-platform-staging", "--worker-secret", "CLOUD_VM_API_SERVICE_KEY",
];
const dirs: string[] = [];
afterEach(() => { for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true }); });

const run = (opts: { github?: string[]; worker?: string[]; args?: string[] } = {}) => {
  const dir = mkdtempSync(join(tmpdir(), "mint-service-key-"));
  dirs.push(dir);
  const fake = (name: string, body: string) => {
    writeFileSync(join(dir, name), `#!/usr/bin/env bash\nset -eu\n${body}\n`);
    chmodSync(join(dir, name), 0o755);
  };
  fake("gh", `case "$1 $2" in
  "secret list") printf '%s\\n' ${(opts.github ?? []).join(" ")} ;;
  "secret set") echo "$@" > "${dir}/gh-args"; cat > "${dir}/gh-stdin" ;;
  *) exit 9 ;;
esac`);
  fake("wrangler", `case "$1 $2" in
  "secret list") printf '%s' '${JSON.stringify((opts.worker ?? []).map((name) => ({ name, type: "secret_text" })))}' ;;
  "secret put") echo "$@" > "${dir}/wrangler-args"; cat > "${dir}/wrangler-stdin" ;;
  *) exit 9 ;;
esac`);
  const result = spawnSync("bash", [SCRIPT, ...(opts.args ?? ARGS)], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, WRANGLER: join(dir, "wrangler") },
  });
  const read = (name: string) => { try { return readFileSync(join(dir, name), "utf8"); } catch { return undefined; } };
  return { ...result, read };
};

it("gives the Worker the key and GitHub an entry with its hash, and prints neither", () => {
  const r = run({ worker: ["OTHER"] });
  expect(r.status, r.stderr).toBe(0);
  const key = r.read("wrangler-stdin")!;
  expect(isApiKeyShaped(key)).toBe(true);
  expect(r.read("wrangler-args")).toBe("secret put CLOUD_VM_API_SERVICE_KEY --name cmux-platform-staging\n");
  expect(r.read("gh-args")).toBe("secret set CMUX_VM_SERVICE_KEYS_CLOUD_PLATFORM_STAGING --env cmux-vm-staging --repo manaflow-ai/cmux\n");
  const sha = createHash("sha256").update(key).digest("hex");
  const parsed = parseServiceKeys(r.read("gh-stdin"));
  expect(parsed.ok).toBe(true);
  expect(parsed.keys).toHaveLength(1);
  expect(parsed.keys[0]).toMatchObject({ id: "cloud-platform-staging", sha256: sha, labels: { role: "cloud" }, teams: null });
  expect([...parsed.keys[0]!.scopes]).toEqual(["vm:read", "vm:write", "vm:exec", "vm:files", "vm:network", "snapshot:*", "mesh:read", "mesh:write"]);
  expect(r.stdout).toContain("ok");
  for (const secret of [key, sha]) {
    expect(r.stdout).not.toContain(secret);
    expect(r.stderr).not.toContain(secret);
    expect(r.read("gh-args")).not.toContain(secret);
  }
});

it("refuses when the GitHub secret already exists and mints nothing", () => {
  const r = run({ github: ["CMUX_VM_SERVICE_KEYS_CLOUD_PLATFORM_STAGING"] });
  expect(r.status).not.toBe(0);
  expect(r.stderr).toContain("refusing to overwrite");
  expect(r.read("gh-stdin")).toBeUndefined();
  expect(r.read("wrangler-stdin")).toBeUndefined();
});

it("refuses an existing Worker secret unless told to replace it", () => {
  const refused = run({ worker: ["CLOUD_VM_API_SERVICE_KEY"] });
  expect(refused.status).not.toBe(0);
  expect(refused.read("gh-stdin")).toBeUndefined();
  const replaced = run({ worker: ["CLOUD_VM_API_SERVICE_KEY"], args: [...ARGS, "--replace-worker-secret"] });
  expect(replaced.status, replaced.stderr).toBe(0);
  expect(isApiKeyShaped(replaced.read("wrangler-stdin")!)).toBe(true);
});

it("refuses the admin scope and an entry with no labels", () => {
  expect(run({ args: [...ARGS, "--scopes", "vm:read,admin"] }).status).not.toBe(0);
  expect(run({ args: [...ARGS, "--labels", ""] }).status).not.toBe(0);
});
