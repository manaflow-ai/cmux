#!/usr/bin/env bun
/**
 * Setup script for local Convex development.
 *
 * This script:
 * 1. Cleans up any existing convex processes
 * 2. Starts a local Convex deployment
 * 3. Sets ALL environment variables from .env to Convex
 * 4. Runs the seed command
 * 5. Kills the dev process once setup is complete
 */

import { spawn, spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

const ROOT_DIR = path.resolve(import.meta.dirname, "../../..");
const CONVEX_DIR = path.resolve(import.meta.dirname, "..");
const ENV_FILE = path.join(ROOT_DIR, ".env");
const CONVEX_ENV_LOCAL = path.join(CONVEX_DIR, ".env.local");
const CONVEX_STATE_DIR = path.join(
  os.homedir(),
  ".convex",
  "anonymous-convex-backend-state"
);

const VERBOSE = process.argv.includes("--verbose");

function log(msg: string) {
  console.log(msg);
}

function logVerbose(msg: string) {
  if (VERBOSE) {
    console.log(`   ${msg}`);
  }
}

function logCmd(cmd: string, args: string[]) {
  if (VERBOSE) {
    console.log(`   $ ${cmd} ${args.join(" ")}`);
  }
}

function cleanupConvexProcesses() {
  logVerbose("Cleaning up existing Convex processes...");
  logCmd("pkill", ["-9", "-f", "convex-local-backend"]);
  spawnSync("pkill", ["-9", "-f", "convex-local-backend"], { stdio: "ignore" });
  logCmd("pkill", ["-9", "-f", "convex dev"]);
  spawnSync("pkill", ["-9", "-f", "convex dev"], { stdio: "ignore" });
  spawnSync("sleep", ["1"]);
}

function cleanupConvexState() {
  logVerbose("Cleaning up old Convex state...");
  if (fs.existsSync(CONVEX_STATE_DIR)) {
    fs.rmSync(CONVEX_STATE_DIR, { recursive: true, force: true });
  }
}

function parseEnvFile(filePath: string): Record<string, string> {
  const content = fs.readFileSync(filePath, "utf-8");
  const env: Record<string, string> = {};

  let currentKey: string | null = null;
  let currentValue: string[] = [];
  let inMultiline = false;

  for (const line of content.split("\n")) {
    if (inMultiline) {
      currentValue.push(line);
      if (line.endsWith('"') && !line.endsWith('\\"')) {
        env[currentKey!] = currentValue.join("\n").slice(0, -1);
        inMultiline = false;
        currentKey = null;
        currentValue = [];
      }
    } else {
      const match = line.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
      if (match) {
        const [, key, rawValue] = match;
        if (rawValue.startsWith('"') && !rawValue.endsWith('"')) {
          currentKey = key;
          currentValue = [rawValue.slice(1)];
          inMultiline = true;
        } else {
          let value = rawValue;
          if (value.startsWith('"') && value.endsWith('"')) {
            value = value.slice(1, -1);
          }
          env[key] = value;
        }
      }
    }
  }

  return env;
}

async function setEnvVar(key: string, value: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const proc = spawn("bunx", ["convex", "env", "set", key, "--", value], {
      cwd: CONVEX_DIR,
      stdio: ["pipe", "pipe", "pipe"],
    });

    let stderr = "";
    proc.stderr.on("data", (data) => {
      stderr += data.toString();
    });

    proc.on("close", (code) => {
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(`Failed to set ${key}: ${stderr}`));
      }
    });
  });
}

function spinner(frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]) {
  let i = 0;
  return () => frames[i++ % frames.length];
}

async function withSpinner<T>(
  message: string,
  fn: () => Promise<T>
): Promise<T> {
  const spin = spinner();
  const interval = setInterval(() => {
    process.stdout.write(`\r${spin()} ${message}`);
  }, 80);

  try {
    const result = await fn();
    clearInterval(interval);
    process.stdout.write(`\r✓ ${message}\n`);
    return result;
  } catch (error) {
    clearInterval(interval);
    process.stdout.write(`\r✗ ${message}\n`);
    throw error;
  }
}

async function main() {
  log("Setting up local Convex deployment...\n");

  cleanupConvexProcesses();
  cleanupConvexState();

  // Required env vars for seed to work (Stack Auth)
  const requiredEnvVars = [
    "NEXT_PUBLIC_STACK_PROJECT_ID",
    "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY",
    "STACK_SECRET_SERVER_KEY",
    "STACK_SUPER_SECRET_ADMIN_KEY",
  ];

  const missingEnvVars = requiredEnvVars.filter((key) => !process.env[key]);
  if (missingEnvVars.length > 0) {
    console.error(
      `✗ Missing required environment variables:\n  ${missingEnvVars.join("\n  ")}`
    );
    console.error(
      "\nMake sure these are set in your environment or .env file"
    );
    process.exit(1);
  }

  // Collect env vars to sync from .env file if it exists, otherwise from process.env
  const optionalEnvVars = ["MORPH_API_KEY"];
  let envVarsToSync: [string, string][];

  if (fs.existsSync(ENV_FILE)) {
    const envVars = parseEnvFile(ENV_FILE);
    envVarsToSync = Object.entries(envVars);
  } else {
    // Fall back to process.env for required + optional vars
    const allEnvVars = [...requiredEnvVars, ...optionalEnvVars];
    envVarsToSync = allEnvVars
      .filter((key) => process.env[key])
      .map((key) => [key, process.env[key]!]);
  }

  if (fs.existsSync(CONVEX_ENV_LOCAL)) {
    logVerbose(`Removing ${CONVEX_ENV_LOCAL}`);
    fs.unlinkSync(CONVEX_ENV_LOCAL);
  }

  const devArgs = [
    "convex",
    "dev",
    "--configure",
    "new",
    "--dev-deployment",
    "local",
    "--project",
    "cmux_local",
  ];
  logCmd("bunx", devArgs);

  let devOutput = "";
  const devProcess = spawn("bunx", devArgs, {
    cwd: CONVEX_DIR,
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      ...process.env,
      CONVEX_DEPLOYMENT: "",
      CONVEX_AGENT_MODE: "anonymous",
    },
  });

  devProcess.stdout.on("data", (data) => {
    devOutput += data.toString();
    logVerbose(data.toString().trim());
  });
  devProcess.stderr.on("data", (data) => {
    devOutput += data.toString();
    logVerbose(data.toString().trim());
  });

  devProcess.on("error", (err) => {
    console.error(`\n✗ Failed to start Convex server: ${err.message}`);
    process.exit(1);
  });

  const killDevServer = async () => {
    logVerbose("Stopping dev server...");
    devProcess.kill("SIGTERM");
    await new Promise((resolve) => setTimeout(resolve, 1000));
    devProcess.kill("SIGKILL");
  };

  try {
    await withSpinner("Starting local Convex server", async () => {
      const maxWait = 60000;
      const startTime = Date.now();

      while (Date.now() - startTime < maxWait) {
        if (fs.existsSync(CONVEX_ENV_LOCAL)) {
          const content = fs.readFileSync(CONVEX_ENV_LOCAL, "utf-8");
          if (
            content.includes("CONVEX_DEPLOYMENT=") &&
            content.includes("CONVEX_URL=")
          ) {
            logVerbose(`.env.local created after ${Date.now() - startTime}ms`);
            break;
          }
        }
        await new Promise((resolve) => setTimeout(resolve, 500));
      }

      if (!fs.existsSync(CONVEX_ENV_LOCAL)) {
        console.error("\n\nServer output:\n" + devOutput);
        throw new Error("Timed out waiting for Convex server to start");
      }

      // Wait for server to stabilize
      await new Promise((resolve) => setTimeout(resolve, 2000));
    });

    await withSpinner(
      `Setting ${envVarsToSync.length} environment variables`,
      async () => {
        const failures: string[] = [];
        for (const [key, value] of envVarsToSync) {
          try {
            await setEnvVar(key, value);
            logVerbose(`Set ${key}`);
          } catch (error) {
            failures.push(`${key}: ${error}`);
          }
        }
        if (failures.length > 0) {
          throw new Error(`Failed to set: ${failures.join(", ")}`);
        }
      }
    );

    await withSpinner("Waiting for functions to deploy", async () => {
      let functionsReady = false;
      const maxWaitTime = 60000;
      const functionsStartTime = Date.now();

      while (!functionsReady && Date.now() - functionsStartTime < maxWaitTime) {
        logCmd("bunx", ["convex", "function-spec"]);
        const checkProcess = spawn("bunx", ["convex", "function-spec"], {
          cwd: CONVEX_DIR,
          stdio: ["pipe", "pipe", "pipe"],
        });

        let stdout = "";
        checkProcess.stdout.on("data", (data) => {
          stdout += data.toString();
        });

        const exitCode = await new Promise<number>((resolve) => {
          checkProcess.on("close", (code) => resolve(code ?? 1));
        });

        logVerbose(`function-spec exit: ${exitCode}, has seed: ${stdout.includes("seed")}`);

        if (exitCode === 0 && stdout.includes("seed")) {
          functionsReady = true;
        } else {
          await new Promise((resolve) => setTimeout(resolve, 2000));
        }
      }

      if (!functionsReady) {
        console.error("\n\nServer output:\n" + devOutput);
        throw new Error("Timed out waiting for functions to deploy");
      }
    });

    await withSpinner("Running seed", async () => {
      logCmd("bunx", ["convex", "run", "seed"]);

      const seedProcess = spawn("bunx", ["convex", "run", "seed"], {
        cwd: CONVEX_DIR,
        stdio: ["ignore", "pipe", "pipe"],
      });

      let seedOutput = "";
      seedProcess.stdout.on("data", (data) => {
        seedOutput += data.toString();
        logVerbose(data.toString().trim());
      });
      seedProcess.stderr.on("data", (data) => {
        seedOutput += data.toString();
        logVerbose(data.toString().trim());
      });

      await new Promise<void>((resolve, reject) => {
        seedProcess.on("close", (code) => {
          if (code === 0) {
            resolve();
          } else {
            console.error("\n\nSeed output:\n" + seedOutput);
            reject(new Error(`Seed command failed with code ${code}`));
          }
        });
      });
    });

    log("\n✓ Setup complete!\n");
    log("Run the dev environment with:");
    log("  ./scripts/dev.sh --convex-agent\n");
  } finally {
    await killDevServer();
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
