import {
  createMorphCloudClient,
  startInstanceInstancePost,
  getInstanceInstanceInstanceIdGet,
  execInstanceInstanceIdExecPost,
  stopInstanceInstanceInstanceIdDelete,
  type InstanceModel,
} from "@cmux/morphcloud-openapi-client";
import type { WorkerRunTaskScreenshots } from "@cmux/shared";
import { SignJWT } from "jose";
import { env } from "../_shared/convex-env";
import { fetchInstallationAccessToken } from "../_shared/githubApp";
import { stringToBase64 } from "../_shared/encoding";
import { internal } from "./_generated/api";
import type { Id } from "./_generated/dataModel";
import type { ActionCtx } from "./_generated/server";

const sliceOutput = (value?: string | null, length = 200): string | undefined =>
  value?.slice(0, length);

const singleQuote = (value: string): string =>
  `'${value.replace(/'/g, "'\\''")}'`;

const WORKER_SOCKET_TIMEOUT_MS = 30_000;

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

const formatWorkerSocketError = (error: unknown): string => {
  if (!error) {
    return "Unknown worker socket error";
  }
  if (error instanceof Error) {
    return error.message;
  }
  if (typeof error === "string") {
    return error;
  }
  if (typeof error === "object") {
    const errorMessage =
      "message" in error && typeof (error as { message?: unknown }).message === "string"
        ? (error as { message?: string }).message
        : undefined;

    if (errorMessage) {
      return errorMessage;
    }

    try {
      return JSON.stringify(error);
    } catch {
      return String(error);
    }
  }
  return String(error);
};

async function waitForWorkerHealth({
  workerUrl,
  previewRunId,
  timeoutMs = 60_000,
}: {
  workerUrl: string;
  previewRunId: Id<"previewRuns">;
  timeoutMs?: number;
}): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const response = await fetch(`${workerUrl}/health`);
      if (response.ok) {
        const payload = await response.json();
        console.log("[preview-jobs] Worker health check ok", {
          previewRunId,
          mainServerConnected: payload?.mainServerConnected,
        });
        if (!payload || payload.status === "healthy") {
          return;
        }
      } else {
        console.warn("[preview-jobs] Worker health check failed", {
          previewRunId,
          status: response.status,
        });
      }
    } catch (error) {
      console.warn("[preview-jobs] Worker health fetch error", {
        previewRunId,
        error: error instanceof Error ? error.message : String(error),
      });
    }
    await delay(2_000);
  }
  throw new Error("Worker did not become healthy before timeout");
}

async function triggerWorkerScreenshotCollection({
  workerUrl,
  payload,
  previewRunId,
  maxAttempts = 3,
}: {
  workerUrl: string;
  payload: WorkerRunTaskScreenshots;
  previewRunId: Id<"previewRuns">;
  maxAttempts?: number;
}): Promise<void> {
  await waitForWorkerHealth({ workerUrl, previewRunId });
  let attempt = 0;
  let lastError: Error | null = null;
  while (attempt < maxAttempts) {
    attempt += 1;
    try {
      console.log("[preview-jobs] Triggering screenshot collection via HTTP", {
        previewRunId,
        attempt,
        url: `${workerUrl}/api/run-task-screenshots`,
      });

      const response = await fetch(`${workerUrl}/api/run-task-screenshots`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify(payload),
        signal: AbortSignal.timeout(WORKER_SOCKET_TIMEOUT_MS),
      });

      if (!response.ok) {
        const errorText = await response.text().catch(() => "Unknown error");
        throw new Error(
          `Worker returned ${response.status}: ${errorText}`
        );
      }

      const result = await response.json();

      if (result.error) {
        throw new Error(formatWorkerSocketError(result.error));
      }

      console.log("[preview-jobs] Screenshot collection triggered successfully", {
        previewRunId,
        attempt,
      });
      return;
    } catch (error) {
      lastError = error instanceof Error ? error : new Error(String(error));
      console.warn("[preview-jobs] Screenshot trigger attempt failed", {
        previewRunId,
        attempt,
        maxAttempts,
        error: lastError.message,
      });
      if (attempt < maxAttempts) {
        await delay(5_000);
      }
    }
  }
  throw lastError ?? new Error("Unknown worker HTTP error");
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
      description: "Check the git diff and look for frontend changes where screenshots could add good context.",
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
    await ctx.runMutation(internal.previewRuns.updateStatus, {
      previewRunId,
      status: "skipped",
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
    await ctx.runMutation(internal.previewRuns.updateStatus, {
      previewRunId,
      status: "skipped",
    });
    return;
  }

  if (!environment.morphSnapshotId) {
    console.warn("[preview-jobs] Environment missing morph snapshot; skipping", {
      previewRunId,
      environmentId: environment._id,
    });
    await ctx.runMutation(internal.previewRuns.updateStatus, {
      previewRunId,
      status: "skipped",
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

    taskId = await ctx.runMutation(internal.tasks.createForPreview, {
      teamId: run.teamId,
      userId: config.createdByUserId,
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
        userId: config.createdByUserId,
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

  try {
    // Generate JWT for screenshot upload authentication if we have a taskRunId
    const previewJwt = taskRunId
      ? await new SignJWT({
          taskRunId,
          teamId: run.teamId,
          userId: config.createdByUserId,
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
      screenshotLogUrl: `${workerService.url.replace(':39377', ':39376')}/file?path=/root/.cmux/screenshot-collector/screenshot-collector.log`,
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
            extension: getServiceUrl(39376),
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
      const envLines = [
        `CMUX_TASK_RUN_ID="${taskRunId}"`,
        `CMUX_TASK_RUN_JWT="${previewJwt}"`,
        `CONVEX_SITE_URL="${convexUrl}"`,
        `CONVEX_URL="${convexUrl}"`,
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

      // Trigger screenshot collection via worker HTTP endpoint
      // The JWT contains taskRunId, and the worker will call /api/crown/check to get taskId
      const screenshotPayload: WorkerRunTaskScreenshots = {
        token: previewJwt,
        convexUrl,
        // Pass environment scripts so Claude knows how to install deps and run dev server
        installCommand: environment.maintenanceScript ?? undefined,
        devCommand: environment.devScript ?? undefined,
      };

      try {
        await triggerWorkerScreenshotCollection({
          workerUrl: workerService.url,
          payload: screenshotPayload,
          previewRunId,
        });
      } catch (error) {
        console.error("[preview-jobs] Failed to trigger screenshots", {
          previewRunId,
          error: error instanceof Error ? error.message : String(error),
        });
        throw new Error("Failed to trigger screenshot collection");
      }

      console.log("[preview-jobs] Triggered screenshot collection via HTTP", {
        previewRunId,
        taskRunId,
      });
    }

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
