#!/usr/bin/env bun
import { spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

// Define all packages that have lint scripts
const packagesWithLint = [
  { name: "client", path: "apps/client" },
  { name: "www", path: "apps/www" },
  { name: "landing", path: "apps/landing" },
  { name: "vscode-extension", path: "packages/vscode-extension" },
];

async function runLint() {
  console.log("🔍 Running lint checks in parallel...\n");

  // Create all promises immediately for true parallel execution
  const lintPromises = packagesWithLint.map(async (pkg) => {
    const packageJsonPath = join(__dirname, "..", pkg.path, "package.json");

    // Check if package.json exists and has a lint script
    if (!existsSync(packageJsonPath)) {
      return null;
    }

    try {
      const packageJson = JSON.parse(readFileSync(packageJsonPath, "utf8"));

      if (!packageJson.scripts?.lint) {
        console.log(`⏭️  Skipping ${pkg.name} (no lint script)`);
        return null;
      }

      console.log(`📦 Starting lint for ${pkg.name}...`);

      // Use spawn for true parallel execution
      const cwd = join(__dirname, "..", pkg.path);

      return new Promise<{
        name: string;
        success: boolean;
        output?: string;
      }>((resolve) => {
        let stdout = "";
        let stderr = "";

        const child = spawn("bun", ["run", "lint"], {
          cwd,
          shell: true,
        });

        child.stdout?.on("data", (data) => {
          stdout += data.toString();
        });

        child.stderr?.on("data", (data) => {
          stderr += data.toString();
        });

        child.on("close", (code) => {
          resolve({
            name: pkg.name,
            success: code === 0,
            output: stdout || stderr,
          });
        });

        child.on("error", (error) => {
          resolve({
            name: pkg.name,
            success: false,
            output: error.message,
          });
        });
      });
    } catch (error) {
      console.error(`❌ Error reading package.json for ${pkg.name}:`, error);
      return null;
    }
  });

  if (lintPromises.length === 0) {
    console.log("⚠️  No packages with lint scripts found");
    return;
  }

  // Wait for all lint checks to complete (filter out nulls)
  const results = (await Promise.all(lintPromises)).filter(
    (result): result is { name: string; success: boolean; output?: string } =>
      result !== null
  );

  console.log("\n📊 Lint Results:\n");

  let hasErrors = false;

  for (const result of results) {
    if (result.success) {
      console.log(`✅ ${result.name}: PASSED`);
      if (result.output && result.output.trim()) {
        console.log(`   Output: ${result.output.trim()}`);
      }
    } else {
      hasErrors = true;
      console.log(`❌ ${result.name}: FAILED`);
      if (result.output) {
        console.log(
          `   Error:\n${result.output
            .split("\n")
            .map((line) => `     ${line}`)
            .join("\n")}`
        );
      }
    }
  }

  if (hasErrors) {
    console.log("\n❌ Lint check failed. Please fix the errors above.");
    process.exit(1);
  } else {
    console.log("\n✅ All lint checks passed!");
  }
}

// Run the lint script
runLint().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
