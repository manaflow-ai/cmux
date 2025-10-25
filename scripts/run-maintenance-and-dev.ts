#!/usr/bin/env bun
/**
 * Orchestrator script for running maintenance and dev scripts in sequence.
 * This script is uploaded to the sandbox and run in the background to avoid Vercel timeouts.
 *
 * Flow:
 * 1. Create both tmux windows upfront
 * 2. Run maintenance script and wait for completion
 * 3. Run dev script (regardless of maintenance outcome)
 */

import { $ } from "bun";

// These values will be replaced when the script is uploaded to the sandbox
const MAINTENANCE_SCRIPT_PATH = "{{MAINTENANCE_SCRIPT_PATH}}";
const DEV_SCRIPT_PATH = "{{DEV_SCRIPT_PATH}}";
const MAINTENANCE_WINDOW_NAME = "{{MAINTENANCE_WINDOW_NAME}}";
const DEV_WINDOW_NAME = "{{DEV_WINDOW_NAME}}";
const MAINTENANCE_EXIT_CODE_PATH = "{{MAINTENANCE_EXIT_CODE_PATH}}";
const HAS_MAINTENANCE_SCRIPT = ("{{HAS_MAINTENANCE_SCRIPT}}" as "true" | "false") === "true";
const HAS_DEV_SCRIPT = ("{{HAS_DEV_SCRIPT}}" as "true" | "false") === "true";

// Wait for tmux session to be ready
async function waitForTmuxSession(): Promise<void> {
  for (let i = 0; i < 20; i++) {
    try {
      const result = await $`tmux has-session -t cmux 2>/dev/null`.quiet();
      if (result.exitCode === 0) {
        console.log("[ORCHESTRATOR] tmux session found");
        return;
      }
    } catch (error) {
      // Session not ready yet
    }
    await Bun.sleep(500);
  }

  // Final check
  const result = await $`tmux has-session -t cmux 2>/dev/null`.quiet();
  if (result.exitCode !== 0) {
    throw new Error("Error: cmux session does not exist");
  }
}

// Create both windows upfront
async function createWindows(): Promise<void> {
  await waitForTmuxSession();

  // Create maintenance window if needed
  if (HAS_MAINTENANCE_SCRIPT) {
    try {
      console.log(`[ORCHESTRATOR] Creating ${MAINTENANCE_WINDOW_NAME} window...`);
      await $`tmux new-window -t cmux: -n ${MAINTENANCE_WINDOW_NAME} -d`;
      console.log(`[ORCHESTRATOR] ${MAINTENANCE_WINDOW_NAME} window created`);
    } catch (error) {
      console.error(`[ORCHESTRATOR] Failed to create ${MAINTENANCE_WINDOW_NAME} window:`, error);
      throw error;
    }
  }

  // Create dev window if needed
  if (HAS_DEV_SCRIPT) {
    try {
      console.log(`[ORCHESTRATOR] Creating ${DEV_WINDOW_NAME} window...`);
      await $`tmux new-window -t cmux: -n ${DEV_WINDOW_NAME} -d`;
      console.log(`[ORCHESTRATOR] ${DEV_WINDOW_NAME} window created`);
    } catch (error) {
      console.error(`[ORCHESTRATOR] Failed to create ${DEV_WINDOW_NAME} window:`, error);
      throw error;
    }
  }
}

// Run maintenance script and wait for completion
async function runMaintenanceScript(): Promise<{ exitCode: number; error: string | null }> {
  if (!HAS_MAINTENANCE_SCRIPT) {
    console.log("[MAINTENANCE] No maintenance script to run");
    return { exitCode: 0, error: null };
  }

  try {
    console.log("[MAINTENANCE] Starting maintenance script...");

    // Send command to run the script and capture exit code
    const scriptCommand = `zsh "${MAINTENANCE_SCRIPT_PATH}"
EXIT_CODE=$?
echo "$EXIT_CODE" > "${MAINTENANCE_EXIT_CODE_PATH}"
if [ "$EXIT_CODE" -ne 0 ]; then
  echo "[MAINTENANCE] Script exited with code $EXIT_CODE" >&2
else
  echo "[MAINTENANCE] Script completed successfully"
fi
exec zsh`;

    await $`tmux send-keys -t cmux:${MAINTENANCE_WINDOW_NAME} ${scriptCommand} C-m`;

    await Bun.sleep(2000);

    // Wait for exit code file to appear
    console.log("[MAINTENANCE] Waiting for script to complete...");
    let attempts = 0;
    const maxAttempts = 600; // 10 minutes max
    while (attempts < maxAttempts) {
      const file = Bun.file(MAINTENANCE_EXIT_CODE_PATH);
      if (await file.exists()) {
        break;
      }
      await Bun.sleep(1000);
      attempts++;
    }

    if (attempts >= maxAttempts) {
      console.error("[MAINTENANCE] Script timed out after 10 minutes");
      return {
        exitCode: 124,
        error: "Maintenance script timed out after 10 minutes"
      };
    }

    // Read exit code
    const exitCodeFile = Bun.file(MAINTENANCE_EXIT_CODE_PATH);
    const exitCodeText = await exitCodeFile.text();
    const exitCode = parseInt(exitCodeText.trim()) || 0;

    // Clean up exit code file
    await $`rm -f ${MAINTENANCE_EXIT_CODE_PATH}`;

    console.log(`[MAINTENANCE] Script completed with exit code ${exitCode}`);

    if (exitCode !== 0) {
      return {
        exitCode,
        error: `Maintenance script finished with exit code ${exitCode}`
      };
    }

    return { exitCode: 0, error: null };
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    console.error(`[MAINTENANCE] Error: ${errorMessage}`);
    return {
      exitCode: 1,
      error: `Maintenance script execution failed: ${errorMessage}`
    };
  }
}

// Start dev script (does not wait for completion)
async function startDevScript(): Promise<{ error: string | null }> {
  if (!HAS_DEV_SCRIPT) {
    console.log("[DEV] No dev script to run");
    return { error: null };
  }

  try {
    console.log("[DEV] Starting dev script...");

    // Send command to run the script
    await $`tmux send-keys -t cmux:${DEV_WINDOW_NAME} "zsh \\"${DEV_SCRIPT_PATH}\\"" C-m`;

    await Bun.sleep(2000);

    // Verify window is still running
    const windowCheck = await $`tmux list-windows -t cmux`.text();
    if (windowCheck.includes(DEV_WINDOW_NAME)) {
      console.log("[DEV] Script started successfully");
      return { error: null };
    } else {
      const error = "Dev window not found after starting script";
      console.error(`[DEV] ERROR: ${error}`);
      return { error };
    }
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    console.error(`[DEV] Error: ${errorMessage}`);
    return {
      error: `Dev script execution failed: ${errorMessage}`
    };
  }
}

// Main execution
(async () => {
  try {
    console.log("[ORCHESTRATOR] Starting orchestrator...");

    // Create both windows upfront
    await createWindows();

    // Run maintenance first, capture any errors but continue
    const maintenanceResult = await runMaintenanceScript();
    if (maintenanceResult.error) {
      console.error(`[ORCHESTRATOR] Maintenance completed with error: ${maintenanceResult.error}`);
    } else {
      console.log("[ORCHESTRATOR] Maintenance completed successfully");
    }

    // Always run dev script regardless of maintenance outcome
    const devResult = await startDevScript();
    if (devResult.error) {
      console.error(`[ORCHESTRATOR] Dev script failed: ${devResult.error}`);
      process.exit(1);
    } else {
      console.log("[ORCHESTRATOR] Dev script started successfully");
    }

    // Exit with success - maintenance errors don't affect overall success
    console.log("[ORCHESTRATOR] Orchestrator completed successfully");
    process.exit(0);
  } catch (error) {
    console.error(`[ORCHESTRATOR] Fatal error: ${error}`);
    process.exit(1);
  }
})();
