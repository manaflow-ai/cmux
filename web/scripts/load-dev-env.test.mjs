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

test("loads an explicitly selected Freestyle provider from the extra environment file", () => {
  const [, , apiKey, , provider] = sourceDevEnv({
    extraFileContents: "FREESTYLE_API_KEY=explicit-freestyle-key\nCMUX_VM_DEFAULT_PROVIDER=freestyle\n",
  });

  assert.equal(apiKey, "explicit-freestyle-key");
  assert.equal(provider, "freestyle");
});

function sourcedNetworkNamespace(env) {
  const home = mkdtempSync(path.join(tmpdir(), "cmux-load-dev-env-ns-"));
  const secrets = path.join(home, ".secrets");
  const envFile = path.join(secrets, "cmuxterm-dev.env");
  mkdirSync(secrets, { recursive: true });
  writeFileSync(envFile, "", { mode: 0o600 });
  const inherited = { ...process.env };
  delete inherited.CMUX_VM_NETWORK_NAMESPACE;
  delete inherited.DATABASE_URL;
  delete inherited.CMUX_DEV_USE_EXTERNAL_DATABASE_URL;
  try {
    return execFileSync(
      "bash",
      ["-c", `source "$1"; printf '%s:%s' "\${CMUX_VM_NETWORK_NAMESPACE+set}" "\${CMUX_VM_NETWORK_NAMESPACE-}"`, "bash", scriptPath],
      {
        encoding: "utf8",
        env: { ...inherited, HOME: home, CMUXTERM_ENV_FILE: envFile, CMUXTERM_EXTRA_ENV_FILE: "", ...env },
      },
    );
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
}

test("each dev database gets its own Cloud network namespace", () => {
  const stackA = sourcedNetworkNamespace({
    CMUX_DEV_USE_EXTERNAL_DATABASE_URL: "1",
    DATABASE_URL: "postgres://cmux:stack-a-password@postgres:5432/cmux",
  });
  const stackB = sourcedNetworkNamespace({
    CMUX_DEV_USE_EXTERNAL_DATABASE_URL: "1",
    DATABASE_URL: "postgres://cmux:stack-b-password@postgres:5432/cmux",
  });
  const local = sourcedNetworkNamespace({ CMUX_PORT: "3811" });
  for (const value of [stackA, stackB, local]) {
    assert.match(value, /^set:dev-[0-9a-f]{10}$/);
  }
  assert.notEqual(stackA, stackB);
  assert.notEqual(stackA, local);
  assert.equal(stackA, sourcedNetworkNamespace({
    CMUX_DEV_USE_EXTERNAL_DATABASE_URL: "1",
    DATABASE_URL: "postgres://cmux:stack-a-password@postgres:5432/cmux",
  }));
  assert.equal(stackA.includes("stack-a-password"), false);
});

test("an explicit Cloud network namespace, even empty, is kept", () => {
  assert.equal(sourcedNetworkNamespace({ CMUX_VM_NETWORK_NAMESPACE: "staging" }), "set:staging");
  assert.equal(sourcedNetworkNamespace({ CMUX_VM_NETWORK_NAMESPACE: "" }), "set:");
});
