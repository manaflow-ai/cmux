import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  assertSecureFile,
  cleanupTemporaryStackUser,
  createTemporaryStackUser,
  parseEnvFile,
} from "./temporary-stack-user.mjs";

function fixtureDirectory() {
  const directory = mkdtempSync(path.join(os.tmpdir(), "cmux-stack-user-test-"));
  chmodSync(directory, 0o700);
  return directory;
}

function temporaryUser(id = "user-1") {
  return {
    id,
    async createSession() {
      return {
        async getTokens() {
          return { accessToken: "access-token", refreshToken: "refresh-token" };
        },
      };
    },
    async delete() {},
  };
}

test("parseEnvFile handles Vercel-style quoted values", () => {
  assert.deepEqual(parseEnvFile('A="one\\ntwo"\nB=plain\nC=\'single\'\n'), {
    A: "one\ntwo",
    B: "plain",
    C: "single",
  });
});

test("create writes only protected state and credential files", async (t) => {
  const directory = fixtureDirectory();
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const stateFile = path.join(directory, "account.json");
  const credentialsFile = path.join(directory, "credentials.env");
  const user = temporaryUser();
  const stackApp = {
    async createUser(options) {
      assert.equal(options.primaryEmailVerified, true);
      assert.equal(options.primaryEmailAuthEnabled, true);
      assert.match(options.primaryEmail, /^cmux-iroh-gate\+/u);
      return user;
    },
  };

  assert.deepEqual(await createTemporaryStackUser({ stackApp, stateFile, credentialsFile }), {
    created: true,
  });
  assert.doesNotThrow(() => assertSecureFile(stateFile));
  assert.doesNotThrow(() => assertSecureFile(credentialsFile));
  const credentials = readFileSync(credentialsFile, "utf8");
  assert.match(credentials, /CMUX_UITEST_STACK_EMAIL=/u);
  assert.match(credentials, /CMUX_UITEST_STACK_PASSWORD=/u);
  assert.doesNotMatch(credentials, /access-token|refresh-token/u);
});

test("cleanup API failure deletes directly but keeps the gate red", async (t) => {
  const directory = fixtureDirectory();
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const stateFile = path.join(directory, "account.json");
  const credentialsFile = path.join(directory, "credentials.env");
  const recoveryDirectory = path.join(directory, "recovery");
  const recoveryFile = path.join(recoveryDirectory, "cleanup.json");
  chmodSync(directory, 0o700);
  const user = temporaryUser();
  let present = true;
  user.delete = async () => { present = false; };
  const stackApp = {
    async createUser() { return user; },
    async getUser() { return present ? user : null; },
  };
  await createTemporaryStackUser({ stackApp, stateFile, credentialsFile });

  const result = await cleanupTemporaryStackUser({
    stackApp,
    stateFile,
    credentialsFile,
    recoveryFile,
    apiBaseURL: "https://cmux.com",
    fetchImpl: async () => new Response(JSON.stringify({ error: "account_delete_failed" }), {
      status: 500,
      headers: { "content-type": "application/json" },
    }),
  });

  assert.equal(result.passed, false);
  assert.equal(result.apiStatus, 500);
  assert.equal(result.apiErrorCode, "account_delete_failed");
  assert.equal(result.accountAbsentAfterAPI, false);
  assert.equal(result.directCleanupSucceeded, true);
  assert.equal(result.accountAbsent, true);
  assert.equal(result.manualRecoveryRequired, false);
  assert.doesNotMatch(readFileSync(recoveryFile, "utf8"), /access-token|refresh-token|@manaflow/u);
  assert.throws(() => readFileSync(stateFile));
  assert.throws(() => readFileSync(credentialsFile));
});

test("cleanup stays red when a successful API response did not delete the account", async (t) => {
  const directory = fixtureDirectory();
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const stateFile = path.join(directory, "account.json");
  const credentialsFile = path.join(directory, "credentials.env");
  const recoveryFile = path.join(directory, "cleanup.json");
  const user = temporaryUser();
  let present = true;
  user.delete = async () => { present = false; };
  const stackApp = {
    async createUser() { return user; },
    async getUser() { return present ? user : null; },
  };
  await createTemporaryStackUser({ stackApp, stateFile, credentialsFile });

  const result = await cleanupTemporaryStackUser({
    stackApp,
    stateFile,
    credentialsFile,
    recoveryFile,
    apiBaseURL: "https://cmux.com",
    fetchImpl: async () => new Response(null, { status: 204 }),
  });

  assert.equal(result.apiCleanupSucceeded, true);
  assert.equal(result.accountAbsentAfterAPI, false);
  assert.equal(result.directCleanupSucceeded, true);
  assert.equal(result.accountAbsent, true);
  assert.equal(result.passed, false);
});

test("cleanup report replaces unstructured server errors with a safe code", async (t) => {
  const directory = fixtureDirectory();
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const stateFile = path.join(directory, "account.json");
  const credentialsFile = path.join(directory, "credentials.env");
  const recoveryFile = path.join(directory, "cleanup.json");
  const user = temporaryUser();
  let present = true;
  user.delete = async () => { present = false; };
  const stackApp = {
    async createUser() { return user; },
    async getUser() { return present ? user : null; },
  };
  await createTemporaryStackUser({ stackApp, stateFile, credentialsFile });

  const result = await cleanupTemporaryStackUser({
    stackApp,
    stateFile,
    credentialsFile,
    recoveryFile,
    apiBaseURL: "https://cmux.com",
    fetchImpl: async () => new Response(JSON.stringify({
      error: "deletion failed for temporary@example.com with token secret",
    }), {
      status: 500,
      headers: { "content-type": "application/json" },
    }),
  });

  assert.equal(result.apiErrorCode, "server_error");
  assert.doesNotMatch(readFileSync(recoveryFile, "utf8"), /temporary@example|token secret/u);
});

test("failed session creation preserves a direct-cleanup recovery record", async (t) => {
  const directory = fixtureDirectory();
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const stateFile = path.join(directory, "account.json");
  const credentialsFile = path.join(directory, "credentials.env");
  const recoveryFile = path.join(directory, "cleanup.json");
  const user = temporaryUser();
  user.createSession = async () => { throw new Error("session unavailable"); };
  user.delete = async () => { throw new Error("delete unavailable"); };
  const stackApp = {
    async createUser() { return user; },
    async getUser() { return user; },
  };

  await assert.rejects(
    createTemporaryStackUser({ stackApp, stateFile, credentialsFile }),
    /session unavailable/u,
  );
  assert.doesNotThrow(() => assertSecureFile(stateFile));

  const result = await cleanupTemporaryStackUser({
    stackApp,
    stateFile,
    credentialsFile,
    recoveryFile,
    apiBaseURL: "https://cmux.com",
    fetchImpl: async () => { throw new Error("must not call account API without tokens"); },
  });
  assert.equal(result.apiErrorCode, "temporary_session_unavailable");
  assert.equal(result.manualRecoveryRequired, true);
  assert.doesNotThrow(() => assertSecureFile(stateFile));
});

test("cleanup preserves per-user recovery state when direct deletion fails", async (t) => {
  const directory = fixtureDirectory();
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const stateFile = path.join(directory, "account.json");
  const credentialsFile = path.join(directory, "credentials.env");
  const recoveryFile = path.join(directory, "cleanup.json");
  const user = temporaryUser();
  user.delete = async () => { throw new Error("unavailable"); };
  const stackApp = {
    async createUser() { return user; },
    async getUser() { return user; },
  };
  await createTemporaryStackUser({ stackApp, stateFile, credentialsFile });

  const result = await cleanupTemporaryStackUser({
    stackApp,
    stateFile,
    credentialsFile,
    recoveryFile,
    apiBaseURL: "https://cmux.com",
    fetchImpl: async () => { throw new Error("offline"); },
  });

  assert.equal(result.passed, false);
  assert.equal(result.accountAbsent, false);
  assert.equal(result.manualRecoveryRequired, true);
  assert.doesNotThrow(() => assertSecureFile(stateFile));
  assert.doesNotThrow(() => assertSecureFile(credentialsFile));
});

test("secure-file validation rejects group-readable credentials", (t) => {
  const directory = fixtureDirectory();
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const file = path.join(directory, "credentials.env");
  writeFileSync(file, "secret", { mode: 0o640 });
  chmodSync(file, 0o640);
  assert.throws(() => assertSecureFile(file), /group or world/u);
});
