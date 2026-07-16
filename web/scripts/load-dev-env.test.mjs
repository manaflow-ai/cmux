import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const scriptPath = fileURLToPath(new URL("./load-dev-env.sh", import.meta.url));

function sourceDevEnv({
  downloadedKeyID = "",
  inheritedPrivateKey = "",
  keyFileContents,
}) {
  const home = mkdtempSync(path.join(tmpdir(), "cmux-load-dev-env-"));
  const secrets = path.join(home, ".secrets");
  const envFile = path.join(secrets, "cmuxterm-dev.env");
  const keyFile = path.join(
    secrets,
    "cmux-staging-relay-policy-2026-08.pem",
  );
  mkdirSync(secrets, { recursive: true });
  writeFileSync(
    envFile,
    [
      `CMUX_RELAY_POLICY_KEY_ID=${downloadedKeyID}`,
      "CMUX_RELAY_POLICY_PRIVATE_KEY_PEM=",
      "",
    ].join("\n"),
    { mode: 0o600 },
  );
  writeFileSync(keyFile, keyFileContents, { mode: 0o600 });

  try {
    return execFileSync(
      "bash",
      [
        "-c",
        `source "$1"; printf '%s\\0%s' "\${CMUX_RELAY_POLICY_KEY_ID-}" "\${CMUX_RELAY_POLICY_PRIVATE_KEY_PEM-}"`,
        "bash",
        scriptPath,
      ],
      {
        encoding: "utf8",
        env: {
          ...process.env,
          HOME: home,
          CMUXTERM_ENV_FILE: envFile,
          CMUX_RELAY_POLICY_KEY_ID: "",
          CMUX_RELAY_POLICY_PRIVATE_KEY_PEM: inheritedPrivateKey,
        },
      },
    ).split("\0");
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
}

test("blank downloaded relay secret falls back to the protected local key", () => {
  const privateKey = "-----BEGIN PRIVATE KEY-----\nlocal-dev\n-----END PRIVATE KEY-----\n";
  const [keyID, loadedPrivateKey] = sourceDevEnv({
    keyFileContents: privateKey,
  });

  assert.equal(keyID, "cmux-staging-relay-policy-2026-08");
  assert.equal(loadedPrivateKey, privateKey.trimEnd());
});

test("local fallback key replaces a stale downloaded key id", () => {
  const privateKey = "-----BEGIN PRIVATE KEY-----\nlocal-dev\n-----END PRIVATE KEY-----\n";
  const [keyID, loadedPrivateKey] = sourceDevEnv({
    downloadedKeyID: "cmux-staging-relay-policy-2026-07",
    keyFileContents: privateKey,
  });

  assert.equal(keyID, "cmux-staging-relay-policy-2026-08");
  assert.equal(loadedPrivateKey, privateKey.trimEnd());
});
