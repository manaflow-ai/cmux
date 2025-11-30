#!/usr/bin/env bun
import { spawn } from "node:child_process";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { performance } from "node:perf_hooks";

type Result = {
  name: string;
  dir: string;
  success: boolean;
  output: string;
  durationMs: number;
  usedJsonReporter: boolean;
};

type PkgWithTest = {
  name: string;
  dir: string;
  testScript: string;
  isVitest: boolean;
  usesDotenv: boolean;
  dotenvEnvPath?: string;
};

function findPackagesWithTests(): PkgWithTest[] {
  const roots = ["apps", "packages"];
  const found: PkgWithTest[] = [];
  for (const root of roots) {
    try {
      const rootPath = join(__dirname, "..", root);
      // Shallow glob: <root>/*/package.json
      const entries: string[] = readdirSync(rootPath);
      for (const entry of entries) {
        const pkgJsonPath = join(rootPath, entry, "package.json");
        if (!existsSync(pkgJsonPath)) continue;
        try {
          const pkg = JSON.parse(readFileSync(pkgJsonPath, "utf8")) as {
            name?: string;
            scripts?: Record<string, string>;
          };
          const testScript = pkg.scripts?.test;
          if (testScript) {
            const dir = dirname(pkgJsonPath);
            const isVitest = /\bvitest\b/.test(testScript);
            const usesDotenv = /\bdotenv\b/.test(testScript);
            let dotenvEnvPath: string | undefined;
            if (usesDotenv) {
              // naive token parse to find: -e <path>
              const tokens = testScript.split(/\s+/);
              for (let i = 0; i < tokens.length - 1; i++) {
                if (tokens[i] === "-e") {
                  dotenvEnvPath = tokens[i + 1];
                  break;
                }
              }
            }
            found.push({
              name: pkg.name ?? `${root}/${entry}`,
              dir,
              testScript,
              isVitest,
              usesDotenv,
              dotenvEnvPath,
            });
          }
        } catch {
          // ignore invalid package.json
        }
      }
    } catch {
      // ignore missing roots
    }
  }
  return found;
}

type TestStatus = "passed" | "failed" | "skipped" | "todo" | "only" | "unknown";
type PerTestTiming = {
  packageName: string;
  filePath: string;
  title: string;
  fullName: string;
  durationMs: number;
  status: TestStatus;
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function asString(v: unknown): string | undefined {
  return typeof v === "string" ? v : undefined;
}

function asNumber(v: unknown): number | undefined {
  return typeof v === "number" ? v : undefined;
}

// Attempts to extract per-test timings from Vitest JSON reporter output.
function parseVitestPerTests(output: string, pkgName: string): PerTestTiming[] {
  const trimmed = output.trim();
  let obj: unknown;
  try {
    obj = JSON.parse(trimmed);
  } catch {
    // Best-effort: try to find the last JSON object in the output
    const lastOpen = trimmed.lastIndexOf("{");
    if (lastOpen !== -1) {
      const candidate = trimmed.slice(lastOpen);
      try {
        obj = JSON.parse(candidate);
      } catch {
        return [];
      }
    } else {
      return [];
    }
  }

  const perTests: PerTestTiming[] = [];

  // Shape 1: Jest-like JSON with testResults -> assertionResults
  if (
    isRecord(obj) &&
    Array.isArray((obj as Record<string, unknown>)["testResults"])
  ) {
    const arr = (obj as Record<string, unknown>)["testResults"] as unknown[];
    for (const fileRes of arr) {
      if (!isRecord(fileRes)) continue;
      const filePath =
        asString(fileRes["name"]) || asString(fileRes["file"]) || "";
      const assertions = fileRes["assertionResults"];
      if (Array.isArray(assertions)) {
        for (const a of assertions) {
          if (!isRecord(a)) continue;
          const title =
            asString(a["title"]) ||
            asString(a["name"]) ||
            asString(a["fullName"]) ||
            "";
          const fullName = asString(a["fullName"]) || title;
          const duration = asNumber(a["duration"]) ?? 0;
          const statusRaw =
            asString(a["status"]) || asString(a["state"]) || "unknown";
          const status: TestStatus =
            statusRaw === "passed" ||
            statusRaw === "failed" ||
            statusRaw === "skipped" ||
            statusRaw === "todo" ||
            statusRaw === "only"
              ? statusRaw
              : "unknown";
          if (title && duration >= 0) {
            perTests.push({
              packageName: pkgName,
              filePath,
              title,
              fullName,
              durationMs: duration,
              status,
            });
          }
        }
      }
    }
  }

  // Shape 2: Vitest-style flattened tests array with name/title + duration
  if (
    perTests.length === 0 &&
    isRecord(obj) &&
    Array.isArray((obj as Record<string, unknown>)["tests"])
  ) {
    const tests = (obj as Record<string, unknown>)["tests"] as unknown[];
    for (const t of tests) {
      if (!isRecord(t)) continue;
      const title = asString(t["title"]) || asString(t["name"]) || "";
      const fullName = asString(t["fullName"]) || title;
      const duration = asNumber(t["duration"]) ?? 0;
      const filePath = asString(t["file"]) || asString(t["filepath"]) || "";
      const statusRaw =
        asString(t["status"]) || asString(t["state"]) || "unknown";
      const status: TestStatus =
        statusRaw === "passed" ||
        statusRaw === "failed" ||
        statusRaw === "skipped" ||
        statusRaw === "todo" ||
        statusRaw === "only"
          ? statusRaw
          : "unknown";
      if (title && duration >= 0) {
        perTests.push({
          packageName: pkgName,
          filePath,
          title,
          fullName,
          durationMs: duration,
          status,
        });
      }
    }
  }

  return perTests;
}

async function runTests() {
  const showTimings = process.argv.includes("--timings");
  console.log(
    `🧪 Running tests across workspaces in parallel${showTimings ? " (with per-test timings)" : ""}...\n`
  );
  // Discover JS/TS packages
  const pkgs = findPackagesWithTests();
  // Partition: run all non-server packages first, then cargo crates, then @cmux/server
  const serverPkg = pkgs.find(
    (p) => p.name === "@cmux/server" || /(^|\/)apps\/server$/.test(p.dir)
  );
  const otherPkgs = pkgs.filter((p) => p !== serverPkg);
  if (pkgs.length === 0) {
    console.log("⚠️  No packages with test scripts found.");
    return;
  }
  // Log which workspaces will run first
  const otherNames = otherPkgs.map((p) => p.name).join(", ");
  console.log(
    `🧵 Stage 1 — workspaces (excluding @cmux/server) (${otherPkgs.length}): ${otherNames}`
  );
  const skipCargoCrates =
    process.env.CMUX_SKIP_CARGO_CRATES?.split(",")
      .map((s) => s.trim())
      .filter((s) => s.length > 0) ?? [];
  const skipCargoSet = new Set(skipCargoCrates);
  const cargoCrates = findCargoCrates();
  const cargoCratesToRun = cargoCrates.filter(
    (c) => !skipCargoSet.has(c.name)
  );
  const skippedCargoCrates = cargoCrates
    .filter((c) => skipCargoSet.has(c.name))
    .map((c) => c.name);
  const cargoNames = cargoCratesToRun.map((c) => `cargo:${c.name}`).join(", ");
  console.log(
    `🧵 Stage 1 — cargo crates (${cargoCratesToRun.length}): ${cargoNames}`
  );
  if (skippedCargoCrates.length > 0) {
    console.log(
      `🚫 Skipping cargo crates via CMUX_SKIP_CARGO_CRATES: ${skippedCargoCrates.join(", ")}`
    );
  }

  const allPerTests: PerTestTiming[] = [];

  const tasksStage1 = otherPkgs.map(
    ({ name, dir, isVitest, usesDotenv, dotenvEnvPath }) => {
      return new Promise<Result>((resolve) => {
        let combined = "";
        const start = performance.now();
        const cmd = "pnpm";
        let args: string[];
        const useJson = showTimings && isVitest;
        if (useJson) {
          // Prefer pnpm exec to avoid the extra `--` being forwarded to vitest
          if (usesDotenv) {
            // Replicate `dotenv -e <path> -- vitest run` with JSON reporter
            args = [
              "exec",
              "dotenv",
              ...(dotenvEnvPath ? ["-e", dotenvEnvPath] : []),
              "--",
              "vitest",
              "run",
              "--reporter=json",
              "--silent",
            ];
          } else {
            args = ["exec", "vitest", "run", "--reporter=json", "--silent"];
          }
        } else {
          // Normal run (no JSON reporter), preserves raw console logs
          args = ["run", "test"];
        }
        // Log when each workspace starts running
        console.log(`▶️  ${name}: starting tests`);
        const child = spawn(cmd, args, {
          cwd: dir,
          shell: true,
          env: process.env,
        });
        child.stdout?.on("data", (d) => (combined += d.toString()));
        child.stderr?.on("data", (d) => (combined += d.toString()));
        child.on("close", (code) => {
          const durationMs = performance.now() - start;
          if (useJson) {
            try {
              const per = parseVitestPerTests(combined, name);
              allPerTests.push(...per);
            } catch {
              // ignore parse errors; fall back to package-level timing only
            }
          }
          console.log(
            `${code === 0 ? "✅" : "❌"} ${name}: finished in ${(durationMs / 1000).toFixed(2)}s`
          );
          resolve({
            name,
            dir,
            success: code === 0,
            output: combined,
            durationMs,
            usedJsonReporter: useJson,
          });
        });
        child.on("error", (err) => {
          const durationMs = performance.now() - start;
          console.log(
            `❌ ${name}: errored after ${(durationMs / 1000).toFixed(2)}s`
          );
          resolve({
            name,
            dir,
            success: false,
            output: String(err),
            durationMs,
            usedJsonReporter: useJson,
          });
        });
      });
    }
  );

  // Run Stage 1 — non-server packages and cargo crates concurrently
  const cargoTasks = cargoCratesToRun.map((c) =>
    new Promise<Result>((resolve) => {
      console.log(`▶️  cargo:${c.name}: starting tests`);
      const start = performance.now();
      const child = spawn("cargo", ["test", "--", "--nocapture"], {
        cwd: c.dir,
        shell: true,
        env: process.env,
      });
      let buf = "";
      child.stdout?.on("data", (d) => (buf += d.toString()));
      child.stderr?.on("data", (d) => (buf += d.toString()));
      child.on("close", (code) => {
        const durationMs = performance.now() - start;
        const success =
          code === 0 && /test result:\s+ok\./.test(buf) && !/\bFAILED\b/.test(buf);
        console.log(
          `${success ? "✅" : "❌"} cargo:${c.name}: finished in ${(durationMs / 1000).toFixed(2)}s`
        );
        resolve({
          name: `cargo:${c.name}`,
          dir: c.dir,
          success,
          output: buf,
          durationMs,
          usedJsonReporter: false,
        });
      });
      child.on("error", (err) => {
        const durationMs = performance.now() - start;
        resolve({
          name: `cargo:${c.name}`,
          dir: c.dir,
          success: false,
          output: String(err),
          durationMs,
          usedJsonReporter: false,
        });
      });
    })
  );

  const resultsStage1 = await Promise.all([...tasksStage1, ...cargoTasks]);

  // Build native Node-API addons for cargo crates (if they define a build script)
  await buildNativeAddons(cargoCratesToRun);

  // Stage 3 — run @cmux/server tests (after cargo)
  let serverResults: Result[] = [];
  if (serverPkg) {
    console.log(`🧵 Stage 3 — @cmux/server tests`);
    const r = await new Promise<Result>((resolve) => {
      let combined = "";
      const start = performance.now();
      const cmd = "pnpm";
      const useJson = showTimings && serverPkg.isVitest;
      let args: string[];
      const skipDocker = process.env.CMUX_SKIP_DOCKER_TESTS === "1";
      if (useJson) {
        if (serverPkg.usesDotenv) {
          args = [
            "exec",
            "dotenv",
            ...(serverPkg.dotenvEnvPath ? ["-e", serverPkg.dotenvEnvPath] : []),
            "--",
            "vitest",
            "run",
            "--reporter=json",
            "--silent",
            ...(skipDocker ? ["--exclude", "**/archiveTask.test.ts"] : []),
          ];
        } else {
          args = [
            "exec",
            "vitest",
            "run",
            "--reporter=json",
            "--silent",
            ...(skipDocker ? ["--exclude", "**/archiveTask.test.ts"] : []),
          ];
        }
      } else {
        args = [
          "run",
          "test",
          ...(skipDocker ? ["--", "--exclude", "**/archiveTask.test.ts"] : []),
        ];
      }
      console.log(`▶️  ${serverPkg.name}: starting tests`);
      const child = spawn(cmd, args, {
        cwd: serverPkg.dir,
        shell: true,
        env: process.env,
      });
      child.stdout?.on("data", (d) => (combined += d.toString()));
      child.stderr?.on("data", (d) => (combined += d.toString()));
      child.on("close", (code) => {
        const durationMs = performance.now() - start;
        if (useJson) {
          try {
            const per = parseVitestPerTests(combined, serverPkg.name);
            allPerTests.push(...per);
          } catch {
            // pass
          }
        }
        console.log(
          `${code === 0 ? "✅" : "❌"} ${serverPkg.name}: finished in ${(durationMs / 1000).toFixed(2)}s`
        );
        resolve({
          name: serverPkg.name,
          dir: serverPkg.dir,
          success: code === 0,
          output: combined,
          durationMs,
          usedJsonReporter: useJson,
        });
      });
      child.on("error", (err) => {
        const durationMs = performance.now() - start;
        console.log(
          `❌ ${serverPkg.name}: errored after ${(durationMs / 1000).toFixed(2)}s`
        );
        resolve({
          name: serverPkg.name,
          dir: serverPkg.dir,
          success: false,
          output: String(err),
          durationMs,
          usedJsonReporter: useJson,
        });
      });
    });
    serverResults = [r];
  }

  const results = [...resultsStage1, ...serverResults];

  // Sort by duration ascending so the longest running are at the bottom
  results.sort((a, b) => a.durationMs - b.durationMs);

  console.log("\n📊 Test Results (sorted by duration, slowest last):\n");
  let failures = 0;
  for (const r of results) {
    if (r.success) {
      const secs = (r.durationMs / 1000).toFixed(2);
      console.log(`✅ ${r.name}: PASSED in ${secs}s`);
    } else {
      failures++;
      const secs = (r.durationMs / 1000).toFixed(2);
      console.log(`❌ ${r.name}: FAILED in ${secs}s`);
      if (r.usedJsonReporter) {
        // If we ran vitest with --silent for JSON, re-run to print raw logs.
        try {
          const retry = await new Promise<string>((resolve) => {
            const child = spawn("pnpm", ["run", "test"], {
              cwd: r.dir,
              shell: true,
              env: process.env,
            });
            let buf = "";
            child.stdout?.on("data", (d) => (buf += d.toString()));
            child.stderr?.on("data", (d) => (buf += d.toString()));
            child.on("close", () => resolve(buf));
            child.on("error", () => resolve(buf));
          });
          const lines = retry.trim().split("\n");
          const last = lines.slice(-200).join("\n");
          console.log(
            `   Output (tail):\n${last
              .split("\n")
              .map((l) => `     ${l}`)
              .join("\n")}`
          );
        } catch {
          const lines = r.output.trim().split("\n");
          const last = lines.slice(-200).join("\n");
          console.log(
            `   Output (tail):\n${last
              .split("\n")
              .map((l) => `     ${l}`)
              .join("\n")}`
          );
        }
      } else {
        // Already have raw logs in r.output
        const lines = r.output.trim().split("\n");
        const last = lines.slice(-200).join("\n");
        console.log(
          `   Output (tail):\n${last
            .split("\n")
            .map((l) => `     ${l}`)
            .join("\n")}`
        );
      }
    }
  }

  // Per-test timing summary (only for Vitest packages where JSON output could be parsed)
  if (showTimings && allPerTests.length > 0) {
    allPerTests.sort((a, b) => a.durationMs - b.durationMs);
    console.log("\n⏱️  Per-test timings (Vitest) — slowest last:\n");
    for (const t of allPerTests) {
      const secs = (t.durationMs / 1000).toFixed(3);
      // Keep line concise: package, file (basename), test title, time, status
      const fileName = t.filePath ? t.filePath.split("/").slice(-1)[0] : "";
      console.log(
        ` • ${t.packageName}${fileName ? `/${fileName}` : ""} :: ${t.title} — ${secs}s ${t.status}`
      );
    }
  }

  if (failures > 0) {
    console.log(`\n❌ ${failures} package(s) failed tests.`);
    process.exit(1);
  } else {
    console.log("\n✅ All package tests passed!");
  }
}

runTests().catch((err) => {
  console.error("Fatal error:", err);
  process.exit(1);
});

// Recursively find Rust crates (Cargo.toml) under apps/, packages/, and crates/
function findCargoCrates(): { name: string; dir: string }[] {
  const roots = ["apps", "packages", "crates"];
  const crates: { name: string; dir: string }[] = [];
  const seen = new Set<string>();

  for (const root of roots) {
    const rootPath = join(__dirname, "..", root);
    walk(rootPath, (dir) => {
      const cargo = join(dir, "Cargo.toml");
      if (existsSync(cargo)) {
        const name = dir.replace(rootPath + "/", "");
        // Discover cargo crate
        if (!seen.has(dir)) {
          seen.add(dir);
          crates.push({ name, dir });
        }
      }
    });
  }
  return crates;
}

function walk(root: string, onDir: (dir: string) => void) {
  let entries: string[] = [];
  try {
    entries = readdirSync(root);
  } catch {
    return;
  }
  onDir(root);
  for (const ent of entries) {
    if (ent === "node_modules" || ent === ".git" || ent === "target") continue;
    const p = join(root, ent);
    let st: ReturnType<typeof statSync> | undefined;
    try {
      st = statSync(p);
    } catch {
      continue;
    }
    if (st && st.isDirectory()) walk(p, onDir);
  }
}

// Build Node-API binaries for crates that expose a package.json with a build script
async function buildNativeAddons(crates: { name: string; dir: string }[]) {
  for (const c of crates) {
    const pkgJsonPath = join(c.dir, "package.json");
    if (!existsSync(pkgJsonPath)) continue;
    try {
      const pkg = JSON.parse(readFileSync(pkgJsonPath, "utf8")) as {
        scripts?: Record<string, string>;
      };
      if (pkg.scripts?.build) {
        console.log(`🔧 Building native addon for cargo:${c.name}`);
        await new Promise<void>((resolve) => {
          const child = spawn("bun", ["run", "build"], {
            cwd: c.dir,
            shell: true,
            env: process.env,
          });
          child.stdout?.on("data", (d) => process.stdout.write(d));
          child.stderr?.on("data", (d) => process.stderr.write(d));
          child.on("close", () => resolve());
          child.on("error", () => resolve());
        });

        // Optionally cross-build Linux targets if toolchains are present
        const buildLinux = process.env.CMUX_BUILD_LINUX === "1";
        if (buildLinux) {
          console.log(`🔧 Building Linux targets for cargo:${c.name}`);
          await new Promise<void>((resolve) => {
            const child = spawn(
              "bunx",
              [
                "--bun",
                "@napi-rs/cli",
                "build",
                "--platform",
                "--target",
                "x86_64-unknown-linux-gnu",
                "--target",
                "aarch64-unknown-linux-gnu",
              ],
              {
                cwd: c.dir,
                shell: true,
                env: process.env,
              }
            );
            child.stdout?.on("data", (d) => process.stdout.write(d));
            child.stderr?.on("data", (d) => process.stderr.write(d));
            child.on("close", () => resolve());
            child.on("error", () => resolve());
          });
        }
      }
    } catch {
      // ignore invalid package.json
    }
  }
}
