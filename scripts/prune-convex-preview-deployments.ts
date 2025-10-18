#!/usr/bin/env bun

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
  readonly minAgeDays?: string;
  readonly exclude?: string[];
  readonly dryRun?: boolean;
};

const DEFAULT_MIN_AGE_DAYS = 7;

const program = new Command()
  .name("prune-convex-preview-deployments")
  .description(
    "Delete Convex preview deployments that are older than a threshold and lack an open GitHub pull request.",
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
    "--min-age-days <days>",
    `Minimum age in days before a preview becomes eligible for deletion (default ${DEFAULT_MIN_AGE_DAYS}).`,
  )
  .option(
    "--exclude <deployment...>",
    "Deployment names to always skip (repeatable).",
  )
  .option("--dry-run", "Show which previews would be deleted without deleting.");

async function main() {
  program.parse();
  const options = program.opts<Options>();

  const rawToken = options.token ?? process.env.CONVEX_MANAGEMENT_TOKEN ?? "";

  let optionTeamId: number | null = null;
  let optionProjectId: number | null = null;
  let minAgeDays: number = DEFAULT_MIN_AGE_DAYS;
  try {
    optionTeamId = parseIntegerOption("team-id", options.teamId);
    optionProjectId = parseIntegerOption("project-id", options.projectId);
    const parsedMinAge = parseIntegerOption("min-age-days", options.minAgeDays);
    if (parsedMinAge !== null) {
      minAgeDays = parsedMinAge;
    }
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  }

  if (minAgeDays < 0) {
    console.error("min-age-days must be non-negative.");
    process.exit(1);
  }

  const optionProjectSlug =
    options.projectSlug === undefined ? null : options.projectSlug;

  const githubRepoInput =
    options.githubRepo ??
    process.env.GITHUB_REPO ??
    process.env.GITHUB_REPOSITORY ??
    "manaflow-ai/cmux";

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

  const excludeSet = new Set<string>([
    "adorable-wombat-701",
    "polite-canary-804",
    "famous-camel-162",
    ...(Array.isArray(options.exclude) ? options.exclude : []),
  ]);

  try {
    const previews = await fetchPreviewDeployments({
      token: rawToken,
      baseUrl: options.baseUrl,
      teamId: optionTeamId,
      projectId: optionProjectId,
      projectSlug: optionProjectSlug,
      github: githubConfig,
    });

    if (previews.length === 0) {
      console.log("No preview deployments found for the provided scope.");
      return;
    }

    const now = Date.now();
    const cutoffMs = minAgeDays * 24 * 60 * 60 * 1000;

    const candidates = previews.filter((preview) =>
      shouldDelete(preview, cutoffMs, now, excludeSet),
    );

    if (candidates.length === 0) {
      console.log(
        `No preview deployments older than ${minAgeDays} day(s) matched the deletion criteria.`,
      );
      return;
    }

    console.log(
      `Found ${candidates.length} preview deployment(s) older than ${minAgeDays} day(s) with no open pull request:`,
    );
    for (const candidate of candidates) {
      const createdAt = candidate.createdAt;
      const identifier =
        candidate.previewIdentifier ?? "no preview identifier";
      const github = candidate.github;
      const parts = [`created ${createdAt}`];
      if (github) {
        parts.push(
          github.branchExists
            ? `branch ${github.branchName} exists`
            : `branch ${github.branchName} missing`,
        );
        if (github.pullRequest) {
          const pr = github.pullRequest;
          parts.push(`PR #${pr.number} ${pr.state}`);
        } else {
          parts.push("no pull request");
        }
      } else {
        parts.push("GitHub status unavailable");
      }
      console.log(
        `  • ${candidate.deploymentName} (${identifier}) — ${parts.join(", ")}`,
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
    for (const preview of candidates) {
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
  } catch (error) {
    if (error instanceof TokenError) {
      console.error(error.message);
      process.exit(1);
    }
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  }
}

function shouldDelete(
  preview: PreviewDeploymentRecord,
  cutoffMs: number,
  nowMs: number,
  exclude: Set<string>,
): boolean {
  if (preview.previewIdentifier === null) {
    return false;
  }
  if (exclude.has(preview.deploymentName)) {
    return false;
  }
  const createdTime = Date.parse(preview.createdAt);
  if (!Number.isFinite(createdTime)) {
    return false;
  }
  if (nowMs - createdTime < cutoffMs) {
    return false;
  }

  const github = preview.github;
  if (!github) {
    return true;
  }

  if (!github.branchExists) {
    return true;
  }

  const pullRequest = github.pullRequest;
  if (!pullRequest) {
    return true;
  }

  if (pullRequest.state === "open") {
    return false;
  }

  return true;
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
