import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  projects,
  requiredRuntimeEnvKeys,
  withLinkedVercelProject,
} from "./projects.mjs";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const webDir = path.resolve(scriptDir, "../..");
const auditScript = path.join(scriptDir, "audit-vercel-env.mjs");
const freestyleRequiredKeys = [
  "CMUX_VM_FREESTYLE_ENABLED",
  "FREESTYLE_API_KEY",
];

function renderEnv(values) {
  return Object.entries(values)
    .map(([key, value]) => `${key}=${JSON.stringify(value)}`)
    .join("\n");
}

function runStrictAudit(values, { failBeforeCapture = false } = {}) {
  const fixtureDir = mkdtempSync(path.join(tmpdir(), "cmux-cloud-vm-audit-test-"));
  const fakeVercel = path.join(fixtureDir, "vercel");
  const capturePath = path.join(fixtureDir, "pulled-env-path.txt");
  const fakeVercelScript = failBeforeCapture
    ? `#!/bin/sh
set -eu
echo "fake Vercel failed before env capture" >&2
exit 71
`
    : `#!/bin/sh
set -eu
if [ "$1" = "env" ] && [ "$2" = "ls" ]; then
  printf '%s\n' '{"envs": []}'
  exit 0
fi
if [ "$1" != "env" ] || [ "$2" != "pull" ]; then
  echo "unexpected fake Vercel command" >&2
  exit 64
fi
printf '%s' "$3" > "$FAKE_VERCEL_CAPTURE_PATH"
printf '%s\n' "$FAKE_VERCEL_ENV_CONTENT" > "$3"
`;
  writeFileSync(
    fakeVercel,
    fakeVercelScript,
  );
  chmodSync(fakeVercel, 0o755);

  try {
    const result = spawnSync(process.execPath, [auditScript, "staging", "--strict"], {
      cwd: webDir,
      encoding: "utf8",
      env: {
        ...process.env,
        VERCEL_CLI: fakeVercel,
        FAKE_VERCEL_CAPTURE_PATH: capturePath,
        FAKE_VERCEL_ENV_CONTENT: renderEnv(values),
      },
    });
    const pulledEnvPath = existsSync(capturePath) ? readFileSync(capturePath, "utf8") : undefined;
    return { ...result, pulledEnvPath };
  } finally {
    rmSync(fixtureDir, { recursive: true, force: true });
  }
}

describe("Cloud VM environment audit", () => {
  test("strict audit requires Freestyle key names without printing secret values", () => {
    const configured = Object.fromEntries(
      requiredRuntimeEnvKeys
        .filter((key) => !freestyleRequiredKeys.includes(key))
        .map((key, index) => [key, `audit-secret-${index}-${key}`]),
    );
    configured.CMUX_VM_DEFAULT_PROVIDER = "freestyle";
    configured.STACK_SECRET_SERVER_KEY = "strict-audit-secret-sentinel";

    const result = runStrictAudit(configured);

    expect(result.status).toBe(1);
    expect(result.stderr).toBe("");
    const report = JSON.parse(result.stdout);
    expect(report.ok).toBe(false);
    expect([...report.missingRequired].sort()).toEqual([...freestyleRequiredKeys].sort());
    for (const value of Object.values(configured).filter((value) => value.startsWith("audit-secret-") || value === "strict-audit-secret-sentinel")) {
      expect(result.stdout).not.toContain(value);
      expect(result.stderr).not.toContain(value);
    }
    expect(existsSync(result.pulledEnvPath)).toBe(false);
    expect(existsSync(path.dirname(result.pulledEnvPath))).toBe(false);
  });

  test("linked Vercel scratch data is removed when an operation fails", () => {
    let scratch;
    expect(() =>
      withLinkedVercelProject(projects.staging, (candidate) => {
        scratch = candidate;
        expect(existsSync(path.join(candidate, ".vercel", "project.json"))).toBe(true);
        throw new Error("fixture failure");
      }),
    ).toThrow("fixture failure");
    expect(scratch).toBeDefined();
    expect(existsSync(scratch)).toBe(false);
  });

  test("audit preserves child diagnostics when env capture is missing", () => {
    const result = runStrictAudit({}, { failBeforeCapture: true });

    expect(result.status).toBe(1);
    expect(result.pulledEnvPath).toBeUndefined();
    expect(result.stdout).toBe("");
    expect(result.stderr).toContain("fake Vercel failed before env capture");
  });
});
