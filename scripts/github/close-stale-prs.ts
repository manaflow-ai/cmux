#!/usr/bin/env bun
import type { Buffer } from "node:buffer";
import { spawn } from "node:child_process";
import process from "node:process";

// Closes inactive pull requests in the current repository using the GitHub CLI.
// Usage: bun run scripts/github/close-stale-prs.ts [--dry-run] [--days <n>] [--comment <text>]

type PullRequest = {
  number: number;
  title: string;
  url: string;
  createdAt: string;
  lastCommitAt: string;
};

type BasePullRequest = {
  number: number;
  title: string;
  url: string;
  createdAt: string;
  headSha: string | null;
};

type Options = {
  dryRun: boolean;
  inactivityDays: number;
  comment: string | null;
};

const MS_PER_DAY = 24 * 60 * 60 * 1000;

async function main() {
  const options = parseOptions(process.argv.slice(2));
  const repoPulls = await fetchOpenPullRequests();
  const stalePulls = filterStalePullRequests(repoPulls, options.inactivityDays);

  if (stalePulls.length === 0) {
    console.log(`No pull requests exceeded ${options.inactivityDays} days without activity.`);
    return;
  }

  console.log(`Found ${stalePulls.length} inactive pull request(s) to close.`);
  for (const pull of stalePulls) {
    if (options.dryRun) {
      console.log(`[dry-run] Would close PR #${pull.number}: ${pull.title} (${pull.url})`);
      continue;
    }
    await closePullRequest(pull, options);
  }
}

function parseOptions(args: string[]): Options {
  let dryRun = false;
  let inactivityDays = 7;
  let comment: string | null = null;

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--dry-run") {
      dryRun = true;
      continue;
    }
    if (arg === "--days") {
      const value = args[index + 1];
      if (!value) {
        throw new Error("Missing value for --days");
      }
      const parsed = Number.parseInt(value, 10);
      if (Number.isNaN(parsed) || parsed <= 0) {
        throw new Error("--days must be a positive integer");
      }
      inactivityDays = parsed;
      index += 1;
      continue;
    }
    if (arg === "--comment") {
      const value = args[index + 1];
      if (!value) {
        throw new Error("Missing value for --comment");
      }
      comment = value;
      index += 1;
      continue;
    }
    throw new Error(`Unknown option '${arg}'`);
  }

  return { dryRun, inactivityDays, comment };
}

async function fetchOpenPullRequests(): Promise<PullRequest[]> {
  const repo = await resolveRepoSlug();
  const { stdout } = await runGh([
    "pr",
    "list",
    "--state",
    "open",
    "--limit",
    "1000",
    "--json",
    "number,title,url,createdAt,headRefOid",
  ]);
  const basePulls = parsePullRequestList(stdout);
  if (basePulls.length === 0) {
    return [];
  }
  const enriched = await mapWithConcurrency(basePulls, 6, async (pull) => {
    const lastCommitAt = (await fetchLastCommitAt(repo, pull.headSha)) ?? pull.createdAt;
    return { ...pull, lastCommitAt };
  });
  return enriched;
}

function parsePullRequestList(rawJson: string): BasePullRequest[] {
  let parsed: unknown;
  try {
    parsed = JSON.parse(rawJson);
  } catch (error) {
    throw new Error(`Failed to parse GitHub CLI response: ${String(error)}`);
  }
  if (!Array.isArray(parsed)) {
    throw new Error("Unexpected GitHub CLI response: expected an array");
  }
  return parsed.map((item, index) => mapGhPullToBasePull(item, index));
}

function filterStalePullRequests(pulls: PullRequest[], inactivityDays: number): PullRequest[] {
  const now = Date.now();
  const thresholdMs = inactivityDays * MS_PER_DAY;

  return pulls.filter((pull) => {
    const createdAt = Date.parse(pull.createdAt);
    const lastCommitAt = Date.parse(pull.lastCommitAt);
    if (Number.isNaN(createdAt) || Number.isNaN(lastCommitAt)) {
      return false;
    }
    const age = now - createdAt;
    const inactiveDuration = now - lastCommitAt;
    return age >= thresholdMs && inactiveDuration >= thresholdMs;
  });
}

async function closePullRequest(pull: PullRequest, options: Options): Promise<void> {
  const comment = options.comment ?? `Closing this pull request because it has had no activity for ${options.inactivityDays} day(s). Please reopen or create a new PR if you plan to continue working on it.`;
  const args = ["pr", "close", pull.number.toString(), "--comment", comment];
  console.log(`Closing PR #${pull.number}: ${pull.title}`);
  await runGh(args);
  console.log(`Closed PR #${pull.number}`);
}

function isPullRequest(value: unknown): value is Record<string, unknown> {
  if (!isRecord(value)) {
    return false;
  }
  const candidate = value;
  const numberField = candidate["number"];
  const titleField = candidate["title"];
  const urlField = candidate["url"];
  const createdField = candidate["createdAt"];
  const headField = candidate["headRefOid"];
  return (
    typeof numberField === "number" &&
    typeof titleField === "string" &&
    typeof urlField === "string" &&
    typeof createdField === "string" &&
    (typeof headField === "string" || headField === null || headField === undefined)
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function mapGhPullToBasePull(value: unknown, index: number): BasePullRequest {
  if (!isPullRequest(value)) {
    throw new Error(`Unexpected pull request payload at index ${index}`);
  }
  return {
    number: value["number"] as number,
    title: value["title"] as string,
    url: value["url"] as string,
    createdAt: value["createdAt"] as string,
    headSha: typeof value["headRefOid"] === "string" ? (value["headRefOid"] as string) : null,
  };
}

let cachedRepoSlug: string | null = null;

async function runGh(args: string[]): Promise<{ stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn("gh", args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";

    child.stdout?.on("data", (chunk: Buffer) => {
      stdout += chunk.toString("utf8");
    });
    child.stderr?.on("data", (chunk: Buffer) => {
      stderr += chunk.toString("utf8");
    });

    child.on("error", (error) => {
      reject(error);
    });

    child.on("close", (code) => {
      if (code === 0) {
        resolve({ stdout, stderr });
        return;
      }
      const message = [`gh ${args.join(" ")} exited with code ${code}`];
      if (stderr.trim().length > 0) {
        message.push(stderr.trim());
      }
      reject(new Error(message.join(": ")));
    });
  });
}

await main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});

async function resolveRepoSlug(): Promise<string> {
  if (cachedRepoSlug) {
    return cachedRepoSlug;
  }
  const { stdout } = await runGh(["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]);
  const slug = stdout.trim();
  if (!slug) {
    throw new Error("Failed to determine repository name");
  }
  cachedRepoSlug = slug;
  return slug;
}

async function fetchLastCommitAt(repoSlug: string, headSha: string | null): Promise<string | null> {
  if (!headSha) {
    return null;
  }
  const endpoint = `repos/${repoSlug}/commits/${headSha}`;
  const { stdout } = await runGh(["api", endpoint, "--jq", ".commit.committer.date // .commit.author.date"]);
  const trimmed = stdout.trim();
  return trimmed.length === 0 ? null : trimmed;
}

async function mapWithConcurrency<T, U>(
  items: readonly T[],
  limit: number,
  mapper: (item: T, index: number) => Promise<U>,
): Promise<U[]> {
  if (items.length === 0) {
    return [];
  }
  const max = Math.max(1, Math.min(limit, items.length));
  const results: U[] = new Array(items.length);
  let nextIndex = 0;

  async function worker(): Promise<void> {
    while (true) {
      const current = nextIndex;
      if (current >= items.length) {
        break;
      }
      nextIndex += 1;
      results[current] = await mapper(items[current], current);
    }
  }

  const workers = Array.from({ length: max }, () => worker());
  await Promise.all(workers);
  return results;
}
