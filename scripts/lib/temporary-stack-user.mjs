#!/usr/bin/env bun

import { randomBytes, randomUUID } from "node:crypto";
import {
  chmodSync,
  closeSync,
  constants,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const moduleDirectory = path.dirname(fileURLToPath(import.meta.url));
const webRequire = createRequire(path.join(moduleDirectory, "../../web/package.json"));

export function parseEnvFile(contents) {
  const result = {};
  for (const rawLine of contents.split(/\r?\n/u)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const equals = line.indexOf("=");
    if (equals <= 0) continue;
    const key = line.slice(0, equals).trim();
    let value = line.slice(equals + 1).trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      try {
        value = JSON.parse(value);
      } catch {
        value = value.slice(1, -1);
      }
    } else if (value.length >= 2 && value.startsWith("'") && value.endsWith("'")) {
      value = value.slice(1, -1);
    }
    result[key] = value;
  }
  return result;
}

function assertSecureDirectory(directory) {
  const absolute = path.resolve(directory);
  if (absolute !== directory) throw new Error("state directory must use an absolute normalized path");
  const metadata = lstatSync(directory);
  if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
    throw new Error("state directory must be a non-symlink directory");
  }
  if (metadata.uid !== process.getuid()) throw new Error("state directory must be owned by the current user");
  if ((metadata.mode & 0o077) !== 0) throw new Error("state directory must not grant group or world permissions");
}

export function assertSecureFile(file) {
  const absolute = path.resolve(file);
  if (absolute !== file) throw new Error("secret file must use an absolute normalized path");
  assertSecureDirectory(path.dirname(file));
  const metadata = lstatSync(file);
  if (!metadata.isFile() || metadata.isSymbolicLink()) {
    throw new Error("secret file must be a regular non-symlink file");
  }
  if (metadata.uid !== process.getuid()) throw new Error("secret file must be owned by the current user");
  if ((metadata.mode & 0o077) !== 0) throw new Error("secret file must not grant group or world permissions");
}

function writeExclusiveSecureFile(file, contents) {
  assertSecureDirectory(path.dirname(file));
  const descriptor = openSync(
    file,
    constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY | constants.O_NOFOLLOW,
    0o600,
  );
  try {
    writeFileSync(descriptor, contents, { encoding: "utf8" });
  } finally {
    closeSync(descriptor);
  }
  chmodSync(file, 0o600);
}

function replaceSecureFile(file, contents) {
  const temporary = `${file}.tmp-${process.pid}-${randomUUID()}`;
  writeExclusiveSecureFile(temporary, contents);
  renameSync(temporary, file);
}

function requiredValue(values, key) {
  const value = values[key]?.trim();
  if (!value) throw new Error(`production Stack environment is missing ${key}`);
  return value;
}

export function stackConfigurationFromEnvFile(environmentFile) {
  assertSecureFile(environmentFile);
  const values = parseEnvFile(readFileSync(environmentFile, "utf8"));
  return {
    projectId: requiredValue(values, "NEXT_PUBLIC_STACK_PROJECT_ID"),
    publishableClientKey: requiredValue(values, "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY"),
    secretServerKey: requiredValue(values, "STACK_SECRET_SERVER_KEY"),
  };
}

function loadStackServerApp(configuration) {
  const { StackServerApp } = webRequire("@stackframe/stack");
  return new StackServerApp(configuration);
}

function credentialFileContents(email, password) {
  return [
    `CMUX_UITEST_STACK_EMAIL=${JSON.stringify(email)}`,
    `CMUX_UITEST_STACK_PASSWORD=${JSON.stringify(password)}`,
    "",
  ].join("\n");
}

export async function createTemporaryStackUser({
  stackApp,
  stateFile,
  credentialsFile,
  now = () => new Date(),
}) {
  if (path.dirname(stateFile) !== path.dirname(credentialsFile)) {
    throw new Error("state and credentials files must share one protected directory");
  }
  assertSecureDirectory(path.dirname(stateFile));
  const email = `cmux-iroh-gate+${randomUUID()}@manaflow.ai`;
  const password = randomBytes(24).toString("base64url");
  let user;
  try {
    user = await stackApp.createUser({
      primaryEmail: email,
      primaryEmailVerified: true,
      primaryEmailAuthEnabled: true,
      password,
      displayName: "cmux Iroh production gate",
    });
    const initialState = {
      schemaVersion: 1,
      userId: user.id,
      email,
      password,
      accessToken: null,
      refreshToken: null,
      createdAt: now().toISOString(),
    };
    writeExclusiveSecureFile(stateFile, `${JSON.stringify(initialState)}\n`);

    const session = await user.createSession({
      expiresInMillis: 20 * 60 * 1000,
      isImpersonation: true,
    });
    const { accessToken, refreshToken } = await session.getTokens();
    if (!accessToken || !refreshToken) throw new Error("Stack did not return temporary session tokens");

    replaceSecureFile(stateFile, `${JSON.stringify({
      ...initialState,
      accessToken,
      refreshToken,
    })}\n`);
    writeExclusiveSecureFile(credentialsFile, credentialFileContents(email, password));
    return { created: true };
  } catch (error) {
    rmSync(credentialsFile, { force: true });
    let accountAbsent = user === undefined;
    if (user) {
      try {
        await user.delete();
        accountAbsent = (await stackApp.getUser(user.id)) === null;
      } catch {
        accountAbsent = false;
      }
    }
    if (accountAbsent) {
      rmSync(stateFile, { force: true });
    } else if (!statExists(stateFile) && user) {
      // Keep a minimal protected recovery record when account creation
      // succeeded but session creation (or the first state write) failed.
      // Cleanup can skip the unavailable account API tokens and still use the
      // Stack admin client to delete this exact user.
      writeExclusiveSecureFile(stateFile, `${JSON.stringify({
        schemaVersion: 1,
        userId: user.id,
        email,
        password,
        accessToken: null,
        refreshToken: null,
        createdAt: now().toISOString(),
      })}\n`);
    }
    throw error;
  }
}

function statExists(file) {
  try {
    lstatSync(file);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

function readState(stateFile) {
  assertSecureFile(stateFile);
  const state = JSON.parse(readFileSync(stateFile, "utf8"));
  for (const key of ["userId", "email", "password"]) {
    if (typeof state[key] !== "string" || state[key].length === 0) {
      throw new Error(`temporary Stack state is missing ${key}`);
    }
  }
  return state;
}

async function safeResponseErrorCode(response) {
  try {
    const body = await response.json();
    if (typeof body?.error !== "string") return null;
    const code = body.error.slice(0, 80);
    return /^[a-z0-9_-]+$/iu.test(code) ? code : "server_error";
  } catch {
    return null;
  }
}

function writeRecoveryReport(recoveryFile, report) {
  mkdirSync(path.dirname(recoveryFile), { recursive: true, mode: 0o700 });
  const parent = statSync(path.dirname(recoveryFile));
  if (parent.uid !== process.getuid() || (parent.mode & 0o022) !== 0) {
    throw new Error("cleanup report directory must be current-user-owned and non-writable by group/world");
  }
  rmSync(recoveryFile, { force: true });
  writeExclusiveSecureFile(recoveryFile, `${JSON.stringify(report, null, 2)}\n`);
}

export async function cleanupTemporaryStackUser({
  stackApp,
  stateFile,
  credentialsFile,
  recoveryFile,
  apiBaseURL,
  fetchImpl = fetch,
  now = () => new Date(),
}) {
  const state = readState(stateFile);
  let apiStatus = null;
  let apiErrorCode = null;
  let apiCleanupSucceeded = false;
  if (typeof state.accessToken === "string" && state.accessToken.length > 0
      && typeof state.refreshToken === "string" && state.refreshToken.length > 0) {
    try {
      const response = await fetchImpl(new URL("/api/account", apiBaseURL), {
        method: "DELETE",
        headers: {
          authorization: `Bearer ${state.accessToken}`,
          "x-stack-refresh-token": state.refreshToken,
        },
      });
      apiStatus = response.status;
      apiCleanupSucceeded = response.ok;
      if (!response.ok) apiErrorCode = await safeResponseErrorCode(response);
    } catch {
      apiErrorCode = "network_error";
    }
  } else {
    apiErrorCode = "temporary_session_unavailable";
  }

  let directCleanupAttempted = false;
  let directCleanupSucceeded = false;
  let accountAbsentAfterAPI = false;
  try {
    accountAbsentAfterAPI = (await stackApp.getUser(state.userId)) === null;
  } catch {
    accountAbsentAfterAPI = false;
  }
  let accountAbsent = accountAbsentAfterAPI;
  if (!accountAbsent) {
    directCleanupAttempted = true;
    try {
      const user = await stackApp.getUser(state.userId);
      if (user) await user.delete();
      accountAbsent = (await stackApp.getUser(state.userId)) === null;
      directCleanupSucceeded = accountAbsent;
    } catch {
      directCleanupSucceeded = false;
      accountAbsent = false;
    }
  }

  // Direct deletion is a hygiene fallback, not evidence that the production
  // account API worked. The release gate passes only when the API succeeded
  // and its deletion was independently observable before the fallback.
  const passed = apiCleanupSucceeded && accountAbsentAfterAPI;
  const report = {
    schemaVersion: 1,
    passed,
    apiCleanupSucceeded,
    apiStatus,
    apiErrorCode,
    directCleanupAttempted,
    directCleanupSucceeded,
    accountAbsentAfterAPI,
    accountAbsent,
    manualRecoveryRequired: !accountAbsent,
    completedAt: now().toISOString(),
  };
  writeRecoveryReport(recoveryFile, report);

  if (accountAbsent) {
    rmSync(credentialsFile, { force: true });
    rmSync(stateFile, { force: true });
  }
  return report;
}

function parsedArguments(argv) {
  const values = { command: argv[0] };
  for (let index = 1; index < argv.length; index += 2) {
    const option = argv[index];
    const value = argv[index + 1];
    if (!option?.startsWith("--") || !value) throw new Error(`invalid argument ${option ?? ""}`);
    values[option.slice(2)] = value;
  }
  return values;
}

async function main() {
  const args = parsedArguments(process.argv.slice(2));
  for (const key of ["environment-file", "state-file", "credentials-file"]) {
    if (!args[key]) throw new Error(`--${key} is required`);
  }
  const configuration = stackConfigurationFromEnvFile(args["environment-file"]);
  const stackApp = loadStackServerApp(configuration);

  if (args.command === "create") {
    const result = await createTemporaryStackUser({
      stackApp,
      stateFile: args["state-file"],
      credentialsFile: args["credentials-file"],
    });
    process.stdout.write(`${JSON.stringify(result)}\n`);
    return;
  }
  if (args.command === "cleanup") {
    if (!args["api-base-url"] || !args["recovery-file"]) {
      throw new Error("cleanup requires --api-base-url and --recovery-file");
    }
    const result = await cleanupTemporaryStackUser({
      stackApp,
      stateFile: args["state-file"],
      credentialsFile: args["credentials-file"],
      recoveryFile: args["recovery-file"],
      apiBaseURL: args["api-base-url"],
    });
    process.stdout.write(`${JSON.stringify(result)}\n`);
    if (!result.passed) process.exitCode = 1;
    return;
  }
  throw new Error("command must be create or cleanup");
}

if (import.meta.main) {
  main().catch(() => {
    // Stack SDK errors can echo request fields. Keep command-line logs free of
    // the temporary account identity, password, and tokens; recovery details
    // live only in the protected state/report files.
    process.stderr.write("error: temporary Stack user operation failed; inspect the protected recovery state\n");
    process.exitCode = 1;
  });
}
