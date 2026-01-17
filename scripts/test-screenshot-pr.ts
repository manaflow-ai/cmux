#!/usr/bin/env bun
/**
 * Fast screenshot collector testing script
 *
 * Takes a PR URL and runs the screenshot collector locally for quick iteration.
 * Automatically starts Chrome with remote debugging for the collector to connect to.
 *
 * Usage:
 *   bun scripts/test-screenshot-pr.ts <PR_URL> [options]
 *
 * Examples:
 *   bun scripts/test-screenshot-pr.ts https://github.com/owner/repo/pull/123
 *   bun scripts/test-screenshot-pr.ts https://github.com/owner/repo/pull/123 --workspace /path/to/repo
 *   bun scripts/test-screenshot-pr.ts https://github.com/owner/repo/pull/123 --output-dir ./screenshots
 *
 * Environment:
 *   ANTHROPIC_API_KEY - Required for running Claude Code
 */

import { execSync, spawn, type ChildProcess } from "node:child_process";
import { existsSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir, platform } from "node:os";
import { join, resolve } from "node:path";

// ============================================================================
// Types
// ============================================================================

interface PRInfo {
  owner: string;
  repo: string;
  number: number;
  title: string;
  body: string;
  baseBranch: string;
  headBranch: string;
  changedFiles: string[];
}

interface ScreenshotOptions {
  workspaceDir: string;
  changedFiles: string[];
  prTitle: string;
  prDescription: string;
  baseBranch: string;
  headBranch: string;
  outputDir: string;
  installCommand?: string;
  devCommand?: string;
  pathToClaudeCodeExecutable?: string;
  auth: { anthropicApiKey: string };
}

interface CLIArgs {
  prUrl: string;
  workspaceDir?: string;
  outputDir?: string;
  installCommand?: string;
  devCommand?: string;
  skipClone?: boolean;
  verbose?: boolean;
}

// ============================================================================
// Utilities
// ============================================================================

function log(message: string, data?: Record<string, unknown>): void {
  const timestamp = new Date().toISOString();
  if (data) {
    console.log(`[${timestamp}] ${message}`, JSON.stringify(data, null, 2));
  } else {
    console.log(`[${timestamp}] ${message}`);
  }
}

function execCommand(command: string, options?: { cwd?: string }): string {
  try {
    return execSync(command, {
      encoding: "utf-8",
      cwd: options?.cwd,
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch (error) {
    const err = error as { stderr?: Buffer; message?: string };
    throw new Error(
      `Command failed: ${command}\n${err.stderr?.toString() || err.message}`
    );
  }
}

const CDP_PORT = 39382;

function getChromePath(): string {
  const os = platform();

  if (os === "darwin") {
    // macOS Chrome paths
    const paths = [
      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
      "/Applications/Chromium.app/Contents/MacOS/Chromium",
      `${process.env.HOME}/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`,
    ];
    for (const p of paths) {
      if (existsSync(p)) return p;
    }
  } else if (os === "linux") {
    // Linux Chrome paths
    const paths = [
      "/usr/bin/google-chrome",
      "/usr/bin/google-chrome-stable",
      "/usr/bin/chromium",
      "/usr/bin/chromium-browser",
    ];
    for (const p of paths) {
      if (existsSync(p)) return p;
    }
  }

  throw new Error(
    `Could not find Chrome/Chromium. Please install Chrome or set the path manually.`
  );
}

function startChrome(): ChildProcess {
  const chromePath = getChromePath();
  log(`Starting Chrome from: ${chromePath}`);

  const userDataDir = join(tmpdir(), `chrome-debug-${Date.now()}`);
  mkdirSync(userDataDir, { recursive: true });

  const args = [
    `--remote-debugging-port=${CDP_PORT}`,
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-background-networking",
    "--disable-client-side-phishing-detection",
    "--disable-default-apps",
    "--disable-extensions",
    "--disable-hang-monitor",
    "--disable-popup-blocking",
    "--disable-prompt-on-repost",
    "--disable-sync",
    "--disable-translate",
    "--metrics-recording-only",
    "--safebrowsing-disable-auto-update",
    `--user-data-dir=${userDataDir}`,
    "--window-size=1920,1080",
    "about:blank",
  ];

  const proc = spawn(chromePath, args, {
    stdio: ["ignore", "pipe", "pipe"],
    detached: true,
  });

  proc.stderr?.on("data", (data: Buffer) => {
    const msg = data.toString();
    // Only log non-routine Chrome stderr messages
    if (!msg.includes("DevTools listening") && !msg.includes("ERROR:")) {
      // Suppress routine messages
    }
  });

  return proc;
}

async function waitForCDP(timeoutMs = 10000): Promise<void> {
  const start = Date.now();
  const url = `http://127.0.0.1:${CDP_PORT}/json/version`;

  while (Date.now() - start < timeoutMs) {
    try {
      const response = await fetch(url);
      if (response.ok) {
        log(`Chrome DevTools ready at port ${CDP_PORT}`);
        return;
      }
    } catch {
      // Not ready yet, wait and retry
    }
    await new Promise((r) => setTimeout(r, 200));
  }

  throw new Error(`Chrome DevTools not available after ${timeoutMs}ms`);
}

function parsePRUrl(url: string): { owner: string; repo: string; number: number } {
  // https://github.com/owner/repo/pull/123
  const match = url.match(
    /https:\/\/github\.com\/([^/]+)\/([^/]+)\/pull\/(\d+)/
  );
  if (!match) {
    throw new Error(
      `Invalid PR URL format. Expected: https://github.com/<owner>/<repo>/pull/<number>\nGot: ${url}`
    );
  }
  return {
    owner: match[1],
    repo: match[2],
    number: parseInt(match[3], 10),
  };
}

// ============================================================================
// GitHub API helpers (via gh CLI)
// ============================================================================

function fetchPRInfo(prUrl: string): PRInfo {
  const { owner, repo, number } = parsePRUrl(prUrl);
  log(`Fetching PR info for ${owner}/${repo}#${number}...`);

  // Fetch PR metadata
  const prJson = execCommand(
    `gh pr view ${prUrl} --json title,body,baseRefName,headRefName`
  );
  const pr = JSON.parse(prJson) as {
    title: string;
    body: string;
    baseRefName: string;
    headRefName: string;
  };

  // Fetch changed files
  const filesJson = execCommand(`gh pr view ${prUrl} --json files`);
  const filesData = JSON.parse(filesJson) as {
    files: Array<{ path: string }>;
  };
  const changedFiles = filesData.files.map((f) => f.path);

  return {
    owner,
    repo,
    number,
    title: pr.title,
    body: pr.body || "",
    baseBranch: pr.baseRefName,
    headBranch: pr.headRefName,
    changedFiles,
  };
}

// ============================================================================
// Repository setup
// ============================================================================

function setupWorkspace(
  prInfo: PRInfo,
  workspaceDir: string,
  skipClone: boolean
): string {
  const { owner, repo, headBranch } = prInfo;
  const repoUrl = `https://github.com/${owner}/${repo}`;

  if (skipClone) {
    log(`Skipping clone, using existing workspace: ${workspaceDir}`);
    // Just checkout the branch
    execCommand(`git fetch origin ${headBranch}`, { cwd: workspaceDir });
    execCommand(`git checkout ${headBranch}`, { cwd: workspaceDir });
    execCommand(`git pull origin ${headBranch}`, { cwd: workspaceDir });
    return workspaceDir;
  }

  // Clean and clone
  if (existsSync(workspaceDir)) {
    log(`Removing existing workspace: ${workspaceDir}`);
    rmSync(workspaceDir, { recursive: true, force: true });
  }

  log(`Cloning ${repoUrl} into ${workspaceDir}...`);
  mkdirSync(workspaceDir, { recursive: true });
  execCommand(`git clone ${repoUrl} ${workspaceDir}`);

  // Checkout PR branch
  log(`Checking out branch: ${headBranch}`);
  execCommand(`git checkout ${headBranch}`, { cwd: workspaceDir });

  return workspaceDir;
}

// ============================================================================
// Screenshot collector runner
// ============================================================================

async function runScreenshotCollector(options: ScreenshotOptions): Promise<void> {
  log("Starting screenshot collector...", {
    workspaceDir: options.workspaceDir,
    outputDir: options.outputDir,
    changedFilesCount: options.changedFiles.length,
    prTitle: options.prTitle,
    baseBranch: options.baseBranch,
    headBranch: options.headBranch,
  });

  // Find the claude CLI executable
  const claudeExecutable = (() => {
    try {
      return execCommand("which claude").trim();
    } catch {
      // Fallback to common locations
      const commonPaths = [
        join(process.env.HOME || "", ".bun/bin/claude"),
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude",
      ];
      for (const p of commonPaths) {
        if (existsSync(p)) return p;
      }
      throw new Error("Could not find claude CLI. Make sure it's installed and in PATH.");
    }
  })();
  log("Found claude CLI at:", { path: claudeExecutable });

  // Build the host-screenshot-collector first
  const packageDir = resolve(
    import.meta.dirname,
    "../packages/host-screenshot-collector"
  );

  log("Building host-screenshot-collector...");
  execCommand("bun run build", { cwd: packageDir });

  // Import the module directly (like production does)
  const collectorPath = join(packageDir, "dist/index.js");
  log("Loading screenshot collector module...", { path: collectorPath });

  // Set CDP_BROWSER_URL for the collector to use
  process.env.CDP_BROWSER_URL = `http://127.0.0.1:${CDP_PORT}`;

  const collectorModule = await import(`file://${collectorPath}`);
  const { claudeCodeCapturePRScreenshots } = collectorModule as {
    claudeCodeCapturePRScreenshots: (opts: ScreenshotOptions) => Promise<{
      status: "completed" | "failed" | "skipped";
      screenshots?: { path: string; description?: string }[];
      videos?: { path: string; description?: string }[];
      hasUiChanges?: boolean;
      error?: string;
      reason?: string;
    }>;
  };

  log("Running screenshot collector...");
  log("Output will be saved to:", { outputDir: options.outputDir });

  const result = await claudeCodeCapturePRScreenshots({
    workspaceDir: options.workspaceDir,
    changedFiles: options.changedFiles,
    prTitle: options.prTitle,
    prDescription: options.prDescription,
    baseBranch: options.baseBranch,
    headBranch: options.headBranch,
    outputDir: options.outputDir,
    installCommand: options.installCommand,
    devCommand: options.devCommand,
    pathToClaudeCodeExecutable: claudeExecutable,
    auth: options.auth,
  });

  log("Screenshot collector completed", {
    status: result.status,
    screenshotCount: result.screenshots?.length ?? 0,
    videoCount: result.videos?.length ?? 0,
    hasUiChanges: result.hasUiChanges,
  });

  if (result.status === "failed") {
    throw new Error(`Screenshot collector failed: ${result.error}`);
  }
}

// ============================================================================
// CLI argument parsing
// ============================================================================

function printUsage(): void {
  console.log(`
Usage: bun scripts/test-screenshot-pr.ts <PR_URL> [options]

Arguments:
  PR_URL                  GitHub PR URL (e.g., https://github.com/owner/repo/pull/123)

Options:
  --workspace <dir>       Path to workspace directory (default: /tmp/screenshot-test-<timestamp>)
  --output-dir <dir>      Path to output directory for screenshots (default: ./tmp/screenshots)
  --install-command <cmd> Command to install dependencies (e.g., "bun install")
  --dev-command <cmd>     Command to start dev server (e.g., "bun run dev")
  --skip-clone            Skip cloning, use existing workspace (requires --workspace)
  --verbose               Enable verbose logging
  --help                  Show this help message

Environment:
  ANTHROPIC_API_KEY       Required for running Claude Code

Notes:
  - This script automatically starts Chrome with remote debugging on port ${CDP_PORT}
  - Screenshot capture uses Chrome DevTools Protocol (CDP) - works on macOS and Linux
  - Video recording (screenshot-to-video via ffmpeg) works on macOS and Linux

Examples:
  # Basic usage - clone repo and run screenshot collector
  bun scripts/test-screenshot-pr.ts https://github.com/manaflow-ai/cmux/pull/123

  # Use existing workspace (skip clone)
  bun scripts/test-screenshot-pr.ts https://github.com/manaflow-ai/cmux/pull/123 \\
    --workspace /path/to/cmux --skip-clone

  # Specify install and dev commands
  bun scripts/test-screenshot-pr.ts https://github.com/manaflow-ai/cmux/pull/123 \\
    --install-command "bun install" --dev-command "bun run dev"
`);
}

function parseArgs(args: string[]): CLIArgs {
  const result: CLIArgs = {
    prUrl: "",
  };

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];

    if (arg === "--help" || arg === "-h") {
      printUsage();
      process.exit(0);
    }

    if (arg === "--workspace") {
      result.workspaceDir = args[++i];
    } else if (arg.startsWith("--workspace=")) {
      result.workspaceDir = arg.slice("--workspace=".length);
    } else if (arg === "--output-dir") {
      result.outputDir = args[++i];
    } else if (arg.startsWith("--output-dir=")) {
      result.outputDir = arg.slice("--output-dir=".length);
    } else if (arg === "--install-command") {
      result.installCommand = args[++i];
    } else if (arg.startsWith("--install-command=")) {
      result.installCommand = arg.slice("--install-command=".length);
    } else if (arg === "--dev-command") {
      result.devCommand = args[++i];
    } else if (arg.startsWith("--dev-command=")) {
      result.devCommand = arg.slice("--dev-command=".length);
    } else if (arg === "--skip-clone") {
      result.skipClone = true;
    } else if (arg === "--verbose") {
      result.verbose = true;
    } else if (!arg.startsWith("-") && !result.prUrl) {
      result.prUrl = arg;
    } else if (!arg.startsWith("-")) {
      console.error(`Unexpected argument: ${arg}`);
      process.exit(1);
    }
  }

  return result;
}

// ============================================================================
// Main
// ============================================================================

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));

  if (!args.prUrl) {
    console.error("Error: PR URL is required\n");
    printUsage();
    process.exit(1);
  }

  // Check for ANTHROPIC_API_KEY
  const anthropicApiKey = process.env.ANTHROPIC_API_KEY;
  if (!anthropicApiKey) {
    console.error("Error: ANTHROPIC_API_KEY environment variable is required");
    console.error("Set it via: export ANTHROPIC_API_KEY=your-key");
    process.exit(1);
  }

  // Validate skip-clone requires workspace
  if (args.skipClone && !args.workspaceDir) {
    console.error("Error: --skip-clone requires --workspace to be specified");
    process.exit(1);
  }

  let chromeProcess: ChildProcess | null = null;

  // Cleanup function to kill Chrome on exit
  const cleanup = () => {
    if (chromeProcess && !chromeProcess.killed) {
      log("Cleaning up Chrome process...");
      chromeProcess.kill("SIGTERM");
    }
  };

  process.on("SIGINT", () => {
    cleanup();
    process.exit(1);
  });
  process.on("SIGTERM", () => {
    cleanup();
    process.exit(1);
  });

  try {
    // Fetch PR info
    const prInfo = fetchPRInfo(args.prUrl);
    log("PR info fetched", {
      title: prInfo.title,
      baseBranch: prInfo.baseBranch,
      headBranch: prInfo.headBranch,
      changedFilesCount: prInfo.changedFiles.length,
    });

    if (args.verbose) {
      log("Changed files:", { files: prInfo.changedFiles });
    }

    // Setup workspace
    const timestamp = Date.now();
    const defaultWorkspace = join(tmpdir(), `screenshot-test-${timestamp}`);
    const workspaceDir = args.workspaceDir
      ? resolve(args.workspaceDir)
      : defaultWorkspace;

    const workspace = setupWorkspace(
      prInfo,
      workspaceDir,
      args.skipClone ?? false
    );

    // Setup output directory
    const outputDir = args.outputDir
      ? resolve(args.outputDir)
      : resolve(process.cwd(), "tmp/screenshots", `pr-${prInfo.number}`);

    mkdirSync(outputDir, { recursive: true });

    // Start Chrome with remote debugging
    log("Starting Chrome with remote debugging...");
    chromeProcess = startChrome();
    await waitForCDP();

    // Run screenshot collector
    await runScreenshotCollector({
      workspaceDir: workspace,
      changedFiles: prInfo.changedFiles,
      prTitle: prInfo.title,
      prDescription: prInfo.body,
      baseBranch: prInfo.baseBranch,
      headBranch: prInfo.headBranch,
      outputDir,
      installCommand: args.installCommand,
      devCommand: args.devCommand,
      auth: { anthropicApiKey },
    });

    log("Done! Media saved to:", { outputDir });
    console.log(`\n✅ Screenshots and videos saved to: ${outputDir}`);
  } catch (error) {
    console.error("Error:", error instanceof Error ? error.message : error);
    process.exit(1);
  } finally {
    cleanup();
  }
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
