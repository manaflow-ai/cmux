import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

export const projects = {
  staging: {
    projectId: "prj_804LTAUdOwulMvEfcmfnU8bvGo3T",
    orgId: "team_KndpHsJ15gO2OoAP2SO0thYn",
    projectName: "cmux-staging",
    label: "staging",
    url: "https://cmux-staging.vercel.app",
    stackLabel: "staging",
  },
  production: {
    projectId: "prj_kH8qcuoliyJ2TLI4vMM03rnNVzr4",
    orgId: "team_KndpHsJ15gO2OoAP2SO0thYn",
    projectName: "cmux",
    label: "production",
    url: "https://cmux.com",
    stackLabel: "prod",
  },
};

export const requiredRuntimeEnvKeys = [
  "AWS_REGION",
  "AWS_ROLE_ARN",
  // Without the Slack sink every triggered VM alert drops silently while the
  // alert cron keeps returning 200, so an unset webhook is an observability
  // outage, not a tuning choice. The only waiver is a recorded operator
  // decision in the env itself (alertSinkAudit.mjs).
  "CMUX_ALERTS_SLACK_WEBHOOK_URL",
  // The application can build without APNs credentials, but a promoted
  // runtime cannot deliver the Push Alerts feature without the complete set.
  "CMUX_APNS_KEY_ID",
  "CMUX_APNS_KEY_P8",
  "CMUX_APNS_TEAM_ID",
  "CMUX_DB_DRIVER",
  "CMUX_VM_CREATE_ENABLED",
  "CMUX_VM_DEFAULT_PROVIDER",
  // Freestyle is the production default provider (CMUX_VM_DEFAULT_PROVIDER):
  // without credentials and a snapshot selector every create 503s.
  "CMUX_VM_FREESTYLE_ENABLED",
  // Every Vercel cron (VM alerts included) refuses to run without it.
  "CRON_SECRET",
  "FREESTYLE_API_KEY",
  "NEXT_PUBLIC_STACK_PROJECT_ID",
  "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY",
  "PGDATABASE",
  "PGHOST",
  "PGPORT",
  "PGUSER",
  "STACK_SECRET_SERVER_KEY",
];

export const recommendedRuntimeEnvKeys = [
  "CMUX_DB_POOL_MAX",
  // Kill switches are off-only: unset means enabled, so requiring presence
  // would fail a healthy deployment. Freestyle's own flag is required rather
  // than recommended because it is the only provider, so a missing value there
  // is a real outage risk.
  // CMUX_VM_ALLOW_FREE_PROVISIONING / CMUX_VM_REQUIRE_PRO are deliberately
  // absent from every presence list: unset is the safe value, and their
  // VALUES are audited by freeProvisioningAudit.mjs (a permissive value fails).
  // CMUX_ALERTS_SINK_UNCONFIGURED_ACK is absent for the same reason; its VALUE
  // is audited by alertSinkAudit.mjs.
  "CMUX_DB_SSL_REJECT_UNAUTHORIZED",
  "OTEL_EXPORTER_OTLP_ENDPOINT",
  "OTEL_EXPORTER_OTLP_HEADERS",
  "OTEL_SERVICE_NAME",
];

export const forbiddenRuntimeEnvKeys = [
  "CMUX_DB_SSL_CA_PEM",
  "CMUX_DB_SSL_CA_PEM_BASE64",
];

export const legacyCloudVmEnvKeys = [
  // Blaxel, E2B, and Daytona were removed by the provider migrations. Keep
  // their keys visible to the audit until operators remove them from Vercel.
  "BL_API_KEY",
  "BL_WORKSPACE",
  "BLAXEL_SANDBOX_IMAGE",
  "BLAXEL_SANDBOX_DESKTOP_IMAGE",
  "CMUX_VM_BLAXEL_ENABLED",
  "E2B_API_KEY",
  "E2B_CMUXD_WS_TEMPLATE",
  "E2B_SANDBOX_TEMPLATE",
  "CMUX_VM_E2B_ENABLED",
  "DAYTONA_API_KEY",
  "DAYTONA_API_URL",
  "DAYTONA_SANDBOX_SNAPSHOT",
  "CMUX_VM_DAYTONA_ENABLED",
  "CMUX_RIVET_INTERNAL_SECRET",
  "RIVET_ENDPOINT",
  "RIVET_NAMESPACE",
  "RIVET_PUBLIC_ENDPOINT",
  "RIVET_RUNNER_VERSION",
  "RIVET_TOKEN",
  // Subrouter and coderouter access gates were removed: team membership is
  // the only requirement. The runtime ignores these keys; delete them.
  "SUBROUTER_ENFORCE_STACK_PERMISSIONS",
  "SUBROUTER_ALLOWED_TEAM_IDS",
  "CODEROUTER_HOSTED_PRO_REQUIRED",
];

export function normalizeTarget(value) {
  if (value === "prod") return "production";
  return value;
}

export function resolveProject(targetArg, usage) {
  const target = normalizeTarget(targetArg);
  const project = projects[target];
  if (!project) {
    console.error(usage);
    process.exit(2);
  }
  return { target, project };
}

export function parseWebDirAndTarget(args, usage) {
  const first = args[0];
  if (first === "staging" || first === "production" || first === "prod") {
    return { webDir: resolveWebDir("."), ...resolveProject(first, usage), rest: args.slice(1) };
  }
  return {
    webDir: resolveWebDir(first ?? "."),
    ...resolveProject(args[1], usage),
    rest: args.slice(2),
  };
}

export function resolveWebDir(input) {
  let webDir = path.resolve(input);
  const nestedWebDir = path.join(webDir, "web");
  if (existsPackageJson(nestedWebDir)) {
    webDir = nestedWebDir;
  } else if (!existsPackageJson(webDir)) {
    console.error("Could not find web/package.json. Pass the web directory as the first argument.");
    process.exit(2);
  }
  return webDir;
}

export function withLinkedVercelProject(project, fn) {
  const scratch = mkdtempSync(path.join(tmpdir(), `cmux-${project.label}-vercel-`));
  try {
    const vercelDir = path.join(scratch, ".vercel");
    mkdirSync(vercelDir, { recursive: true });
    writeFileSync(path.join(vercelDir, "project.json"), JSON.stringify(project));
    return fn(scratch);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

export function pullProductionEnv(project) {
  return withLinkedVercelProject(project, (scratch) => {
    const envFile = path.join(scratch, `${project.projectName}.env`);
    runVercel(["env", "pull", envFile, "--environment=production", "--scope", "manaflow", "--cwd", scratch], {
      stdio: ["ignore", "pipe", "inherit"],
    });
    return loadEnv(envFile);
  });
}

export function loadTargetEnv(project) {
  const source = process.env.CMUX_CLOUD_VM_ENV_SOURCE ?? "vercel";
  if (source === "vercel") return pullProductionEnv(project);
  if (source === "process") return processEnvObject();
  throw new Error(`Unknown CMUX_CLOUD_VM_ENV_SOURCE ${source}`);
}

export function requireEnvKeys(env, keys, label) {
  const missing = keys.filter((key) => !env[key]);
  if (missing.length > 0) throw new Error(`${label} missing env keys: ${missing.join(", ")}`);
}

export function runVercel(args, options = {}) {
  const stdio = options.stdio ?? "inherit";
  // The Vercel CLI reads VERCEL_TOKEN from the environment, so CI needs no
  // --token in argv (argv leaks into process listings and thrown errors).
  const env = { ...process.env, ...options.env };
  const command = process.env.VERCEL_CLI;
  if (command) return execFileSync(command, args, { ...options, env, stdio });
  try {
    return execFileSync("vercel", args, { ...options, env, stdio });
  } catch (error) {
    if (error && error.code === "ENOENT") {
      return execFileSync("bunx", ["vercel", ...args], { ...options, env, stdio });
    }
    throw error;
  }
}

export function loadEnv(file) {
  const env = {};
  for (const raw of readFileSync(file, "utf8").split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq < 0) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    env[key] = value;
  }
  return env;
}

export function optionValue(values, name) {
  const index = values.indexOf(name);
  if (index < 0) return undefined;
  return values[index + 1];
}

export function parseBoolean(value, fallback) {
  if (!value) return fallback;
  const normalized = value.trim().toLowerCase();
  if (["1", "true", "yes", "on"].includes(normalized)) return true;
  if (["0", "false", "no", "off"].includes(normalized)) return false;
  throw new Error("expected boolean value");
}

function existsPackageJson(dir) {
  try {
    readFileSync(path.join(dir, "package.json"));
    return true;
  } catch {
    return false;
  }
}

function processEnvObject() {
  const env = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (value !== undefined) env[key] = value;
  }
  return env;
}
