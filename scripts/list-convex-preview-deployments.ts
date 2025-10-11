import { Command } from "commander";

import {
  DEFAULT_BASE_URL,
  fetchPreviewDeployments,
  parseGitHubRepo,
  TokenError,
  type GitHubConfig,
} from "./lib/convexPreviews.js";

type Options = {
  readonly token?: string;
  readonly baseUrl?: string;
  readonly teamId?: string;
  readonly projectId?: string;
  readonly projectSlug?: string;
  readonly json?: boolean;
  readonly githubRepo?: string;
  readonly githubToken?: string;
  readonly githubBranchPrefix?: string;
};

const program = new Command()
  .name("list-convex-preview-deployments")
  .description(
    "List Convex preview deployments available to a management API token.",
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
    "Optional GitHub repository to cross-reference preview identifiers against branch and PR status.",
  )
  .option(
    "--github-token <token>",
    "GitHub personal access token. Defaults to GITHUB_TOKEN env var.",
  )
  .option(
    "--github-branch-prefix <prefix>",
    "Prefix to strip from preview identifiers before matching GitHub branch names.",
  )
  .option("--json", "Emit JSON output instead of formatted text.");

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
  const githubBranchPrefix = options.githubBranchPrefix ?? "";
  const githubToken =
    options.githubToken ?? process.env.GITHUB_TOKEN ?? null;

  let githubConfig: GitHubConfig | null = null;
  if (githubRepoInput) {
    try {
      const { owner, repo } = parseGitHubRepo(githubRepoInput);
      githubConfig = {
        owner,
        repo,
        branchPrefix: githubBranchPrefix,
        token:
          githubToken !== null && githubToken.trim().length > 0
            ? githubToken.trim()
            : null,
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
  }

  try {
    const previews = await fetchPreviewDeployments({
      token: rawToken,
      baseUrl: options.baseUrl,
      teamId: optionTeamId,
      projectId: optionProjectId,
      projectSlug: optionProjectSlug,
      github: githubConfig,
    });

    if (options.json) {
      console.log(JSON.stringify(previews, null, 2));
      return;
    }

    if (previews.length === 0) {
      console.log("No preview deployments found for the provided scope.");
      return;
    }

    const rowsByProject = new Map<number, typeof previews>();
    for (const row of previews) {
      const current = rowsByProject.get(row.projectId) ?? [];
      current.push(row);
      rowsByProject.set(row.projectId, current);
    }

    for (const [projectId, rows] of rowsByProject) {
      const projectLabel =
        rows[0]?.projectName && rows[0].projectName !== `Project ${projectId}`
          ? `${rows[0]?.projectName} (${rows[0]?.projectSlug ?? "slug unavailable"})`
          : `Project ${projectId}`;
      console.log(`Preview deployments for ${projectLabel}:`);
      for (const row of rows) {
        const parts: string[] = [];
        if (row.previewIdentifier === null) {
          parts.push("no identifier reported");
        } else {
          parts.push(`identifier ${row.previewIdentifier}`);
        }
        if (githubConfig !== null) {
          if (row.previewIdentifier === null) {
            parts.push("GitHub lookup skipped");
          } else if (row.github == null) {
            parts.push("GitHub lookup unavailable");
          } else {
            const github = row.github;
            const branchDescriptor = github.branchExists
              ? `branch ${github.branchName} exists`
              : `branch ${github.branchName} missing`;
            parts.push(branchDescriptor);
            if (github.pullRequest) {
              const pr = github.pullRequest;
              const prState =
                pr.state === "merged"
                  ? "merged"
                  : pr.state === "closed"
                    ? "closed"
                    : "open";
              parts.push(`PR #${pr.number} ${prState}`);
            } else {
              parts.push("no matching PR found");
            }
          }
        }
        parts.push(`created ${row.createdAt}`);
        console.log(`  • ${row.deploymentName} (${parts.join(", ")})`);
      }
    }
  } catch (error) {
    if (error instanceof TokenError) {
      console.error(error.message);
      process.exit(1);
    }
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  }
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

if (import.meta.main) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  });
}
