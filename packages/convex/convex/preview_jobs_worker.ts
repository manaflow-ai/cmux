import {
  createMorphCloudClient,
  startInstanceInstancePost,
  getInstanceInstanceInstanceIdGet,
  execInstanceInstanceIdExecPost,
  stopInstanceInstanceInstanceIdDelete,
  type InstanceModel,
} from "@cmux/morphcloud-openapi-client";
import { SignJWT } from "jose";
import { env } from "../_shared/convex-env";
import { fetchInstallationAccessToken } from "../_shared/githubApp";
import { stringToBase64 } from "../_shared/encoding";
import { internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import type { ActionCtx } from "./_generated/server";

interface ScreenshotCollectorRelease {
  url: string;
  version: string;
  commitSha?: string;
}

const sliceOutput = (value?: string | null, length = 200): string | undefined =>
  value?.slice(0, length);

const singleQuote = (value: string): string =>
  `'${value.replace(/'/g, "'\\''")}'`;

const resolveConvexUrl = (): string | null => {
  const explicitUrl = process.env.CONVEX_SITE_URL || process.env.CONVEX_URL || process.env.CONVEX_CLOUD_URL;
  if (explicitUrl) {
    return explicitUrl.replace(/\/$/, "");
  }
  const deployment = process.env.CONVEX_DEPLOYMENT;
  if (deployment) {
    return `https://${deployment}.convex.site`;
  }
  return null;
};

const delay = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Fetch the screenshot collector release URL from Convex
 */
async function fetchScreenshotCollectorRelease({
  convexUrl,
  isStaging,
  previewRunId,
}: {
  convexUrl: string;
  isStaging: boolean;
  previewRunId: Id<"previewRuns">;
}): Promise<ScreenshotCollectorRelease> {
  // Use .site URL for HTTP endpoints
  const siteUrl = convexUrl.replace(".convex.cloud", ".convex.site");
  const endpoint = `${siteUrl}/api/host-screenshot-collector/latest?staging=${isStaging}`;

  console.log("[preview-jobs] Fetching screenshot collector release", {
    previewRunId,
    endpoint,
    isStaging,
  });

  const response = await fetch(endpoint);
  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(
      `Failed to fetch screenshot collector release (${response.status}): ${errorText}`
    );
  }

  const releaseInfo = await response.json() as ScreenshotCollectorRelease;
  if (!releaseInfo.url) {
    throw new Error("No URL in screenshot collector release info");
  }

  console.log("[preview-jobs] Found screenshot collector release", {
    previewRunId,
    version: releaseInfo.version,
    commitSha: releaseInfo.commitSha,
  });

  return releaseInfo;
}

/**
 * Get changed files in the PR via Morph exec
 */
async function getChangedFiles({
  morphClient,
  instanceId,
  repoDir,
  baseBranch,
  previewRunId,
}: {
  morphClient: ReturnType<typeof createMorphCloudClient>;
  instanceId: string;
  repoDir: string;
  baseBranch: string;
  previewRunId: Id<"previewRuns">;
}): Promise<string[]> {
  // Get the merge base first
  const mergeBaseResponse = await execInstanceInstanceIdExecPost({
    client: morphClient,
    path: { instance_id: instanceId },
    body: {
      command: ["git", "-C", repoDir, "merge-base", `origin/${baseBranch}`, "HEAD"],
    },
  });

  if (mergeBaseResponse.error || mergeBaseResponse.data?.exit_code !== 0) {
    console.warn("[preview-jobs] Failed to get merge base, falling back to origin diff", {
      previewRunId,
      exitCode: mergeBaseResponse.data?.exit_code,
      stderr: sliceOutput(mergeBaseResponse.data?.stderr),
    });

    // Fallback: diff against origin/baseBranch directly
    const fallbackResponse = await execInstanceInstanceIdExecPost({
      client: morphClient,
      path: { instance_id: instanceId },
      body: {
        command: ["git", "-C", repoDir, "diff", "--name-only", `origin/${baseBranch}`],
      },
    });

    if (fallbackResponse.error || fallbackResponse.data?.exit_code !== 0) {
      throw new Error("Failed to get changed files");
    }

    return (fallbackResponse.data?.stdout || "")
      .split("\n")
      .map((f) => f.trim())
      .filter((f) => f.length > 0);
  }

  const mergeBase = mergeBaseResponse.data?.stdout?.trim();
  if (!mergeBase) {
    throw new Error("Empty merge base result");
  }

  // Get changed files between merge base and HEAD
  const diffResponse = await execInstanceInstanceIdExecPost({
    client: morphClient,
    path: { instance_id: instanceId },
    body: {
      command: ["git", "-C", repoDir, "diff", "--name-only", `${mergeBase}..HEAD`],
    },
  });

  if (diffResponse.error || diffResponse.data?.exit_code !== 0) {
    throw new Error(
      `Failed to get changed files: ${diffResponse.data?.stderr || diffResponse.error}`
    );
  }

  const changedFiles = (diffResponse.data?.stdout || "")
    .split("\n")
    .map((f) => f.trim())
    .filter((f) => f.length > 0);

  console.log("[preview-jobs] Got changed files", {
    previewRunId,
    mergeBase,
    fileCount: changedFiles.length,
    files: changedFiles.slice(0, 10), // Log first 10 files
  });

  return changedFiles;
}

interface ScreenshotCollectorOptions {
  workspaceDir: string;
  changedFiles: string[];
  prTitle: string;
  prDescription: string;
  baseBranch: string;
  headBranch: string;
  outputDir: string;
  pathToClaudeCodeExecutable?: string;
  installCommand?: string;
  devCommand?: string;
  auth: { taskRunJwt: string } | { anthropicApiKey: string };
}

interface ScreenshotCollectorResult {
  status: "completed" | "failed" | "skipped";
  screenshots?: Array<{ path: string; description?: string }>;
  hasUiChanges?: boolean;
  error?: string;
  reason?: string;
}

/**
 * Verify a file exists and is non-empty on Morph instance
 */
async function verifyFileOnMorph({
  morphClient,
  instanceId,
  filePath,
}: {
  morphClient: ReturnType<typeof createMorphCloudClient>;
  instanceId: string;
  filePath: string;
}): Promise<number> {
  const verifyResponse = await execInstanceInstanceIdExecPost({
    client: morphClient,
    path: { instance_id: instanceId },
    body: {
      command: ["stat", "-c", "%s", filePath],
    },
  });

  const fileSize = parseInt(verifyResponse.data?.stdout?.trim() || "0", 10);
  if (verifyResponse.error || verifyResponse.data?.exit_code !== 0 || fileSize === 0) {
    throw new Error(`File ${filePath} missing or empty: size=${fileSize}`);
  }
  return fileSize;
}

/**
 * Download a file from URL directly to Morph instance via curl
 */
async function downloadFileToMorph({
  morphClient,
  instanceId,
  filePath,
  url,
  previewRunId,
}: {
  morphClient: ReturnType<typeof createMorphCloudClient>;
  instanceId: string;
  filePath: string;
  url: string;
  previewRunId: Id<"previewRuns">;
}): Promise<number> {
  const downloadResponse = await execInstanceInstanceIdExecPost({
    client: morphClient,
    path: { instance_id: instanceId },
    body: {
      command: ["curl", "-fsSL", "-o", filePath, url],
    },
  });

  if (downloadResponse.error || downloadResponse.data?.exit_code !== 0) {
    throw new Error(
      `Failed to download file to ${filePath}: ${downloadResponse.data?.stderr || downloadResponse.error}`
    );
  }

  const fileSize = await verifyFileOnMorph({ morphClient, instanceId, filePath });

  console.log("[preview-jobs] File downloaded successfully", {
    previewRunId,
    filePath,
    fileSize,
  });

  return fileSize;
}

/**
 * Upload string content to Convex storage and return a URL for downloading
 */
async function uploadToStorage(
  ctx: ActionCtx,
  content: string,
  contentType = "text/plain",
): Promise<{ storageId: Id<"_storage">; url: string }> {
  const blob = new Blob([content], { type: contentType });
  const storageId = await ctx.storage.store(blob);
  const url = await ctx.storage.getUrl(storageId);
  if (!url) {
    throw new Error(`Failed to get URL for storage ID: ${storageId}`);
  }
  return { storageId, url };
}

/**
 * Write string content to a file on Morph instance by uploading to storage then downloading via curl
 */
async function writeStringToMorph({
  ctx,
  morphClient,
  instanceId,
  filePath,
  content,
  previewRunId,
  contentType = "text/plain",
}: {
  ctx: ActionCtx;
  morphClient: ReturnType<typeof createMorphCloudClient>;
  instanceId: string;
  filePath: string;
  content: string;
  previewRunId: Id<"previewRuns">;
  contentType?: string;
}): Promise<void> {
  // Upload content to Convex storage
  const { url, storageId } = await uploadToStorage(ctx, content, contentType);

  console.log("[preview-jobs] Uploaded content to storage", {
    previewRunId,
    filePath,
    contentLength: content.length,
    storageId,
  });

  // Download via curl on Morph
  const downloadResponse = await execInstanceInstanceIdExecPost({
    client: morphClient,
    path: { instance_id: instanceId },
    body: {
      command: ["curl", "-fsSL", "-o", filePath, url],
    },
  });

  if (downloadResponse.error || downloadResponse.data?.exit_code !== 0) {
    throw new Error(
      `Failed to download file to ${filePath}: ${downloadResponse.data?.stderr || downloadResponse.error}`
    );
  }

  const fileSize = await verifyFileOnMorph({ morphClient, instanceId, filePath });

  console.log("[preview-jobs] File written successfully via curl", {
    previewRunId,
    filePath,
    fileSize,
  });
}

/**
 * Read a file from Morph VM and return as base64
 */
async function readFileFromMorph({
  morphClient,
  instanceId,
  filePath,
}: {
  morphClient: ReturnType<typeof createMorphCloudClient>;
  instanceId: string;
  filePath: string;
}): Promise<{ base64: string; size: number } | null> {
  // Use base64 to read the file content (works for binary files like images)
  const response = await execInstanceInstanceIdExecPost({
    client: morphClient,
    path: { instance_id: instanceId },
    body: {
      command: ["base64", "-w", "0", filePath],
    },
  });

  if (response.error || response.data?.exit_code !== 0) {
    return null;
  }

  const base64 = response.data?.stdout?.trim() || "";
  if (!base64) {
    return null;
  }

  // Calculate approximate size from base64 length
  const size = Math.floor((base64.length * 3) / 4);
  return { base64, size };
}

/**
 * Get MIME type from file extension
 */
function getMimeTypeFromPath(filePath: string): string {
  const ext = filePath.split(".").pop()?.toLowerCase();
  switch (ext) {
    case "png":
      return "image/png";
    case "jpg":
    case "jpeg":
      return "image/jpeg";
    case "webp":
      return "image/webp";
    case "gif":
      return "image/gif";
    default:
      return "image/png";
  }
}

/**
 * Download and run the screenshot collector via Morph exec
 */
async function runScreenshotCollector({
  ctx,
  morphClient,
  instanceId,
  collectorUrl,
  options,
  previewRunId,
}: {
  ctx: ActionCtx;
  morphClient: ReturnType<typeof createMorphCloudClient>;
  instanceId: string;
  collectorUrl: string;
  options: ScreenshotCollectorOptions;
  previewRunId: Id<"previewRuns">;
}): Promise<ScreenshotCollectorResult> {
  const collectorPath = "/tmp/screenshot-collector.mjs";
  const optionsPath = "/tmp/screenshot-options.json";
  const runScriptPath = "/tmp/screenshot-runner.mjs";

  // Step 1: Download the collector script from URL via curl on Morph
  console.log("[preview-jobs] Downloading screenshot collector", {
    previewRunId,
    collectorUrl,
  });

  await downloadFileToMorph({
    morphClient,
    instanceId,
    filePath: collectorPath,
    url: collectorUrl,
    previewRunId,
  });

  // Step 2: Write options JSON to Morph via curl (upload to storage, download on Morph)
  const optionsJson = JSON.stringify(options, null, 2);
  console.log("[preview-jobs] Writing screenshot options to file", {
    previewRunId,
    optionsLength: optionsJson.length,
  });

  await writeStringToMorph({
    ctx,
    morphClient,
    instanceId,
    filePath: optionsPath,
    content: optionsJson,
    previewRunId,
    contentType: "application/json",
  });

  // Step 3: Write the runner script to Morph via curl (upload to storage, download on Morph)
  const runScriptContent = `import { claudeCodeCapturePRScreenshots } from '${collectorPath}';
import { readFileSync } from 'fs';
const options = JSON.parse(readFileSync('${optionsPath}', 'utf-8'));
const result = await claudeCodeCapturePRScreenshots(options);
console.log(JSON.stringify(result));`;

  console.log("[preview-jobs] Writing runner script", {
    previewRunId,
    runScriptPath,
  });

  await writeStringToMorph({
    ctx,
    morphClient,
    instanceId,
    filePath: runScriptPath,
    content: runScriptContent,
    previewRunId,
    contentType: "application/javascript",
  });

  // Step 4: Execute the runner script
  console.log("[preview-jobs] Running screenshot collector", {
    previewRunId,
  });

  const runResponse = await execInstanceInstanceIdExecPost({
    client: morphClient,
    path: { instance_id: instanceId },
    body: {
      command: ["/root/.bun/bin/bun", "run", runScriptPath],
    },
  });

  if (runResponse.error) {
    throw new Error(`Screenshot collector exec error: ${JSON.stringify(runResponse.error)}`);
  }

  const { exit_code: exitCode, stdout, stderr } = runResponse.data || {};

  console.log("[preview-jobs] Screenshot collector completed", {
    previewRunId,
    exitCode,
    stdoutLength: stdout?.length,
    stderrLength: stderr?.length,
  });

  if (exitCode !== 0) {
    console.error("[preview-jobs] Screenshot collector failed", {
      previewRunId,
      exitCode,
      stderr: sliceOutput(stderr, 500),
      stdout: sliceOutput(stdout, 500),
    });
    return {
      status: "failed",
      error: stderr || stdout || `Collector exited with code ${exitCode}`,
    };
  }

  // Parse the JSON result from stdout
  // The collector outputs JSON on a line (look for lines starting with '{')
  // The wrapper script may add extra output after the collector finishes
  const stdoutLines = (stdout || "").split("\n").filter((line) => line.trim());

  if (stdoutLines.length === 0) {
    return {
      status: "failed",
      error: "No output from screenshot collector",
    };
  }

  // Find the JSON result line - it should start with '{'
  // Search from the end since the collector outputs JSON as its final meaningful output
  let jsonLine: string | null = null;
  for (let i = stdoutLines.length - 1; i >= 0; i--) {
    const line = stdoutLines[i].trim();
    if (line.startsWith("{")) {
      jsonLine = line;
      break;
    }
  }

  if (!jsonLine) {
    const lastLine = stdoutLines[stdoutLines.length - 1];
    console.error("[preview-jobs] No JSON output found from collector", {
      previewRunId,
      lastLine: sliceOutput(lastLine, 500),
      totalLines: stdoutLines.length,
      stdout: sliceOutput(stdout, 1000),
    });
    return {
      status: "failed",
      error: `No JSON output from collector. Last line: ${sliceOutput(lastLine, 200)}`,
    };
  }

  try {
    const result = JSON.parse(jsonLine) as ScreenshotCollectorResult;
    return result;
  } catch {
    console.error("[preview-jobs] Failed to parse collector JSON output", {
      previewRunId,
      jsonLine: sliceOutput(jsonLine, 500),
    });
    return {
      status: "failed",
      error: `Failed to parse collector output: ${sliceOutput(jsonLine, 200)}`,
    };
  }
}

async function repoHasCommit({
  morphClient,
  instanceId,
  repoDir,
  commitSha,
  previewRunId,
}: {
  morphClient: ReturnType<typeof createMorphCloudClient>;
  instanceId: string;
  repoDir: string;
  commitSha: string;
  previewRunId: Id<"previewRuns">;
}): Promise<boolean> {
  const response = await execInstanceInstanceIdExecPost({
    client: morphClient,
    path: { instance_id: instanceId },
    body: {
      command: ["git", "-C", repoDir, "cat-file", "-e", `${commitSha}^{commit}`],
    },
  });

  if (response.error) {
    console.warn("[preview-jobs] Failed to check commit availability", {
      previewRunId,
      commitSha,
      error: response.error,
    });
    return false;
  }

  return response.data?.exit_code === 0;
}

async function ensureCommitAvailable({
  morphClient,
  instanceId,
  repoDir,
  commitSha,
  prNumber,
  previewRunId,
  headRepoCloneUrl,
  headRef,
}: {
  morphClient: ReturnType<typeof createMorphCloudClient>;
  instanceId: string;
  repoDir: string;
  commitSha: string;
  prNumber: number;
  previewRunId: Id<"previewRuns">;
  headRepoCloneUrl?: string;
  headRef?: string;
}): Promise<void> {
  if (await repoHasCommit({ morphClient, instanceId, repoDir, commitSha, previewRunId })) {
    return;
  }

  console.warn("[preview-jobs] Commit missing after initial fetch, attempting targeted fetches", {
    previewRunId,
    commitSha,
    prNumber,
    headRepoCloneUrl,
    headRef,
  });

  const fetchAttempts: Array<{
    description: string;
    command: string[];
  }> = [
    {
      description: "fetch commit by sha",
      command: ["git", "-C", repoDir, "fetch", "origin", commitSha],
    },
    {
      description: "fetch PR head ref",
      command: [
        "git",
        "-C",
        repoDir,
        "fetch",
        "origin",
        `+refs/pull/${prNumber}/head:refs/cmux/preview/pull/${prNumber}`,
      ],
    },
  ];

  // If PR is from a fork, add fork fetch as the highest priority
  if (headRepoCloneUrl && headRef) {
    fetchAttempts.unshift({
      description: "fetch from fork repository",
      command: [
        "git",
        "-C",
        repoDir,
        "fetch",
        headRepoCloneUrl,
        `${headRef}:refs/cmux/preview/fork/${prNumber}`,
      ],
    });
  }

  for (const attempt of fetchAttempts) {
    console.log("[preview-jobs] Targeted fetch attempt", {
      previewRunId,
      commitSha,
      prNumber,
      description: attempt.description,
    });

    const fetchResponse = await execInstanceInstanceIdExecPost({
      client: morphClient,
      path: { instance_id: instanceId },
      body: {
        command: attempt.command,
      },
    });

    if (fetchResponse.error || fetchResponse.data?.exit_code !== 0) {
      console.warn("[preview-jobs] Targeted fetch failed", {
        previewRunId,
        commitSha,
        prNumber,
        description: attempt.description,
        exitCode: fetchResponse.data?.exit_code,
        stderr: sliceOutput(fetchResponse.data?.stderr),
        stdout: sliceOutput(fetchResponse.data?.stdout),
        error: fetchResponse.error,
      });
      continue;
    }

    if (await repoHasCommit({ morphClient, instanceId, repoDir, commitSha, previewRunId })) {
      console.log("[preview-jobs] Commit available after targeted fetch", {
        previewRunId,
        commitSha,
        prNumber,
        description: attempt.description,
      });
      return;
    }
  }

  throw new Error(
    `Commit ${commitSha} is unavailable after targeted fetch attempts for PR #${prNumber}`,
  );
}

async function stashLocalChanges({
  morphClient,
  instanceId,
  repoDir,
  previewRunId,
  headSha,
}: {
  morphClient: ReturnType<typeof createMorphCloudClient>;
  instanceId: string;
  repoDir: string;
  previewRunId: Id<"previewRuns">;
  headSha: string;
}): Promise<void> {
  console.log("[preview-jobs] Stashing local changes before checkout", {
    previewRunId,
    repoDir,
    headSha,
  });

  const stashResponse = await execInstanceInstanceIdExecPost({
    client: morphClient,
    path: { instance_id: instanceId },
    body: {
      command: [
        "git",
        "-C",
        repoDir,
        "stash",
        "push",
        "--include-untracked",
        "--message",
        `cmux-preview auto-stash before checkout ${headSha}`,
      ],
    },
  });

  if (stashResponse.error || !stashResponse.data) {
    console.error("[preview-jobs] Failed to stash changes before checkout", {
      previewRunId,
      headSha,
      error: stashResponse.error,
    });
    throw new Error("Failed to stash local changes before checkout");
  }

  const { exit_code: exitCode, stdout, stderr } = stashResponse.data;
  if (exitCode !== 0) {
    console.error("[preview-jobs] Stash command failed", {
      previewRunId,
      headSha,
      exitCode,
      stdout: sliceOutput(stdout),
      stderr: sliceOutput(stderr),
    });
    throw new Error(
      `Failed to stash local changes before checkout (exit ${exitCode}): stderr="${sliceOutput(
        stderr,
      )}" stdout="${sliceOutput(stdout)}"`,
    );
  }

  console.log("[preview-jobs] Stash completed before checkout", {
    previewRunId,
    headSha,
    stdout: sliceOutput(stdout),
    stderr: sliceOutput(stderr),
  });
}

async function waitForInstanceReady(
  morphClient: ReturnType<typeof createMorphCloudClient>,
  instanceId: string,
  readinessTimeoutMs = 5 * 60 * 1000,
): Promise<InstanceModel> {
  const start = Date.now();
  while (true) {
    const response = await getInstanceInstanceInstanceIdGet({
      client: morphClient,
      path: { instance_id: instanceId },
    });

    if (response.error) {
      throw new Error(`Failed to get instance status: ${JSON.stringify(response.error)}`);
    }

    const instance = response.data;
    if (!instance) {
      throw new Error("Instance data missing from response");
    }

    if (instance.status === "ready") {
      return instance;
    }
    if (instance.status === "error") {
      throw new Error("Morph instance entered error state");
    }
    if (Date.now() - start > readinessTimeoutMs) {
      throw new Error("Morph instance did not become ready before timeout");
    }
    await new Promise((resolve) => setTimeout(resolve, 1_000));
  }
}

async function startMorphInstance(
  morphClient: ReturnType<typeof createMorphCloudClient>,
  options: {
    snapshotId: string;
    metadata?: Record<string, string>;
    ttlSeconds?: number;
    ttlAction?: "stop" | "pause";
    readinessTimeoutMs?: number;
  },
): Promise<InstanceModel> {
  const response = await startInstanceInstancePost({
    client: morphClient,
    query: {
      snapshot_id: options.snapshotId,
    },
    body: {
      metadata: options.metadata,
      ttl_seconds: options.ttlSeconds,
      ttl_action: options.ttlAction,
    },
  });

  if (response.error) {
    throw new Error(`Failed to start instance: ${JSON.stringify(response.error)}`);
  }

  const instance = response.data;
  if (!instance) {
    throw new Error("Instance data missing from start response");
  }

  return await waitForInstanceReady(
    morphClient,
    instance.id,
    options.readinessTimeoutMs,
  );
}

async function stopMorphInstance(
  morphClient: ReturnType<typeof createMorphCloudClient>,
  instanceId: string,
) {
  await stopInstanceInstanceInstanceIdDelete({
    client: morphClient,
    path: { instance_id: instanceId },
  });
}

async function ensureTmuxSession({
  morphClient,
  instanceId,
  repoDir,
  previewRunId,
}: {
  morphClient: ReturnType<typeof createMorphCloudClient>;
  instanceId: string;
  repoDir: string;
  previewRunId: Id<"previewRuns">;
}): Promise<void> {
  // Match the orchestrator: create session with -n main for the initial window
  const sessionCmd = [
    "zsh",
    "-lc",
    `tmux has-session -t cmux 2>/dev/null || tmux new-session -d -s cmux -c ${singleQuote(repoDir)} -n main`,
  ];
  const response = await execInstanceInstanceIdExecPost({
    client: morphClient,
    path: { instance_id: instanceId },
    body: { command: sessionCmd },
  });
  if (response.error || response.data?.exit_code !== 0) {
    console.warn("[preview-jobs] Failed to ensure tmux session", {
      previewRunId,
      exitCode: response.data?.exit_code,
      stdout: sliceOutput(response.data?.stdout),
      stderr: sliceOutput(response.data?.stderr),
      error: response.error,
    });
  }
}

// Constants matching the environment orchestrator script
const MAINTENANCE_WINDOW_NAME = "maintenance";
const DEV_WINDOW_NAME = "dev";

async function runScriptInTmuxWindow({
  morphClient,
  instanceId,
  repoDir,
  windowName,
  scriptContent,
  previewRunId,
  useSetE = true,
}: {
  morphClient: ReturnType<typeof createMorphCloudClient>;
  instanceId: string;
  repoDir: string;
  windowName: string;
  scriptContent: string;
  previewRunId: Id<"previewRuns">;
  useSetE?: boolean;
}): Promise<void> {
  const trimmed = scriptContent.trim();
  if (!trimmed) {
    return;
  }

  // Create script wrapper matching the environment orchestrator format
  // Source /etc/profile to get system environment variables like RUSTUP_HOME
  const setFlags = useSetE ? "set -eux" : "set -ux";
  const wrappedScript = `#!/bin/zsh
${setFlags}

# Source system profile for environment variables (RUSTUP_HOME, etc.)
[[ -f /etc/profile ]] && source /etc/profile

cd ${repoDir}

echo "=== ${windowName} Script Started at $(date) ==="
${trimmed}
${useSetE ? `echo "=== ${windowName} Script Completed at $(date) ==="` : ""}
`;

  const runtimeDir = "/var/tmp/cmux-scripts";
  const runId = `${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
  const scriptFilePath = `${runtimeDir}/${windowName}.sh`;
  const launcherScriptPath = `${runtimeDir}/${windowName}-launcher.sh`;
  const logFilePath = `${runtimeDir}/${windowName}_${runId}.log`;
  const exitCodePath = `${runtimeDir}/${windowName}_${runId}.exit-code`;

  // Create a launcher script that runs INSIDE the VM to handle tmux operations
  // This matches how the environment orchestrator works - it runs tmux commands
  // from within a shell process inside the VM, not via exec API
  const launcherScript = `#!/bin/zsh
set -eu

# Create the tmux window
tmux new-window -t cmux: -n '${windowName}' -d

# Send keys to run the script (matching orchestrator pattern exactly)
# Pattern: zsh 'script.sh' 2>&1 | tee 'log'; echo \${pipestatus[1]} > 'exit-code'
tmux send-keys -t cmux:'${windowName}' "zsh '${scriptFilePath}' 2>&1 | tee '${logFilePath}'; echo \\\${pipestatus[1]} > '${exitCodePath}'" C-m

echo "[launcher] Started ${windowName} window"
`;

  // Build a setup command that writes both scripts and runs the launcher in background
  // The key insight: Morph exec API doesn't have a TTY, but a background process can
  // interact with tmux properly. This matches the sandbox orchestrator pattern.
  const setupCommand = `
set -eu
mkdir -p '${runtimeDir}'

# Write the main script
cat > '${scriptFilePath}' <<'SCRIPT_EOF'
${wrappedScript}
SCRIPT_EOF
chmod +x '${scriptFilePath}'

# Write the launcher script
cat > '${launcherScriptPath}' <<'LAUNCHER_EOF'
${launcherScript}
LAUNCHER_EOF
chmod +x '${launcherScriptPath}'

# Run the launcher in background (like sandbox orchestrator does with nohup)
nohup zsh '${launcherScriptPath}' > '${runtimeDir}/${windowName}-launcher.log' 2>&1 &
LAUNCHER_PID=$!

# Give it a moment to start
sleep 1

# Verify it started
if kill -0 $LAUNCHER_PID 2>/dev/null; then
  echo "[setup] Launcher started (PID: $LAUNCHER_PID)"
else
  echo "[setup] Launcher may have completed or failed, check log" >&2
fi
`;

  const response = await execInstanceInstanceIdExecPost({
    client: morphClient,
    path: { instance_id: instanceId },
    body: { command: ["zsh", "-lc", setupCommand] },
  });

  if (response.error || response.data?.exit_code !== 0) {
    console.warn("[preview-jobs] Failed to start tmux window", {
      previewRunId,
      windowName,
      exitCode: response.data?.exit_code,
      stdout: sliceOutput(response.data?.stdout),
      stderr: sliceOutput(response.data?.stderr),
      error: response.error,
    });
  } else {
    console.log("[preview-jobs] Started tmux window", {
      previewRunId,
      windowName,
    });
  }
}

export async function runPreviewJob(
  ctx: ActionCtx,
  previewRunId: Id<"previewRuns">,
) {
  const morphApiKey = env.MORPH_API_KEY;
  if (!morphApiKey) {
    console.warn("[preview-jobs] MORPH_API_KEY not configured; skipping run", {
      previewRunId,
    });
    await ctx.runMutation(internal.previewRuns.updateStatus, {
      previewRunId,
      status: "failed",
    });
    return;
  }

  const morphClient = createMorphCloudClient({
    auth: morphApiKey,
  });

  const payload = await ctx.runQuery(internal.previewRuns.getRunWithConfig, {
    previewRunId,
  });
  if (!payload?.run || !payload.config) {
    console.warn("[preview-jobs] Missing run/config for dispatch", {
      previewRunId,
    });
    return;
  }

  const convexUrl = resolveConvexUrl();
  if (!convexUrl) {
    console.error("[preview-jobs] Convex URL not configured; cannot trigger screenshots", {
      previewRunId,
    });
    await ctx.runMutation(internal.previewRuns.updateStatus, {
      previewRunId,
      status: "failed",
    });
    return;
  }

  const { run, config } = payload;
  let taskRunId: Id<"taskRuns"> | null = run.taskRunId ?? null;

  if (!config.environmentId) {
    console.warn("[preview-jobs] Preview config missing environmentId; skipping run", {
      previewRunId,
      repoFullName: run.repoFullName,
      prNumber: run.prNumber,
    });
    // Mark taskRun and task as completed if they exist
    if (taskRunId) {
      try {
        await ctx.runMutation(internal.taskRuns.workerComplete, {
          taskRunId,
          exitCode: 0,
        });
        console.log("[preview-jobs] Task run marked as completed (skipped - no environmentId)", {
          previewRunId,
          taskRunId,
        });
        // Also mark the parent task as completed
        const taskRun = await ctx.runQuery(internal.taskRuns.getById, { id: taskRunId });
        if (taskRun?.taskId) {
          await ctx.runMutation(internal.tasks.setCompletedInternal, {
            taskId: taskRun.taskId,
            isCompleted: true,
            crownEvaluationStatus: "succeeded",
          });
          console.log("[preview-jobs] Task marked as completed (skipped - no environmentId)", {
            previewRunId,
            taskId: taskRun.taskId,
          });
        }
      } catch (completeError) {
        console.error("[preview-jobs] Failed to mark task run/task as completed", {
          previewRunId,
          taskRunId,
          error: completeError instanceof Error ? completeError.message : String(completeError),
        });
      }
    }
    await ctx.runMutation(internal.previewRuns.updateStatus, {
      previewRunId,
      status: "completed",
    });
    return;
  }

  const environment = await ctx.runQuery(internal.environments.getByIdInternal, {
    id: config.environmentId,
  });

  if (!environment) {
    console.warn("[preview-jobs] Environment not found for preview run; skipping", {
      previewRunId,
      environmentId: config.environmentId,
    });
    // Mark taskRun and task as completed if they exist
    if (taskRunId) {
      try {
        await ctx.runMutation(internal.taskRuns.workerComplete, {
          taskRunId,
          exitCode: 0,
        });
        console.log("[preview-jobs] Task run marked as completed (skipped - environment not found)", {
          previewRunId,
          taskRunId,
        });
        // Also mark the parent task as completed
        const taskRun = await ctx.runQuery(internal.taskRuns.getById, { id: taskRunId });
        if (taskRun?.taskId) {
          await ctx.runMutation(internal.tasks.setCompletedInternal, {
            taskId: taskRun.taskId,
            isCompleted: true,
            crownEvaluationStatus: "succeeded",
          });
          console.log("[preview-jobs] Task marked as completed (skipped - environment not found)", {
            previewRunId,
            taskId: taskRun.taskId,
          });
        }
      } catch (completeError) {
        console.error("[preview-jobs] Failed to mark task run/task as completed", {
          previewRunId,
          taskRunId,
          error: completeError instanceof Error ? completeError.message : String(completeError),
        });
      }
    }
    await ctx.runMutation(internal.previewRuns.updateStatus, {
      previewRunId,
      status: "completed",
    });
    return;
  }

  if (!environment.morphSnapshotId) {
    console.warn("[preview-jobs] Environment missing morph snapshot; skipping", {
      previewRunId,
      environmentId: environment._id,
    });
    // Mark taskRun and task as completed if they exist
    if (taskRunId) {
      try {
        await ctx.runMutation(internal.taskRuns.workerComplete, {
          taskRunId,
          exitCode: 0,
        });
        console.log("[preview-jobs] Task run marked as completed (skipped - no morph snapshot)", {
          previewRunId,
          taskRunId,
        });
        // Also mark the parent task as completed
        const taskRun = await ctx.runQuery(internal.taskRuns.getById, { id: taskRunId });
        if (taskRun?.taskId) {
          await ctx.runMutation(internal.tasks.setCompletedInternal, {
            taskId: taskRun.taskId,
            isCompleted: true,
            crownEvaluationStatus: "succeeded",
          });
          console.log("[preview-jobs] Task marked as completed (skipped - no morph snapshot)", {
            previewRunId,
            taskId: taskRun.taskId,
          });
        }
      } catch (completeError) {
        console.error("[preview-jobs] Failed to mark task run/task as completed", {
          previewRunId,
          taskRunId,
          error: completeError instanceof Error ? completeError.message : String(completeError),
        });
      }
    }
    await ctx.runMutation(internal.previewRuns.updateStatus, {
      previewRunId,
      status: "completed",
    });
    return;
  }

  const snapshotId = environment.morphSnapshotId;
  let instance: InstanceModel | null = null;
  let taskId: Id<"tasks"> | null = null;

  if (!taskRunId) {
    console.log("[preview-jobs] No taskRun linked to preview run, creating one now", {
      previewRunId,
      repoFullName: run.repoFullName,
      prNumber: run.prNumber,
    });

    // Get userId from the environment (who created it)
    const userId = environment.userId;
    if (!userId) {
      console.error("[preview-jobs] No userId available for preview task creation", {
        previewRunId,
        repoFullName: run.repoFullName,
        prNumber: run.prNumber,
        teamId: run.teamId,
        environmentId: environment._id,
      });
      throw new Error("No userId available for preview task creation");
    }

    taskId = await ctx.runMutation(internal.tasks.createForPreview, {
      teamId: run.teamId,
      userId,
      previewRunId,
      repoFullName: run.repoFullName,
      prNumber: run.prNumber,
      prUrl: run.prUrl,
      headSha: run.headSha,
      baseBranch: config.repoDefaultBranch,
    });

    const { taskRunId: createdTaskRunId } = await ctx.runMutation(
      internal.taskRuns.createForPreview,
      {
        taskId,
        teamId: run.teamId,
        userId,
        prUrl: run.prUrl,
        environmentId: config.environmentId,
        newBranch: run.headRef,
      },
    );

    await ctx.runMutation(internal.previewRuns.linkTaskRun, {
      previewRunId,
      taskRunId: createdTaskRunId,
    });

    taskRunId = createdTaskRunId;

    console.log("[preview-jobs] Created and linked task/taskRun for preview run", {
      previewRunId,
      taskId,
      taskRunId,
    });
  }

  if (!taskId && taskRunId) {
    const existingTaskRun = await ctx.runQuery(internal.taskRuns.getById, { id: taskRunId });
    if (existingTaskRun?.taskId) {
      taskId = existingTaskRun.taskId;
    } else {
      console.error("[preview-jobs] Task run missing taskId", {
        previewRunId,
        taskRunId,
        hasTaskRun: Boolean(existingTaskRun),
      });
    }
  }

  const keepInstanceForTaskRun = Boolean(taskRunId);
  console.log("[preview-jobs] Launching Morph instance", {
    previewRunId,
    snapshotId,
    repoFullName: run.repoFullName,
    prNumber: run.prNumber,
    headSha: run.headSha,
    baseSha: run.baseSha,
  });

  await ctx.runMutation(internal.previewRuns.updateStatus, {
    previewRunId,
    status: "running",
  });

  // Post initial GitHub comment early with diff heatmap link
  // This gives users immediate feedback while screenshots are being captured
  if (run.repoInstallationId) {
    try {
      const initialCommentResult = await ctx.runAction(
        internal.github_pr_comments.postInitialPreviewComment,
        {
          installationId: run.repoInstallationId,
          repoFullName: run.repoFullName,
          prNumber: run.prNumber,
          previewRunId,
        },
      );

      if (initialCommentResult.ok) {
        console.log("[preview-jobs] Posted initial GitHub comment", {
          previewRunId,
          commentId: initialCommentResult.commentId,
        });
      } else {
        console.warn("[preview-jobs] Failed to post initial GitHub comment", {
          previewRunId,
          error: initialCommentResult.error,
        });
      }
    } catch (error) {
      // Log but don't fail the preview job if initial comment fails
      console.warn("[preview-jobs] Error posting initial GitHub comment", {
        previewRunId,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  try {
    // Generate JWT for screenshot upload authentication if we have a taskRunId
    const previewJwt = taskRunId
      ? await new SignJWT({
          taskRunId,
          teamId: run.teamId,
        })
          .setProtectedHeader({ alg: "HS256" })
          .setIssuedAt()
          .setExpirationTime("12h")
          .sign(new TextEncoder().encode(env.CMUX_TASK_RUN_JWT_SECRET))
      : null;

    console.log("[preview-jobs] Starting Morph instance", {
      previewRunId,
      hasTaskRunId: Boolean(taskRunId),
      hasToken: Boolean(previewJwt),
      snapshotId,
    });

    instance = await startMorphInstance(morphClient, {
      snapshotId,
      metadata: {
        app: "cmux-preview",
        previewRunId: previewRunId,
        repo: run.repoFullName,
        prNumber: String(run.prNumber),
        headSha: run.headSha,
      },
      ttlSeconds: 3600,
      ttlAction: "stop",
      readinessTimeoutMs: 5 * 60 * 1000,
    });

    const workerService = instance.networking?.http_services?.find(
      (service: { port?: number }) => service.port === 39377,
    );
    if (!workerService) {
      throw new Error("Worker service not found on instance");
    }

    const getServiceUrl = (port: number) =>
      instance?.networking?.http_services?.find(
        (service: { port?: number }) => service.port === port,
      )?.url;

    const vscodeService = instance.networking?.http_services?.find(
      (service: { port?: number }) => service.port === 39378,
    );
    const vscodeUrl = vscodeService?.url
      ? `${vscodeService.url}?folder=/root/workspace`
      : null;

    console.log("[preview-jobs] Worker service ready", {
      previewRunId,
      instanceId: instance.id,
      vscodeUrl,
      workerUrl: workerService.url,
      workerHealthUrl: `${workerService.url}/health`,
    });

    if (taskRunId) {
      const networking = instance.networking?.http_services?.map((s) => ({
        status: "running" as const,
        port: s.port || 0,
        url: s.url || "",
      })) ?? [];

      await ctx.runMutation(internal.taskRuns.updateVSCodeMetadataInternal, {
        taskRunId,
        vscode: {
          provider: "morph",
          status: "running",
          containerName: instance.id,
          url: vscodeUrl ?? undefined,
          workspaceUrl: vscodeUrl ?? undefined,
          startedAt: Date.now(),
          ports: {
            vscode: getServiceUrl(39378) ?? "",
            worker: getServiceUrl(39377) ?? "",
            vnc: getServiceUrl(39375),
          },
        },
        networking,
      });
      console.log("[preview-jobs] Updated task run metadata with instance info", {
        taskRunId,
        instanceId: instance.id,
      });
    }

    // Step 2: Fetch latest changes and checkout PR
    // Preview environment snapshots have the repo pre-cloned at /root/workspace
    const repoSearchRoot = "/root/workspace";

    await ctx.runMutation(internal.previewRuns.updateStatus, {
      previewRunId,
      status: "running",
    });

    // The repository is always at /root/workspace directly
    const repoDir = repoSearchRoot;

    console.log("[preview-jobs] Using pre-cloned repository", {
      previewRunId,
      repoFullName: run.repoFullName,
      repoDir,
    });

    console.log("[preview-jobs] Starting GitHub authentication setup", {
      previewRunId,
      hasInstallationId: Boolean(run.repoInstallationId),
      installationId: run.repoInstallationId,
    });

    // Get GitHub App installation token for fetching from private repos
    if (run.repoInstallationId) {
      console.log("[preview-jobs] Fetching installation access token", {
        previewRunId,
        installationId: run.repoInstallationId,
      });

      let accessToken: string | null = null;
      try {
        accessToken = await fetchInstallationAccessToken(run.repoInstallationId);
      } catch (error) {
        console.error("[preview-jobs] Failed to fetch installation token", {
          previewRunId,
          installationId: run.repoInstallationId,
          error: error instanceof Error ? error.message : String(error),
        });
      }

      console.log("[preview-jobs] Installation token fetch result", {
        previewRunId,
        hasToken: Boolean(accessToken),
      });

      if (accessToken) {
        const escapedToken = singleQuote(accessToken);
        
        let lastError: Error | undefined;
        let authSucceeded = false;
        const maxRetries = 5;

        for (let attempt = 1; attempt <= maxRetries; attempt++) {
          try {
            const shellScript = `cd ${repoDir} && printf %s ${escapedToken} | gh auth login --with-token && gh auth setup-git 2>&1`;

            const ghAuthResponse = await execInstanceInstanceIdExecPost({
              client: morphClient,
              path: { instance_id: instance.id },
              body: {
                command: ["bash", "-lc", shellScript],
              },
            });

            console.log("[preview-jobs] GitHub auth response received", {
              previewRunId,
              attempt,
              hasError: Boolean(ghAuthResponse.error),
              exitCode: ghAuthResponse.data?.exit_code,
              stdout: sliceOutput(ghAuthResponse.data?.stdout, 500),
              stderr: sliceOutput(ghAuthResponse.data?.stderr, 500),
            });

            if (ghAuthResponse.error) {
              lastError = new Error(`API error: ${JSON.stringify(ghAuthResponse.error)}`);
              console.error("[preview-jobs] GitHub auth API error", {
                previewRunId,
                attempt,
                error: ghAuthResponse.error,
              });
            } else if (ghAuthResponse.data?.exit_code === 0) {
              console.log("[preview-jobs] GitHub authentication configured successfully", {
                previewRunId,
                attempt,
                stdout: sliceOutput(ghAuthResponse.data?.stdout, 500),
                stderr: sliceOutput(ghAuthResponse.data?.stderr, 500),
              });
              authSucceeded = true;
              break;
            } else {
              const errorMessage = ghAuthResponse.data?.stderr || ghAuthResponse.data?.stdout || "Unknown error";
              lastError = new Error(`GitHub auth failed: ${errorMessage.slice(0, 500)}`);
              console.warn("[preview-jobs] GitHub auth command failed", {
                previewRunId,
                attempt,
                exitCode: ghAuthResponse.data?.exit_code,
                stderr: sliceOutput(ghAuthResponse.data?.stderr, 200),
                stdout: sliceOutput(ghAuthResponse.data?.stdout, 200),
              });
            }

            if (attempt < maxRetries) {
              const delay = Math.min(1000 * Math.pow(2, attempt - 1), 5000);
              console.log("[preview-jobs] Retrying GitHub auth", {
                previewRunId,
                attempt,
                delayMs: delay,
              });
              await new Promise(resolve => setTimeout(resolve, delay));
            }
          } catch (error) {
            const normalizedError = error instanceof Error ? error : new Error(String(error));
            lastError = normalizedError;
            console.error("[preview-jobs] GitHub auth attempt threw error", {
              previewRunId,
              attempt,
              error: normalizedError.message,
            });

            if (attempt < maxRetries) {
              const delay = Math.min(1000 * Math.pow(2, attempt - 1), 5000);
              await new Promise(resolve => setTimeout(resolve, delay));
            }
          }
        }

        if (!authSucceeded) {
          console.error("[preview-jobs] GitHub authentication failed after all retries", {
            previewRunId,
            maxRetries,
            lastError: lastError?.message,
          });
          const finalErrorMessage = lastError?.message || "Unknown error";
          throw new Error(
            `GitHub authentication failed after ${maxRetries} attempts: ${finalErrorMessage}`
          );
        }
      } else {
        console.warn("[preview-jobs] Failed to fetch installation token, falling back to public fetch", {
          previewRunId,
          installationId: run.repoInstallationId,
        });
      }
    } else {
      console.log("[preview-jobs] No installation ID, skipping GitHub authentication", {
        previewRunId,
      });
    }

    console.log("[preview-jobs] Starting git fetch from origin", {
      previewRunId,
      repoDir,
    });

    // Fetch the latest changes from origin (fetch all refs)
    const fetchResponse = await execInstanceInstanceIdExecPost({
      client: morphClient,
      path: { instance_id: instance.id },
      body: {
        command: ["git", "-C", repoDir, "fetch", "origin"],
      },
    });

    if (fetchResponse.error || fetchResponse.data?.exit_code !== 0) {
      console.error("[preview-jobs] Fetch failed", {
        previewRunId,
        exitCode: fetchResponse.data?.exit_code,
        stdout: fetchResponse.data?.stdout,
        stderr: fetchResponse.data?.stderr,
      });
      throw new Error(
        `Failed to fetch from origin (exit ${fetchResponse.data?.exit_code}): ${fetchResponse.data?.stderr || fetchResponse.data?.stdout}`
      );
    }

    console.log("[preview-jobs] Fetched latest changes from origin", {
      previewRunId,
      headSha: run.headSha,
    });

    // Update local default branch ref to match origin
    // This ensures tools like Claude that run `git diff main..branch` use fresh refs
    // Unlike `git pull`, this updates the ref without requiring checkout or modifying working directory
    const defaultBranch = config.repoDefaultBranch || "main";
    const updateDefaultBranchResponse = await execInstanceInstanceIdExecPost({
      client: morphClient,
      path: { instance_id: instance.id },
      body: {
        command: ["git", "-C", repoDir, "fetch", "origin", `${defaultBranch}:${defaultBranch}`],
      },
    });

    if (updateDefaultBranchResponse.error || updateDefaultBranchResponse.data?.exit_code !== 0) {
      // Non-fatal: log warning but continue - the origin/main ref is still available
      console.warn("[preview-jobs] Failed to update local default branch ref", {
        previewRunId,
        defaultBranch,
        exitCode: updateDefaultBranchResponse.data?.exit_code,
        stderr: sliceOutput(updateDefaultBranchResponse.data?.stderr),
      });
    } else {
      console.log("[preview-jobs] Updated local default branch ref", {
        previewRunId,
        defaultBranch,
      });
    }

    // Stash any local changes and pull latest from origin before checkout
    // This ensures the working directory is clean and up-to-date with origin
    await stashLocalChanges({
      morphClient,
      instanceId: instance.id,
      repoDir,
      previewRunId,
      headSha: run.headSha,
    });

    // Pull latest changes from origin for the current branch
    // Use --rebase to avoid merge commits in case there are any unstashed changes
    console.log("[preview-jobs] Pulling latest from origin", {
      previewRunId,
      repoDir,
    });

    const pullResponse = await execInstanceInstanceIdExecPost({
      client: morphClient,
      path: { instance_id: instance.id },
      body: {
        command: ["git", "-C", repoDir, "pull", "--rebase", "origin"],
      },
    });

    if (pullResponse.error || pullResponse.data?.exit_code !== 0) {
      // Non-fatal: log warning but continue - we may be in detached HEAD state
      // or the current branch may not track a remote
      console.warn("[preview-jobs] Failed to pull from origin (may be expected)", {
        previewRunId,
        exitCode: pullResponse.data?.exit_code,
        stderr: sliceOutput(pullResponse.data?.stderr),
        stdout: sliceOutput(pullResponse.data?.stdout),
      });
    } else {
      console.log("[preview-jobs] Pulled latest from origin", {
        previewRunId,
        stdout: sliceOutput(pullResponse.data?.stdout),
      });
    }

    await ensureCommitAvailable({
      morphClient,
      instanceId: instance.id,
      repoDir,
      commitSha: run.headSha,
      prNumber: run.prNumber,
      previewRunId,
      headRepoCloneUrl: run.headRepoCloneUrl,
      headRef: run.headRef,
    });

    console.log("[preview-jobs] Starting git checkout", {
      previewRunId,
      headSha: run.headSha,
      repoDir,
    });

    // Step 3: Checkout the PR commit
    await ctx.runMutation(internal.previewRuns.updateStatus, {
      previewRunId,
      status: "running",
    });

    // Use -f (force) to discard any local modifications that would conflict
    // This is safe because we already stashed changes above
    const checkoutCmd = run.headRef
      ? ["git", "-C", repoDir, "checkout", "-f", "-B", run.headRef, run.headSha]
      : ["git", "-C", repoDir, "checkout", "-f", run.headSha];

    const checkoutResponse = await execInstanceInstanceIdExecPost({
      client: morphClient,
      path: { instance_id: instance.id },
      body: {
        command: checkoutCmd,
      },
    });

    if (checkoutResponse.error) {
      throw new Error(
        `Failed to checkout PR branch ${run.headSha}: ${JSON.stringify(checkoutResponse.error)}`,
      );
    }

    const checkoutResult = checkoutResponse.data;
    if (!checkoutResult) {
      throw new Error("Checkout command returned no data");
    }

    if (checkoutResult.exit_code !== 0) {
      console.error("[preview-jobs] Checkout failed - full output", {
        previewRunId,
        headSha: run.headSha,
        exitCode: checkoutResult.exit_code,
        stdout: checkoutResult.stdout,
        stderr: checkoutResult.stderr,
      });
      throw new Error(
        `Failed to checkout PR branch ${run.headSha} (exit ${checkoutResult.exit_code}): stderr="${checkoutResult.stderr}" stdout="${checkoutResult.stdout}"`,
      );
    }

    console.log("[preview-jobs] Checked out PR branch", {
      previewRunId,
      headSha: run.headSha,
      stdout: checkoutResult.stdout?.slice(0, 200),
    });

    // Step 4: Apply environment variables and trigger screenshot collection
    await ctx.runMutation(internal.previewRuns.updateStatus, {
      previewRunId,
      status: "running",
    });

    if (taskRunId && previewJwt) {
      // Apply environment variables via envctl (same as crown runs)
      // CMUX_IS_STAGING tells the screenshot collector to use staging vs production releases
      const envLines = [
        `CMUX_TASK_RUN_ID="${taskRunId}"`,
        `CMUX_TASK_RUN_JWT="${previewJwt}"`,
        `CONVEX_SITE_URL="${convexUrl}"`,
        `CONVEX_URL="${convexUrl}"`,
        `CMUX_IS_STAGING="${env.CMUX_IS_STAGING ?? "true"}"`,
      ];
      const envVarsContent = envLines.join("\n");
      if (envVarsContent.length === 0) {
        console.error("[preview-jobs] Empty environment payload before envctl", {
          previewRunId,
          taskRunId,
        });
        throw new Error("Cannot apply empty environment payload via envctl");
      }
      const envBase64 = stringToBase64(envVarsContent);
      console.log("[preview-jobs] Applying environment variables via envctl", {
        previewRunId,
        taskRunId,
        payloadLength: envVarsContent.length,
      });
      // Call envctl with explicit base64 argument to avoid shell quoting issues
      const envctlResponse = await execInstanceInstanceIdExecPost({
        client: morphClient,
        path: { instance_id: instance.id },
        body: {
          command: ["envctl", "load", "--base64", envBase64],
        },
      });

      if (envctlResponse.error || envctlResponse.data?.exit_code !== 0) {
        console.error("[preview-jobs] Failed to apply environment variables", {
          previewRunId,
          exitCode: envctlResponse.data?.exit_code,
          stderr: sliceOutput(envctlResponse.data?.stderr),
          stdout: sliceOutput(envctlResponse.data?.stdout),
          error: envctlResponse.error,
        });
        throw new Error("Failed to apply environment variables via envctl");
      }

      console.log("[preview-jobs] Applied environment variables via envctl", {
        previewRunId,
        taskRunId,
        convexUrl,
        cmuxIsStaging: env.CMUX_IS_STAGING ?? "true",
        envctlStdout: sliceOutput(envctlResponse.data?.stdout),
        envctlStderr: sliceOutput(envctlResponse.data?.stderr),
      });

      // Start tmux session and run maintenance/dev scripts if provided
      await ensureTmuxSession({
        morphClient,
        instanceId: instance.id,
        repoDir,
        previewRunId,
      });

      if (environment.maintenanceScript) {
        await runScriptInTmuxWindow({
          morphClient,
          instanceId: instance.id,
          repoDir,
          windowName: MAINTENANCE_WINDOW_NAME,
          scriptContent: environment.maintenanceScript,
          previewRunId,
          useSetE: true,
        });
      }

      if (environment.devScript) {
        await runScriptInTmuxWindow({
          morphClient,
          instanceId: instance.id,
          repoDir,
          windowName: DEV_WINDOW_NAME,
          scriptContent: environment.devScript,
          previewRunId,
          useSetE: false, // Dev script runs indefinitely, don't exit on error
        });
      }

      // Verify task run exists before triggering screenshots
      console.log("[preview-jobs] Verifying task run is queryable", {
        previewRunId,
        taskRunId,
      });

      let taskRunVerified = false;
      for (let attempt = 1; attempt <= 5; attempt++) {
        const verifyTaskRun = await ctx.runQuery(internal.taskRuns.getById, {
          id: taskRunId,
        });

        if (verifyTaskRun) {
          console.log("[preview-jobs] Task run verified", {
            previewRunId,
            taskRunId,
            attempt,
          });
          taskRunVerified = true;
          break;
        }

        console.warn("[preview-jobs] Task run not yet queryable, retrying", {
          previewRunId,
          taskRunId,
          attempt,
        });

        if (attempt < 5) {
          await delay(1000); // Wait 1 second between attempts
        }
      }

      if (!taskRunVerified) {
        throw new Error(`Task run ${taskRunId} not queryable after verification attempts`);
      }

      // Trigger screenshot collection via Morph exec (bypasses worker)
      // Convex determines staging and downloads/runs the collector directly
      const isStaging = env.CMUX_IS_STAGING === "true";

      // Fetch the screenshot collector release URL
      const collectorRelease = await fetchScreenshotCollectorRelease({
        convexUrl,
        isStaging,
        previewRunId,
      });

      // Get changed files via Morph exec
      const changedFiles = await getChangedFiles({
        morphClient,
        instanceId: instance.id,
        repoDir,
        baseBranch: defaultBranch,
        previewRunId,
      });

      if (changedFiles.length === 0) {
        console.log("[preview-jobs] No changed files detected, skipping screenshot collection", {
          previewRunId,
        });
      } else {
        // Build screenshot collector options
        const screenshotOptions: ScreenshotCollectorOptions = {
          workspaceDir: repoDir,
          changedFiles,
          prTitle: run.prTitle || `PR #${run.prNumber}`,
          prDescription: run.prDescription || "",
          baseBranch: defaultBranch,
          headBranch: run.headRef || run.headSha,
          outputDir: `/root/screenshots/${Date.now()}-pr-${run.prNumber}`,
          pathToClaudeCodeExecutable: "/root/.bun/bin/claude",
          installCommand: environment.maintenanceScript ?? undefined,
          devCommand: environment.devScript ?? undefined,
          auth: { taskRunJwt: previewJwt },
        };

        // Run the screenshot collector via Morph exec
        const collectorResult = await runScreenshotCollector({
          ctx,
          morphClient,
          instanceId: instance.id,
          collectorUrl: collectorRelease.url,
          options: screenshotOptions,
          previewRunId,
        });

        console.log("[preview-jobs] Screenshot collector result", {
          previewRunId,
          status: collectorResult.status,
          screenshotCount: collectorResult.screenshots?.length ?? 0,
          hasUiChanges: collectorResult.hasUiChanges,
          error: collectorResult.error,
        });

        // Upload screenshots to Convex storage and create screenshot set
        const uploadedImages: Array<{
          storageId: Id<"_storage">;
          mimeType: string;
          fileName?: string;
          commitSha?: string;
          description?: string;
        }> = [];

        if (collectorResult.status === "completed" && collectorResult.screenshots && collectorResult.screenshots.length > 0) {
          console.log("[preview-jobs] Uploading screenshots to Convex storage", {
            previewRunId,
            screenshotCount: collectorResult.screenshots.length,
          });

          for (const screenshot of collectorResult.screenshots) {
            try {
              // Read the screenshot file from Morph VM
              const fileData = await readFileFromMorph({
                morphClient,
                instanceId: instance.id,
                filePath: screenshot.path,
              });

              if (!fileData) {
                console.warn("[preview-jobs] Failed to read screenshot file", {
                  previewRunId,
                  path: screenshot.path,
                });
                continue;
              }

              // Convert base64 to binary and upload to Convex storage
              const binaryData = Uint8Array.from(atob(fileData.base64), (c) => c.charCodeAt(0));
              const mimeType = getMimeTypeFromPath(screenshot.path);
              const blob = new Blob([binaryData], { type: mimeType });
              const storageId = await ctx.storage.store(blob);

              // Extract filename from path
              const fileName = screenshot.path.split("/").pop() || "screenshot.png";

              uploadedImages.push({
                storageId,
                mimeType,
                fileName,
                commitSha: run.headSha,
                description: screenshot.description,
              });

              console.log("[preview-jobs] Uploaded screenshot", {
                previewRunId,
                path: screenshot.path,
                storageId,
                size: fileData.size,
              });
            } catch (uploadError) {
              console.error("[preview-jobs] Failed to upload screenshot", {
                previewRunId,
                path: screenshot.path,
                error: uploadError instanceof Error ? uploadError.message : String(uploadError),
              });
            }
          }
        }

        let finalStatus = collectorResult.status;
        let finalError = collectorResult.error || collectorResult.reason;
        if (
          collectorResult.status === "completed" &&
          collectorResult.hasUiChanges === false &&
          uploadedImages.length === 0
        ) {
          finalStatus = "skipped";
          finalError = finalError || "No UI changes detected - screenshots skipped";
        }

        console.log("[preview-jobs] Creating screenshot set", {
          previewRunId,
          status: finalStatus,
          originalStatus: collectorResult.status,
          imageCount: uploadedImages.length,
          hasUiChanges: collectorResult.hasUiChanges,
        });

        try {
          await ctx.runMutation(internal.previewScreenshots.createScreenshotSet, {
            previewRunId,
            status: finalStatus,
            commitSha: run.headSha,
            error: finalError,
            hasUiChanges: collectorResult.hasUiChanges,
            images: uploadedImages,
          });

          console.log("[preview-jobs] Screenshot set created, triggering GitHub comment update", {
            previewRunId,
          });

          // Trigger GitHub comment update
          await ctx.runAction(internal.previewScreenshots.triggerGithubComment, {
            previewRunId,
          });

          console.log("[preview-jobs] GitHub comment update triggered", {
            previewRunId,
          });
        } catch (screenshotSetError) {
          console.error("[preview-jobs] Failed to create screenshot set or update GitHub comment", {
            previewRunId,
            error: screenshotSetError instanceof Error ? screenshotSetError.message : String(screenshotSetError),
          });
        }
      }

      console.log("[preview-jobs] Screenshot collection completed via Morph exec", {
        previewRunId,
        taskRunId,
      });
    }

    // Mark the task run as completed now that screenshot collection is done
    // This triggers updateTaskStatusFromRuns to mark the parent task as completed
    if (taskRunId) {
      try {
        await ctx.runMutation(internal.taskRuns.workerComplete, {
          taskRunId,
          exitCode: 0,
        });
        console.log("[preview-jobs] Task run marked as completed", {
          previewRunId,
          taskRunId,
        });
      } catch (completeError) {
        console.error("[preview-jobs] Failed to mark task run as completed", {
          previewRunId,
          taskRunId,
          error: completeError instanceof Error ? completeError.message : String(completeError),
        });
      }

      // Set crown evaluation status to "succeeded" so the green checkmark shows
      // Preview tasks are single-run, so we skip crown evaluation and mark as succeeded directly
      // Use setCompletedInternal which doesn't require user authorization
      if (taskId) {
        try {
          await ctx.runMutation(internal.tasks.setCompletedInternal, {
            taskId,
            isCompleted: true,
            crownEvaluationStatus: "succeeded",
          });
          console.log("[preview-jobs] Task crown evaluation status set to succeeded", {
            previewRunId,
            taskId,
          });
        } catch (crownError) {
          console.error("[preview-jobs] Failed to set crown evaluation status", {
            previewRunId,
            taskId,
            error: crownError instanceof Error ? crownError.message : String(crownError),
          });
        }
      }
    }

    // Mark the preview run as completed
    await ctx.runMutation(internal.previewRuns.updateStatus, {
      previewRunId,
      status: "completed",
    });

    console.log("[preview-jobs] Preview run initialized successfully", {
      previewRunId,
      instanceId: instance.id,
      hasTaskRunId: Boolean(taskRunId),
    });
  } catch (error) {
    const message =
      error instanceof Error ? error.message : String(error ?? "Unknown error");
    console.error("[preview-jobs] Preview job failed", {
      previewRunId,
      error: message,
    });

    // Mark the task run as failed if we have one
    if (taskRunId) {
      try {
        await ctx.runMutation(internal.taskRuns.updateStatus, {
          id: taskRunId,
          status: "failed",
        });
        console.log("[preview-jobs] Task run marked as failed", {
          previewRunId,
          taskRunId,
        });
      } catch (taskRunError) {
        console.error("[preview-jobs] Failed to mark task run as failed", {
          previewRunId,
          taskRunId,
          error: taskRunError instanceof Error ? taskRunError.message : String(taskRunError),
        });
      }
    }

    try {
      await ctx.runMutation(internal.previewRuns.updateStatus, {
        previewRunId,
        status: "failed",
      });
    } catch (statusError) {
      console.error("[preview-jobs] Failed to update preview status", {
        previewRunId,
        error: statusError,
      });
    }

    throw error;
  } finally {
    if (instance && !keepInstanceForTaskRun) {
      try {
        await stopMorphInstance(morphClient, instance.id);
      } catch (stopError) {
        console.warn("[preview-jobs] Failed to stop Morph instance", {
          previewRunId,
          instanceId: instance.id,
          error: stopError,
        });
      }
    } else if (instance) {
      console.log("[preview-jobs] Leaving Morph instance running for preview task run", {
        previewRunId,
        instanceId: instance.id,
        taskRunId,
      });
    }
  }
}
