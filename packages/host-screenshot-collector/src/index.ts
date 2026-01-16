import { query } from "@anthropic-ai/claude-agent-sdk";
import { promises as fs } from "node:fs";
import * as path from "node:path";
import { z } from "zod";

import { logToScreenshotCollector } from "./logger";
import { formatClaudeMessage } from "./claudeMessageFormatter";

export const SCREENSHOT_STORAGE_ROOT = "/root/screenshots";

const IMAGE_EXTENSIONS = new Set([".png", ".jpg", ".jpeg", ".webp"]);

function isScreenshotFile(fileName: string): boolean {
  return IMAGE_EXTENSIONS.has(path.extname(fileName).toLowerCase());
}

const screenshotOutputSchema = z.object({
  hasUiChanges: z.boolean(),
  images: z
    .array(
      z.object({
        path: z.string().min(1),
        description: z.string().min(1),
      })
    )
    .default([]),
});

type ScreenshotStructuredOutput = z.infer<typeof screenshotOutputSchema>;

const screenshotOutputJsonSchema = {
  $schema: "http://json-schema.org/draft-07/schema#",
  type: "object",
  additionalProperties: false,
  required: ["hasUiChanges", "images"],
  properties: {
    hasUiChanges: { type: "boolean" },
    images: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["path", "description"],
        properties: {
          path: { type: "string" },
          description: { type: "string" },
        },
      },
    },
  },
} as const;

async function collectScreenshotFiles(
  directory: string
): Promise<{ files: string[]; hasNestedDirectories: boolean }> {
  const entries = await fs.readdir(directory, { withFileTypes: true });
  const files: string[] = [];
  let hasNestedDirectories = false;

  for (const entry of entries) {
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      hasNestedDirectories = true;
      const nested = await collectScreenshotFiles(fullPath);
      files.push(...nested.files);
    } else if (entry.isFile() && isScreenshotFile(entry.name)) {
      files.push(fullPath);
    }
  }

  return { files, hasNestedDirectories };
}

export function normalizeScreenshotOutputDir(outputDir: string): string {
  if (path.isAbsolute(outputDir)) {
    return path.normalize(outputDir);
  }
  return path.resolve(SCREENSHOT_STORAGE_ROOT, outputDir);
}

export type ClaudeCodeAuthConfig =
  | { auth: { taskRunJwt: string } }
  | { auth: { anthropicApiKey: string } };

type BranchBaseOptions = {
  workspaceDir: string;
  changedFiles: string[];
  prTitle: string;
  prDescription: string;
  outputDir: string;
  pathToClaudeCodeExecutable?: string;
  /** Combined setup script (maintenance + dev), if provided */
  setupScript?: string;
  /** Command to install dependencies (e.g., "bun install", "npm install") */
  installCommand?: string;
  /** Command to start the dev server (e.g., "bun run dev", "npm run dev") */
  devCommand?: string;
  convexSiteUrl?: string;
};

type BranchCaptureOptions =
  | (BranchBaseOptions & { branch: string; auth: { taskRunJwt: string } })
  | (BranchBaseOptions & { branch: string; auth: { anthropicApiKey: string } });

type CaptureScreenshotsBaseOptions = BranchBaseOptions & {
  baseBranch: string;
  headBranch: string;
};

export type CaptureScreenshotsOptions =
  | (CaptureScreenshotsBaseOptions & { auth: { taskRunJwt: string } })
  | (CaptureScreenshotsBaseOptions & { auth: { anthropicApiKey: string } });

export interface ScreenshotResult {
  status: "completed" | "failed" | "skipped";
  screenshots?: { path: string; description?: string }[];
  hasUiChanges?: boolean;
  error?: string;
  reason?: string;
}

/**
 * Use Claude Agent SDK with Playwright MCP to capture screenshots
 * Assumes the workspace is already set up with the correct branch checked out
 */
function isTaskRunJwtAuth(
  auth: ClaudeCodeAuthConfig["auth"]
): auth is { taskRunJwt: string } {
  return "taskRunJwt" in auth;
}

function log(
  level: "INFO" | "WARN" | "ERROR",
  message: string,
  data?: Record<string, unknown>
): void {
  const logData = data ? ` ${JSON.stringify(data)}` : "";
  console.log(`[${level}] ${message}${logData}`);
}

function formatOptionalValue(value: string | null | undefined): string {
  const trimmed = value?.trim();
  return trimmed ? trimmed : "<unset>";
}

function formatSecretValue(value: string | null | undefined): string {
  const trimmed = value?.trim();
  if (!trimmed) return "<unset>";
  return `present(length=${trimmed.length})`;
}

export async function captureScreenshotsForBranch(
  options: BranchCaptureOptions
): Promise<{
  screenshots: { path: string; description?: string }[];
  hasUiChanges?: boolean;
}> {
  const {
    workspaceDir,
    changedFiles,
    prTitle,
    prDescription,
    branch,
    outputDir: requestedOutputDir,
    auth,
    setupScript,
    installCommand,
    devCommand,
    convexSiteUrl,
  } = options;
  const outputDir = normalizeScreenshotOutputDir(requestedOutputDir);
  const useTaskRunJwt = isTaskRunJwtAuth(auth);
  const providedApiKey = !useTaskRunJwt ? auth.anthropicApiKey : undefined;

  const devInstructions = (() => {
    const normalizedSetupScript = setupScript?.trim() ?? "";
    const fallbackSetupScript = [installCommand?.trim(), devCommand?.trim()]
      .filter(Boolean)
      .join("\n\n");
    const resolvedSetupScript = normalizedSetupScript || fallbackSetupScript;

    if (resolvedSetupScript) {
      return `
The user provided the following setup script (maintenance + dev combined). If no dev server is running, use this script to start it:
<setup_script>
${resolvedSetupScript}
</setup_script>`;
    }

    if (!installCommand && !devCommand) {
      return `
The user did not provide installation or dev commands. You will need to discover them by reading README.md, package.json, .devcontainer.json, or other configuration files.`;
    }
    const parts = ["The user provided the following commands:"];
    if (installCommand) {
      parts.push(`<install_command>\n${installCommand}\n</install_command>`);
    } else {
      parts.push(
        "(No install command provided - check README.md or package.json)"
      );
    }
    if (devCommand) {
      parts.push(`<dev_command>\n${devCommand}\n</dev_command>`);
    } else {
      parts.push(
        "(No dev command provided - check README.md or package.json)"
      );
    }
    return "\n" + parts.join("\n");
  })();

  const prompt = `You are a screenshot collector for pull request reviews. Your job is to determine if a PR contains UI changes and, if so, capture screenshots of those changes.

<PR_CONTEXT>
Title: ${prTitle}
Description: ${prDescription || "No description provided"}
Branch: ${branch}
Files changed:
${changedFiles.map((f) => `- ${f}`).join("\n")}
</PR_CONTEXT>

<ENVIRONMENT>
Working directory: ${workspaceDir}
Screenshot output directory: ${outputDir}
${devInstructions}
</ENVIRONMENT>

<PHASE_1_ANALYSIS>
First, analyze the changed files to determine if this PR contains UI changes.

IMPORTANT: Base your decision on the ACTUAL FILES CHANGED, not the PR title or description. PR descriptions can be misleading or incomplete. If the diff contains UI-affecting code, there ARE UI changes regardless of what the description says.

UI changes ARE present if the PR modifies code that affects what users see in the browser:
- Frontend components or templates (any framework: React, Vue, Rails ERB, PHP Blade, Django templates, etc.)
- Stylesheets (CSS, SCSS, Tailwind, styled-components, etc.)
- Markup or template files (HTML, JSX, ERB, Twig, Jinja, Handlebars, etc.)
- Client-side JavaScript/TypeScript that affects rendering
- UI states like loading indicators, error messages, empty states, or toasts
- Accessibility attributes, ARIA labels, or semantic markup

UI changes are NOT present if the PR only modifies:
- Server-side logic that doesn't change what's rendered (API handlers, database queries, background jobs)
- Configuration files (unless they affect theming or UI behavior)
- Tests, documentation, or build scripts
- Type definitions or interfaces for non-UI code

If no UI changes exist: Set hasUiChanges=false, take ZERO screenshots, and explain why. Do not start the dev server or open a browser.
</PHASE_1_ANALYSIS>

<PHASE_2_CAPTURE>
If UI changes exist, capture screenshots:

1. FIRST, check if the dev server is ALREADY RUNNING:
   - Run \`tmux list-windows\` and \`tmux capture-pane -p -t <window>\` to see running processes and their logs
   - Check if there's a dev server process starting up or already running in any tmux window
   - For cloud tasks, also inspect cmux-pty output/logs (tmux may not be used). Look for active dev server commands there.
   - The dev server is typically started automatically in this environment - BE PATIENT and monitor the logs
   - If you see the server is starting/compiling, WAIT for it to finish - do NOT kill it or restart it
   - Use \`ss -tlnp | grep LISTEN\` to see what ports have servers listening
2. ONLY if no server is running anywhere: Read CLAUDE.md, README.md, or package.json for setup instructions. Install dependencies if needed, then start the dev server.
3. BE PATIENT - servers can take time to compile. Monitor tmux logs to see progress. A response from curl (even 404) means the server is up. Do NOT restart the server if it's still compiling.
4. Navigate to the pages/components modified in the PR
5. Capture screenshots of the changes, including:
   - The default/resting state of changed components
   - Interactive states: hover, focus, active, disabled
   - Conditional states: loading, error, empty, success (if the PR modifies these!)
   - Hidden UI: modals, dropdowns, tooltips, accordions
   - Responsive layouts if the PR includes responsive changes
6. Save screenshots to ${outputDir} with descriptive names like "component-state-${branch}.png"
</PHASE_2_CAPTURE>

<PHASE_2B_END_TO_END_TESTING>
CRITICAL: For interactive components, you MUST capture BEFORE and AFTER states to prove functionality works end-to-end.

For EVERY interactive element the PR adds or modifies (buttons, links, forms, toggles, etc.):
1. Screenshot the INITIAL state BEFORE interaction (e.g., "button-before-click.png")
2. PERFORM the interaction (click the button, submit the form, toggle the switch)
3. Screenshot the RESULT state AFTER interaction (e.g., "button-after-click.png")

Examples of proper end-to-end screenshot pairs:
- Button: "add-to-cart-button.png" → click → "item-added-confirmation.png"
- Form: "contact-form-empty.png" → fill & submit → "form-success-message.png"
- Toggle: "dark-mode-off.png" → click toggle → "dark-mode-on.png"
- Modal: "page-with-trigger.png" → click trigger → "modal-open.png"
- Dropdown: "dropdown-closed.png" → click → "dropdown-expanded.png"
- Tab: "tab-1-active.png" → click tab 2 → "tab-2-active.png"
- Accordion: "accordion-collapsed.png" → click → "accordion-expanded.png"
- Delete action: "item-in-list.png" → click delete → "item-removed-or-confirmation.png"

A screenshot of just a button existing is NOT sufficient evidence. You must show the button AND what happens when clicked.
If an interaction fails or produces an error, screenshot that error - it's important evidence.
</PHASE_2B_END_TO_END_TESTING>

<PHASE_3_QUALITY_VERIFICATION>
After capturing screenshots, you MUST verify each one for quality. For EACH screenshot file in ${outputDir}:

1. OPEN the screenshot image file and visually inspect it
2. EVALUATE the screenshot against these quality criteria:
   - Does it show the intended UI component/page that the filename suggests?
   - Is the content fully loaded (no spinners, skeleton loaders, or partial renders - unless that IS the intended capture)?
   - Is the relevant UI element fully visible and not cut off?
   - Is the screenshot free of error states, console overlays, or dev tool artifacts (unless intentionally capturing those)?
   - Does it accurately represent the PR changes you intended to capture?

3. DECIDE: Is this a good screenshot?
   - GOOD: The screenshot clearly captures the intended UI state. Keep it.
   - BAD: The screenshot is blurry, shows wrong content, has unintended loading states, is cut off, or doesn't represent the PR changes. DELETE IT.

4. If BAD: Delete the screenshot file from the filesystem using \`rm <filepath>\`. Then either:
   - Retake the screenshot after fixing the issue (refresh page, wait for content to load, scroll to element, resize viewport)
   - Skip if the UI state cannot be reproduced

5. Only include screenshots in your final output that you have verified as GOOD quality.

Be ruthless about quality. A few excellent screenshots are far more valuable than many mediocre ones. Delete anything that doesn't clearly demonstrate the UI changes.
</PHASE_3_QUALITY_VERIFICATION>

<WHAT_TO_CAPTURE>
Screenshot the UI states that the PR actually modifies. Be intentional:

- If the PR changes a loading spinner → screenshot the loading state
- If the PR changes error handling UI → screenshot the error state
- If the PR changes a skeleton loader → screenshot the skeleton
- If the PR changes hover styles → screenshot the hover state
- If the PR changes a modal → open and screenshot the modal
- If the PR adds a button → screenshot the button AND click it to show what happens
- If the PR adds a form → screenshot the empty form AND submit it to show validation/success
- If the PR adds a link → screenshot the link AND navigate to show the destination

Don't screenshot loading/error states incidentally while waiting for the "real" UI. Screenshot them when they ARE the change.

REMEMBER: Interactive elements require TWO screenshots minimum - before AND after the interaction.
</WHAT_TO_CAPTURE>

<CRITICAL_MISTAKES>
Avoid these failure modes:

FALSE POSITIVE: Taking screenshots when the PR has no UI changes. Backend-only, config, or test changes = hasUiChanges=false, zero screenshots.

FALSE NEGATIVE: Failing to capture screenshots when UI changes exist. If React components, CSS, or templates changed, you MUST capture them.

FAKE UI: Creating mock HTML files instead of screenshotting the real app. Never fabricate UIs. If the dev server won't start, report the failure.

WRONG PAGE: Screenshotting pages unrelated to the PR. Only capture components/pages that the changed files actually render.

DUPLICATE SCREENSHOTS: Taking multiple identical screenshots. Each screenshot should show something distinct.

INCOMPLETE CAPTURE: Missing important UI elements. Ensure full components are visible and not cut off.

MISSING INTERACTION PROOF: Only showing a button/form/toggle exists without showing what happens when you interact with it. A button screenshot without clicking it is incomplete evidence. Always capture before AND after states for interactive elements.

UNTESTED FUNCTIONALITY: Taking a screenshot of a new feature without actually testing it works. Click the button. Submit the form. Toggle the switch. Navigate the link. Prove it works.
</CRITICAL_MISTAKES>

<OUTPUT_REQUIREMENTS>
- Set hasUiChanges to true only if the PR modifies UI-rendering code AND you captured screenshots
- Set hasUiChanges to false if the PR has no UI changes (with zero screenshots)
- Include every screenshot path with a description of what it shows
- Do not close the browser when done
- Do not create summary documents
</OUTPUT_REQUIREMENTS>`;

  await logToScreenshotCollector(
    `Starting Claude Agent with browser MCP for branch: ${branch}`
  );

  const screenshotPaths: string[] = [];
  let structuredOutput: ScreenshotStructuredOutput | null = null;

  if (useTaskRunJwt && !convexSiteUrl) {
    await logToScreenshotCollector(
      "[WARN] convexSiteUrl is missing; Anthropic proxy requests may fail."
    );
  }
  const normalizedConvexSiteUrl = formatOptionalValue(convexSiteUrl);

  await logToScreenshotCollector(
    `[DEBUG] convexSiteUrl: ${normalizedConvexSiteUrl}`
  );

  const anthropicBaseUrl = `${normalizedConvexSiteUrl}/api/anthropic`;

  await logToScreenshotCollector(
    `[DEBUG] anthropicBaseUrl: ${anthropicBaseUrl}`
  );

  try {
    const hadOriginalApiKey = Object.prototype.hasOwnProperty.call(
      process.env,
      "ANTHROPIC_API_KEY"
    );
    const originalApiKey = process.env.ANTHROPIC_API_KEY;
    if (useTaskRunJwt) {
      delete process.env.ANTHROPIC_API_KEY;
      // Log JWT info for debugging
      await logToScreenshotCollector(
        `Using taskRun JWT auth. JWT present: ${!!auth.taskRunJwt}, JWT length: ${auth.taskRunJwt?.length ?? 0}, JWT first 20 chars: ${auth.taskRunJwt?.substring(0, 20) ?? "N/A"}`
      );
      await logToScreenshotCollector(
        `ANTHROPIC_BASE_URL: ${anthropicBaseUrl}`
      );
      await logToScreenshotCollector(
        `[DEBUG] ANTHROPIC_CUSTOM_HEADERS will be: x-cmux-token:<jwt>`
      );
    } else if (providedApiKey) {
      process.env.ANTHROPIC_API_KEY = providedApiKey;
      await logToScreenshotCollector(
        `Using API key auth. Key present: ${!!providedApiKey}, Key length: ${providedApiKey?.length ?? 0}`
      );
    }

    await logToScreenshotCollector(
      `Arguments to Claude Code: ${JSON.stringify({
        prompt,
        cwd: workspaceDir,
        pathToClaudeCodeExecutable: options.pathToClaudeCodeExecutable,
      })}`
    );

    const claudeEnv = {
      ...process.env,
      IS_SANDBOX: "1",
      CLAUDE_CODE_ENABLE_TELEMETRY: "0",
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1",
      ...(useTaskRunJwt
        ? {
          ANTHROPIC_API_KEY: "sk_placeholder_cmux_anthropic_api_key",
          ANTHROPIC_BASE_URL: anthropicBaseUrl,
          ANTHROPIC_CUSTOM_HEADERS: `x-cmux-token:${auth.taskRunJwt}`,
        }
        : {}),
    };

    await logToScreenshotCollector(
      `[DEBUG] Claude env: ${JSON.stringify({
        ANTHROPIC_BASE_URL: formatOptionalValue(claudeEnv.ANTHROPIC_BASE_URL),
        ANTHROPIC_CUSTOM_HEADERS: formatSecretValue(
          claudeEnv.ANTHROPIC_CUSTOM_HEADERS
        ),
        ANTHROPIC_API_KEY: formatSecretValue(claudeEnv.ANTHROPIC_API_KEY),
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: formatOptionalValue(
          claudeEnv.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
        ),
        CLAUDE_CODE_ENABLE_TELEMETRY: formatOptionalValue(
          claudeEnv.CLAUDE_CODE_ENABLE_TELEMETRY
        ),
      })}`
    );

    try {
      for await (const message of query({
        prompt,
        options: {
          // model: "claude-haiku-4-5",
          model: "claude-opus-4-5",
          // mcpServers: {
          //   "playwright": {
          //     command: "bunx",
          //     args: [
          //       "@playwright/mcp",
          //       "--cdp-endpoint",
          //       "http://0.0.0.0:39382",
          //     ],
          //   },
          // },
          mcpServers: {
            chrome: {
              command: "bunx",
              args: [
                "chrome-devtools-mcp",
                "--browserUrl",
                "http://0.0.0.0:39382",
              ],
            },
          },
          allowDangerouslySkipPermissions: true,
          permissionMode: "bypassPermissions",
          cwd: workspaceDir,
          pathToClaudeCodeExecutable: options.pathToClaudeCodeExecutable,
          outputFormat: {
            type: "json_schema",
            schema: screenshotOutputJsonSchema,
          },
          env: claudeEnv,
          stderr: (data) =>
            logToScreenshotCollector(`[claude-code-stderr] ${data}`),
        },
      })) {
        // Format and log all message types
        const formatted = formatClaudeMessage(message);
        if (formatted) {
          await logToScreenshotCollector(formatted);
        }

        if (message.type === "result" && "structured_output" in message) {
          const parsed = screenshotOutputSchema.safeParse(
            message.structured_output
          );
          if (parsed.success) {
            structuredOutput = parsed.data;
            await logToScreenshotCollector(
              `Structured output captured (hasUiChanges=${parsed.data.hasUiChanges}, images=${parsed.data.images.length})`
            );
          } else {
            await logToScreenshotCollector(
              `Structured output validation failed: ${parsed.error.message}`
            );
          }
        }
      }
    } catch (error) {
      await logToScreenshotCollector(
        `Failed to capture screenshots with Claude Agent: ${error instanceof Error ? error.message : String(error)}`
      );
      log("ERROR", "Failed to capture screenshots with Claude Agent", {
        error: error instanceof Error ? error.message : String(error),
      });
      throw error;
    } finally {
      if (hadOriginalApiKey) {
        if (originalApiKey !== undefined) {
          process.env.ANTHROPIC_API_KEY = originalApiKey;
        } else {
          delete process.env.ANTHROPIC_API_KEY;
        }
      } else {
        delete process.env.ANTHROPIC_API_KEY;
      }
    }

    // Find all screenshot files in the output directory
    try {
      const { files, hasNestedDirectories } =
        await collectScreenshotFiles(outputDir);

      if (hasNestedDirectories) {
        await logToScreenshotCollector(
          `Detected nested screenshot folders under ${outputDir}. Please keep all screenshots directly in the output directory.`
        );
      }

      const uniqueScreens = Array.from(
        new Set(files.map((filePath) => path.normalize(filePath)))
      ).sort();
      screenshotPaths.push(...uniqueScreens);
    } catch (readError) {
      log("WARN", "Could not read screenshot directory", {
        outputDir,
        error:
          readError instanceof Error ? readError.message : String(readError),
      });
    }

    const descriptionByPath = new Map<string, string>();
    const resolvedOutputDir = path.resolve(outputDir);
    if (structuredOutput) {
      for (const image of structuredOutput.images) {
        const absolutePath = path.isAbsolute(image.path)
          ? path.normalize(image.path)
          : path.normalize(path.resolve(resolvedOutputDir, image.path));
        descriptionByPath.set(absolutePath, image.description);
      }
    }

    const screenshotsWithDescriptions = screenshotPaths.map((absolutePath) => {
      const normalized = path.normalize(absolutePath);
      return {
        path: absolutePath,
        description: descriptionByPath.get(normalized),
      };
    });

    if (
      structuredOutput &&
      structuredOutput.images.length > 0 &&
      descriptionByPath.size === 0
    ) {
      await logToScreenshotCollector(
        "Structured output provided image descriptions, but none matched saved files; ensure paths are absolute or relative to the output directory."
      );
    }

    return {
      screenshots: screenshotsWithDescriptions,
      hasUiChanges: structuredOutput?.hasUiChanges,
    };
  } catch (error) {
    const message =
      error instanceof Error ? error.message : String(error ?? "unknown error");
    await logToScreenshotCollector(
      `Failed to capture screenshots with Claude Agent: ${message}`
    );

    // Log full error details for debugging
    if (error instanceof Error) {
      if (error.stack) {
        await logToScreenshotCollector(`Stack trace: ${error.stack}`);
      }
      // Log any additional error properties
      const errorObj = error as Error & Record<string, unknown>;
      const additionalProps = Object.keys(errorObj)
        .filter((key) => !["message", "stack", "name"].includes(key))
        .map((key) => `${key}: ${JSON.stringify(errorObj[key])}`)
        .join(", ");
      if (additionalProps) {
        await logToScreenshotCollector(`Error details: ${additionalProps}`);
      }
    }

    throw error;
  }
}

/**
 * Capture screenshots for a PR
 * Assumes the workspace directory is already set up with git repo cloned
 */
export async function claudeCodeCapturePRScreenshots(
  options: CaptureScreenshotsOptions
): Promise<ScreenshotResult> {
  const {
    workspaceDir,
    changedFiles,
    prTitle,
    prDescription,
    baseBranch,
    headBranch,
    outputDir: requestedOutputDir,
    auth,
  } = options;
  const outputDir = normalizeScreenshotOutputDir(requestedOutputDir);

  try {
    await logToScreenshotCollector(
      `Starting PR screenshot capture in ${workspaceDir}`
    );

    if (changedFiles.length === 0) {
      const reason = "No files changed in PR";
      await logToScreenshotCollector(reason);
      return { status: "skipped", reason };
    }

    await logToScreenshotCollector(
      `Found ${changedFiles.length} changed files: ${changedFiles.join(", ")}`
    );

    await fs.mkdir(outputDir, { recursive: true });

    const allScreenshots: { path: string; description?: string }[] = [];
    let hasUiChanges: boolean | undefined;

    const CAPTURE_BEFORE = false;

    if (CAPTURE_BEFORE) {
      // Capture screenshots for base branch (before changes)
      await logToScreenshotCollector(
        `Capturing 'before' screenshots for base branch: ${baseBranch}`
      );
      const beforeScreenshots = await captureScreenshotsForBranch(
        isTaskRunJwtAuth(auth)
          ? {
          workspaceDir,
          changedFiles,
          prTitle,
          prDescription,
          branch: baseBranch,
          outputDir,
          auth: { taskRunJwt: auth.taskRunJwt },
          pathToClaudeCodeExecutable: options.pathToClaudeCodeExecutable,
          setupScript: options.setupScript,
          installCommand: options.installCommand,
          devCommand: options.devCommand,
          convexSiteUrl: options.convexSiteUrl,
        }
        : {
          workspaceDir,
          changedFiles,
          prTitle,
          prDescription,
          branch: baseBranch,
          outputDir,
          auth: { anthropicApiKey: auth.anthropicApiKey },
          pathToClaudeCodeExecutable: options.pathToClaudeCodeExecutable,
          setupScript: options.setupScript,
          installCommand: options.installCommand,
          devCommand: options.devCommand,
          convexSiteUrl: options.convexSiteUrl,
        }
      );
      allScreenshots.push(...beforeScreenshots.screenshots);
      if (beforeScreenshots.hasUiChanges !== undefined) {
        hasUiChanges = beforeScreenshots.hasUiChanges;
      }
      await logToScreenshotCollector(
        `Captured ${beforeScreenshots.screenshots.length} 'before' screenshots`
      );
    }

    // Capture screenshots for head branch (after changes)
    await logToScreenshotCollector(
      `Capturing 'after' screenshots for head branch: ${headBranch}`
    );
    const afterScreenshots = await captureScreenshotsForBranch(
      isTaskRunJwtAuth(auth)
        ? {
          workspaceDir,
          changedFiles,
          prTitle,
          prDescription,
          branch: headBranch,
          outputDir,
          auth: { taskRunJwt: auth.taskRunJwt },
          pathToClaudeCodeExecutable: options.pathToClaudeCodeExecutable,
          setupScript: options.setupScript,
          installCommand: options.installCommand,
          devCommand: options.devCommand,
          convexSiteUrl: options.convexSiteUrl,
        }
        : {
          workspaceDir,
          changedFiles,
          prTitle,
          prDescription,
          branch: headBranch,
          outputDir,
          auth: { anthropicApiKey: auth.anthropicApiKey },
          pathToClaudeCodeExecutable: options.pathToClaudeCodeExecutable,
          setupScript: options.setupScript,
          installCommand: options.installCommand,
          devCommand: options.devCommand,
          convexSiteUrl: options.convexSiteUrl,
        }
    );
    allScreenshots.push(...afterScreenshots.screenshots);
    if (afterScreenshots.hasUiChanges !== undefined) {
      hasUiChanges = afterScreenshots.hasUiChanges;
    }
    await logToScreenshotCollector(
      `Captured ${afterScreenshots.screenshots.length} 'after' screenshots`
    );

    await logToScreenshotCollector(
      `Screenshot capture completed. Total: ${allScreenshots.length} screenshots saved to ${outputDir}`
    );
    log("INFO", "PR screenshot capture completed", {
      screenshotCount: allScreenshots.length,
      outputDir,
    });

    return {
      status: "completed",
      screenshots: allScreenshots,
      hasUiChanges,
    };
  } catch (error) {
    const message =
      error instanceof Error ? error.message : String(error ?? "unknown error");
    await logToScreenshotCollector(`PR screenshot capture failed: ${message}`);
    log("ERROR", "PR screenshot capture failed", {
      error: message,
    });
    return {
      status: "failed",
      error: message,
    };
  }
}

// Re-export utilities
export { logToScreenshotCollector } from "./logger";
export { formatClaudeMessage } from "./claudeMessageFormatter";

// CLI entry point - runs when executed directly
  const cliOptionsSchema = z.object({
    workspaceDir: z.string(),
    changedFiles: z.array(z.string()),
    prTitle: z.string(),
    prDescription: z.string(),
    baseBranch: z.string(),
    headBranch: z.string(),
    outputDir: z.string(),
    pathToClaudeCodeExecutable: z.string().optional(),
    setupScript: z.string().optional(),
    installCommand: z.string().optional(),
    devCommand: z.string().optional(),
    convexSiteUrl: z.string().optional(),
  auth: z.union([
    z.object({ taskRunJwt: z.string() }),
    z.object({ anthropicApiKey: z.string() }),
  ]),
});

async function main() {
  const optionsJson = process.env.SCREENSHOT_OPTIONS;
  if (!optionsJson) {
    console.error("SCREENSHOT_OPTIONS environment variable is required");
    process.exit(1);
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(optionsJson);
  } catch (error) {
    console.error("Failed to parse SCREENSHOT_OPTIONS as JSON:", error);
    process.exit(1);
  }

  const validated = cliOptionsSchema.safeParse(parsed);
  if (!validated.success) {
    console.error("Invalid SCREENSHOT_OPTIONS:", validated.error.format());
    process.exit(1);
  }

  const options = validated.data;
  const result = await claudeCodeCapturePRScreenshots(options as CaptureScreenshotsOptions);

  // Output result as JSON to stdout
  console.log(JSON.stringify(result));
}

// Check if running as CLI (not imported as module)
// Only run as CLI if SCREENSHOT_OPTIONS env var is set - this is the definitive signal
// that we're being run as a CLI, not imported as a module
const shouldRunAsCli = !!process.env.SCREENSHOT_OPTIONS;

if (shouldRunAsCli) {
  main().catch((error) => {
    console.error("CLI execution failed:", error);
    process.exit(1);
  });
}
