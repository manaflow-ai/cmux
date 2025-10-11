import { Command } from "commander";
import readline from "node:readline/promises";
import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import {
  DEFAULT_BASE_URL,
  deletePreviewDeployment,
  fetchPreviewDeployments,
  parseGitHubRepo,
  TokenError,
  type GitHubConfig,
  type PreviewDeploymentRecord,
} from "./lib/convexPreviews.js";

type Options = {
  readonly token?: string;
  readonly baseUrl?: string;
  readonly teamId?: string;
  readonly projectId?: string;
  readonly projectSlug?: string;
  readonly githubRepo?: string;
  readonly githubToken?: string;
  readonly githubBranchPrefix?: string;
  readonly dryRun?: boolean;
};

const program = new Command()
  .name("cleanup-convex-preview-deployments")
  .description(
    "Delete Convex preview deployments whose associated GitHub pull requests are not open.",
  )
  .option(
    "--token <token>",
    "Management API token. Defaults to CONVEX_MANAGEMENT_TOKEN env var.",
  )
  .option(
    "--base-url <url>",
    "Convex management API base URL.",
    DEFAULT_BASE_URL,
  )
  .option(
    "--team-id <id>",
    "Numeric team ID to scope queries. Auto-detected for team tokens when omitted.",
  )
  .option(
    "--project-id <id>",
    "Numeric project ID to filter results. Defaults to the token's project for project tokens.",
  )
  .option(
    "--project-slug <slug>",
    "Project slug to filter results (team tokens only).",
  )
  .option(
    "--github-repo <owner/repo>",
    "GitHub repository used for branch and PR lookups (required).",
  )
  .option(
    "--github-token <token>",
    "GitHub personal access token. Defaults to GITHUB_TOKEN env var or gh auth token.",
  )
  .option(
    "--github-branch-prefix <prefix>",
    "Prefix to strip from preview identifiers before matching GitHub branch names.",
  )
  .option(
    "--dry-run",
    "Show which previews would be deleted without performing deletions.",
  );

async function main() {
  program.parse();
  const options = program.opts<Options>();

  const rawToken = options.token ?? process.env.CONVEX_MANAGEMENT_TOKEN ?? "";

  let optionTeamId: number | null = null;
  let optionProjectId: number | null = null;
  try {
    optionTeamId = parseIntegerOption("team-id", options.teamId);
    optionProjectId = parseIntegerOption("project-id", options.projectId);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  }

  const optionProjectSlug =
    options.projectSlug === undefined ? null : options.projectSlug;

  const githubRepoInput =
    options.githubRepo ??
    process.env.GITHUB_REPO ??
    process.env.GITHUB_REPOSITORY ??
    null;

  if (!githubRepoInput) {
    console.error(
      "A GitHub repository must be specified via --github-repo or GITHUB_REPO.",
    );
    process.exit(1);
  }

  const githubBranchPrefix = options.githubBranchPrefix ?? "";
  const githubToken =
    options.githubToken ??
    process.env.GITHUB_TOKEN ??
    (await readGhCliTokenOrNull());

  let githubConfig: GitHubConfig;
  try {
    const { owner, repo } = parseGitHubRepo(githubRepoInput);
    githubConfig = {
      owner,
      repo,
      branchPrefix: githubBranchPrefix,
      token: githubToken?.trim()?.length ? githubToken.trim() : null,
      onError: (identifier, error) => {
        console.error(
          `GitHub lookup failed for preview identifier "${identifier}": ${
            error instanceof Error ? error.message : String(error)
          }`,
        );
      },
    };
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  }

  let previews: PreviewDeploymentRecord[];
  try {
    previews = await fetchPreviewDeployments({
      token: rawToken,
      baseUrl: options.baseUrl,
      teamId: optionTeamId,
      projectId: optionProjectId,
      projectSlug: optionProjectSlug,
      github: githubConfig,
    });
  } catch (error) {
    if (error instanceof TokenError) {
      console.error(error.message);
      process.exit(1);
    }
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  }

  if (previews.length === 0) {
    console.log("No preview deployments found for the provided scope.");
    return;
  }

  const candidates = previews.filter((preview) => {
    const prState = preview.github?.pullRequest?.state;
    return (
      preview.previewIdentifier !== null &&
      preview.github !== null &&
      preview.github !== undefined &&
      preview.github.pullRequest !== undefined &&
      prState !== "open" &&
      prState !== undefined
    );
  });

  if (candidates.length === 0) {
    console.log(
      "No preview deployments with closed or merged pull requests were found.",
    );
    return;
  }

  console.log(
    `Found ${candidates.length} preview deployment(s) with closed or merged pull requests (out of ${previews.length} total previews).`,
  );

  for (const preview of candidates) {
    const pr = preview.github?.pullRequest;
    const prInfo =
      pr === undefined
        ? "no PR found"
        : `PR #${pr.number} ${pr.state}${
            pr.state === "merged" && pr.mergedAt
              ? ` at ${pr.mergedAt}`
              : pr.state === "closed" && pr.closedAt
                ? ` at ${pr.closedAt}`
                : ""
          }`;
    console.log(
      `  • ${preview.deploymentName} (${preview.previewIdentifier}) — ${prInfo}; created ${preview.createdAt}`,
    );
  }

  let dashboardAccessToken =
    process.env.CONVEX_DASHBOARD_ACCESS_TOKEN ??
    (await readConvexCliAccessToken());
  if (!dashboardAccessToken) {
    console.error(
      "Unable to locate a Convex dashboard access token. Set CONVEX_DASHBOARD_ACCESS_TOKEN or run `npx convex login` to populate ~/.convex/config.json.",
    );
    return;
  }
  dashboardAccessToken = dashboardAccessToken.trim();
  if (dashboardAccessToken.length === 0) {
    console.error(
      "Convex dashboard access token is empty. Aborting without deletions.",
    );
    return;
  }

  if (options.dryRun) {
    console.log("Dry run enabled; no deletions will be performed.");
    return;
  }

  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });

  try {
    const answer = await rl.question(
      "Press Enter to delete these preview deployments (Ctrl+C to abort)...",
    );
    if (answer.trim().length > 0) {
      console.log("Aborting because input was not empty.");
      return;
    }
  } finally {
    rl.close();
  }

  let successCount = 0;
  let failureCount = 0;
  for (const preview of dedupeCandidates(candidates)) {
    if (preview.previewIdentifier === null) {
      continue;
    }
    try {
      await deletePreviewDeployment({
        auth: { kind: "dashboard", token: dashboardAccessToken },
        baseUrl: options.baseUrl,
        projectId: preview.projectId,
        identifier: preview.previewIdentifier,
      });
      successCount += 1;
      console.log(
        `Deleted preview ${preview.previewIdentifier} (${preview.deploymentName}).`,
      );
    } catch (error) {
      failureCount += 1;
      console.error(
        `Failed to delete preview ${preview.previewIdentifier}: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
    }
  }

  console.log(
    `Deletion complete. Successes: ${successCount}, Failures: ${failureCount}.`,
  );
}

function parseIntegerOption(
  optionName: string,
  value?: string,
): number | null {
  if (value === undefined) {
    return null;
  }
  const parsed = Number.parseInt(value, 10);
  if (!Number.isInteger(parsed) || parsed < 0) {
    throw new Error(`Expected ${optionName} to be a non-negative integer.`);
  }
  return parsed;
}

function dedupeCandidates(
  previews: PreviewDeploymentRecord[],
): PreviewDeploymentRecord[] {
  const seen = new Set<string>();
  const result: PreviewDeploymentRecord[] = [];
  for (const preview of previews) {
    if (preview.previewIdentifier === null) {
      continue;
    }
    const key = `${preview.projectId}:${preview.previewIdentifier}`;
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    result.push(preview);
  }
  return result;
}

async function readGhCliTokenOrNull(): Promise<string | null> {
  return await new Promise((resolve) => {
    const child = spawn("gh", ["auth", "token"], {
      stdio: ["ignore", "pipe", "ignore"],
    });
    let output = "";
    child.stdout.on("data", (chunk: Buffer) => {
      output += chunk.toString();
    });
    child.on("error", () => resolve(null));
    child.on("close", (code) => {
      if (code === 0) {
        resolve(output.trim());
      } else {
        resolve(null);
      }
    });
  });
}

async function readConvexCliAccessToken(): Promise<string | null> {
  try {
    const configPath = path.join(os.homedir(), ".convex", "config.json");
    const raw = await fs.readFile(configPath, "utf8");
    const parsed = JSON.parse(raw) as { accessToken?: unknown };
    if (typeof parsed.accessToken === "string") {
      return parsed.accessToken;
    }
    return null;
  } catch {
    return null;
  }
}

if (import.meta.main) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  });
}
