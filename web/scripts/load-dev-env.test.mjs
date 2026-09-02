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
  downloadedPrivateKey = "",
  keyFileContents = "",
  localKeyID = "",
  providerFileContents = "",
  extraFileContents = "",
}) {
  const home = mkdtempSync(path.join(tmpdir(), "cmux-load-dev-env-"));
  const secrets = path.join(home, ".secrets");
  const envFile = path.join(secrets, "cmuxterm-dev.env");
  const providerFile = path.join(secrets, "cmux.env");
  const extraFile = path.join(secrets, "extra.env");
  const keyFile = path.join(
    secrets,
    "cmux-staging-relay-policy-2026-08.pem",
  );
  mkdirSync(secrets, { recursive: true });
  writeFileSync(
    envFile,
    [
      `CMUX_RELAY_POLICY_KEY_ID=${downloadedKeyID}`,
      `CMUX_RELAY_POLICY_PRIVATE_KEY_PEM=${downloadedPrivateKey}`,
      "",
    ].join("\n"),
    { mode: 0o600 },
  );
  writeFileSync(keyFile, keyFileContents, { mode: 0o600 });
  if (providerFileContents) {
    writeFileSync(providerFile, providerFileContents, { mode: 0o600 });
  }
  if (extraFileContents) {
    writeFileSync(extraFile, extraFileContents, { mode: 0o600 });
  }

  try {
    return execFileSync(
      "bash",
      [
        "-c",
        `source "$1"; printf '%s\\0%s\\0%s\\0%s\\0%s' "\${CMUX_RELAY_POLICY_KEY_ID-}" "\${CMUX_RELAY_POLICY_PRIVATE_KEY_PEM-}" "\${FREESTYLE_API_KEY-}" "\${FREESTYLE_SANDBOX_SNAPSHOT-}" "\${CMUX_VM_DEFAULT_PROVIDER-}"`,
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
          CMUX_RELAY_POLICY_PRIVATE_KEY_PEM: "",
          CMUX_RELAY_POLICY_LOCAL_KEY_ID: localKeyID,
          CMUX_VM_DEFAULT_PROVIDER: "",
          CMUXTERM_EXTRA_ENV_FILE: extraFileContents ? extraFile : "",
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

test("complete downloaded key pair remains coupled", () => {
  const downloadedPrivateKey = "downloaded-private-key";
  const [keyID, loadedPrivateKey] = sourceDevEnv({
    downloadedKeyID: "downloaded-key-id",
    downloadedPrivateKey,
    keyFileContents: "local-private-key",
  });

  assert.equal(keyID, "downloaded-key-id");
  assert.equal(loadedPrivateKey, downloadedPrivateKey);
});

test("custom local fallback key id remains coupled to its private key", () => {
  const privateKey = "custom-local-private-key";
  const [keyID, loadedPrivateKey] = sourceDevEnv({
    downloadedKeyID: "stale-downloaded-key-id",
    keyFileContents: privateKey,
    localKeyID: "custom-local-key-id",
  });

  assert.equal(keyID, "custom-local-key-id");
  assert.equal(loadedPrivateKey, privateKey);
});

test("loads Freestyle credentials from the generic provider file", () => {
  const [, , apiKey, snapshot, provider] = sourceDevEnv({
    providerFileContents: "FREESTYLE_API_KEY=local-freestyle-key\nFREESTYLE_SANDBOX_SNAPSHOT=sh-local\n",
  });

  assert.equal(apiKey, "local-freestyle-key");
  assert.equal(snapshot, "sh-local");
  assert.equal(provider, "freestyle");
});

test("loads an explicitly selected provider from the extra environment file", () => {
  const [, , apiKey, , provider] = sourceDevEnv({
    extraFileContents: "FREESTYLE_API_KEY=explicit-freestyle-key\nCMUX_VM_DEFAULT_PROVIDER=e2b\n",
  });

  assert.equal(apiKey, "explicit-freestyle-key");
  assert.equal(provider, "e2b");
});
