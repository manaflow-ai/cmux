#!/usr/bin/env bun
import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";

type Profile = "auto" | "gateway" | "direct";
type RuleSet = "all" | "focused" | "architecture";
type Args = {
  prNumber?: string;
  repo: string;
  diffFile?: string;
  base: string;
  head: string;
  outDir: string;
  profile: Profile;
  ruleSet: RuleSet;
  onlyRules: string[];
  envFiles: string[];
  maxTokens?: string;
  timeout?: string;
  maxDiffBytes?: string;
  retries?: string;
  mockResponse?: string;
  strict: boolean;
  postComment: boolean;
  failOnViolation: boolean;
};
type Job = {
  rule: string;
  provider: string;
  model: string;
  reasoningEffort?: string;
  thinking?: string;
  missingEnv?: string;
};
type LintResult = {
  rule_id: string;
  provider: string;
  model: string;
  violated: boolean;
  severity: "none" | "warning" | "failure";
  summary: string;
  findings: Array<{
    file: string;
    line: number | null;
    excerpt: string;
    why: string;
    confidence: string;
  }>;
  skipped?: boolean;
};

const FOCUSED_RULES = [
  "swift-concurrency-modernization",
  "swift-blocking-runtime",
  "swift-logging",
  "swiftui-state-layout",
  "swift-actor-isolation",
  "swift-concurrent-annotation",
];
const ARCHITECTURE_RULE = "swift-architectural-rethink";

function usage(): string {
  return [
    "Usage: bun scripts/llm_diff_lint_all.ts [--pr N | --diff-file FILE | --base REF --head REF]",
    "",
    "Options:",
    "  --profile auto|gateway|direct   Default: auto",
    "  --rule-set all|focused|architecture",
    "  --only-rule RULE_ID             Repeatable filter",
    "  --env-file FILE                 Repeatable .env loader, existing env wins",
    "  --out-dir DIR                   Default: tmp/llm-diff-lint/<source>",
    "  --strict                        Fail when a provider key is missing",
    "  --post-comment                  Post or update the PR comment, requires --pr",
    "  --no-fail-on-violation          Keep exit code 0 for lint failures",
    "  --mock-response JSON            Test mode, passed to every rule job",
  ].join("\n");
}

function parseArgs(argv: string[]): Args {
  const args: Args = {
    repo: process.env.GITHUB_REPOSITORY || "manaflow-ai/cmux",
    base: "origin/main",
    head: "HEAD",
    outDir: "",
    profile: "auto",
    ruleSet: "all",
    onlyRules: [],
    envFiles: [],
    strict: false,
    postComment: false,
    failOnViolation: true,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = () => {
      index += 1;
      if (index >= argv.length) {
        throw new Error(`missing value for ${arg}`);
      }
      return argv[index];
    };

    switch (arg) {
      case "-h":
      case "--help":
        console.log(usage());
        process.exit(0);
      case "--pr":
      case "--pr-number":
        args.prNumber = next();
        break;
      case "--repo":
        args.repo = next();
        break;
      case "--diff-file":
        args.diffFile = next();
        break;
      case "--base":
        args.base = next();
        break;
      case "--head":
        args.head = next();
        break;
      case "--out-dir":
        args.outDir = next();
        break;
      case "--profile": {
        const profile = next();
        if (profile !== "auto" && profile !== "gateway" && profile !== "direct") {
          throw new Error(`invalid profile: ${profile}`);
        }
        args.profile = profile;
        break;
      }
      case "--rule-set": {
        const ruleSet = next();
        if (ruleSet !== "all" && ruleSet !== "focused" && ruleSet !== "architecture") {
          throw new Error(`invalid rule set: ${ruleSet}`);
        }
        args.ruleSet = ruleSet;
        break;
      }
      case "--only-rule":
        args.onlyRules.push(next());
        break;
      case "--env-file":
        args.envFiles.push(next());
        break;
      case "--max-tokens":
        args.maxTokens = next();
        break;
      case "--timeout":
        args.timeout = next();
        break;
      case "--max-diff-bytes":
        args.maxDiffBytes = next();
        break;
      case "--retries":
        args.retries = next();
        break;
      case "--mock-response":
        args.mockResponse = next();
        break;
      case "--strict":
        args.strict = true;
        break;
      case "--post-comment":
        args.postComment = true;
        break;
      case "--no-fail-on-violation":
        args.failOnViolation = false;
        break;
      default:
        throw new Error(`unknown argument: ${arg}`);
    }
  }

  if (args.prNumber && args.prNumber.match(/[^0-9]/)) {
    throw new Error(`invalid pull request number: ${args.prNumber}`);
  }
  if ([args.prNumber, args.diffFile].filter(Boolean).length > 1) {
    throw new Error("use only one of --pr or --diff-file");
  }
  if (args.postComment && !args.prNumber) {
    throw new Error("--post-comment requires --pr");
  }
  return args;
}

function expandHome(filePath: string): string {
  if (filePath === "~") {
    return os.homedir();
  }
  if (filePath.startsWith("~/")) {
    return path.join(os.homedir(), filePath.slice(2));
  }
  return filePath;
}

function loadEnvFile(filePath: string): void {
  const resolved = path.resolve(expandHome(filePath));
  if (!existsSync(resolved)) {
    throw new Error(`env file does not exist: ${filePath}`);
  }
  for (const rawLine of readFileSync(resolved, "utf8").split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) {
      continue;
    }
    const normalized = line.startsWith("export ") ? line.slice("export ".length).trim() : line;
    const equals = normalized.indexOf("=");
    if (equals <= 0) {
      continue;
    }
    const key = normalized.slice(0, equals).trim();
    let value = normalized.slice(equals + 1).trim();
    if (!key.match(/^[A-Za-z_][A-Za-z0-9_]*$/) || process.env[key] !== undefined) {
      continue;
    }
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    process.env[key] = value;
  }
}

function safeName(value: string): string {
  return value.replace(/[^A-Za-z0-9_.-]+/g, "-").replace(/^-+|-+$/g, "");
}

function sourceSlug(args: Args): string {
  if (args.prNumber) {
    return `pr-${args.prNumber}`;
  }
  if (args.diffFile) {
    return `diff-${safeName(path.basename(args.diffFile)) || "file"}`;
  }
  return `git-${safeName(args.head) || "head"}`;
}

function resolveOutDir(args: Args): string {
  return path.resolve(args.outDir || path.join("tmp", "llm-diff-lint", sourceSlug(args)));
}

function fetchPrDiff(args: Args, outDir: string): string {
  const diffPath = path.join(outDir, "pr.diff");
  const diff = execFileSync("gh", ["pr", "diff", args.prNumber || "", "--repo", args.repo], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  writeFileSync(diffPath, diff);
  return diffPath;
}

function diffPathFor(args: Args, outDir: string): string | undefined {
  if (args.prNumber) {
    return fetchPrDiff(args, outDir);
  }
  if (args.diffFile) {
    return path.resolve(args.diffFile);
  }
  return undefined;
}

function selectedRules(args: Args): string[] {
  const rules =
    args.ruleSet === "focused"
      ? FOCUSED_RULES
      : args.ruleSet === "architecture"
        ? [ARCHITECTURE_RULE]
        : [...FOCUSED_RULES, ARCHITECTURE_RULE];
  if (args.onlyRules.length === 0) {
    return rules;
  }
  const allowed = new Set(args.onlyRules);
  return rules.filter((rule) => allowed.has(rule));
}

function resolveProfile(args: Args): Exclude<Profile, "auto"> {
  if (args.profile !== "auto") {
    return args.profile;
  }
  return process.env.AI_GATEWAY_API_KEY ? "gateway" : "direct";
}

function missingEnvFor(job: Job): string | undefined {
  if (job.provider === "gateway" && !process.env.AI_GATEWAY_API_KEY) {
    return "AI_GATEWAY_API_KEY";
  }
  if (job.provider === "deepseek" && !process.env.DEEPSEEK_API_KEY) {
    return "DEEPSEEK_API_KEY";
  }
  if (job.provider === "google-vertex" && !process.env.GOOGLE_VERTEX_PROJECT && !process.env.GOOGLE_CLOUD_PROJECT) {
    return "GOOGLE_VERTEX_PROJECT or GOOGLE_CLOUD_PROJECT";
  }
  if (job.provider === "openai" && !process.env.OPENAI_API_KEY) {
    return "OPENAI_API_KEY";
  }
  return undefined;
}

function buildJobs(args: Args): Job[] {
  const profile = resolveProfile(args);
  const rules = selectedRules(args);
  const focusedRules = rules.filter((rule) => rule !== ARCHITECTURE_RULE);
  const includeArchitecture = rules.includes(ARCHITECTURE_RULE);
  const jobs: Job[] = [];

  if (profile === "gateway") {
    for (const rule of focusedRules) {
      jobs.push({ rule, provider: "gateway", model: "deepseek/deepseek-v4-pro" });
      jobs.push({ rule, provider: "gateway", model: "google/gemini-3-flash" });
    }
    if (includeArchitecture) {
      jobs.push({
        rule: ARCHITECTURE_RULE,
        provider: "gateway",
        model: process.env.LLM_DIFF_LINT_CODEX_MODEL || "openai/gpt-5.3-codex",
        reasoningEffort: process.env.LLM_DIFF_LINT_CODEX_REASONING_EFFORT || "medium",
      });
    }
  } else {
    for (const rule of focusedRules) {
      jobs.push({
        rule,
        provider: "deepseek",
        model: "deepseek-v4-pro",
        thinking: process.env.LLM_DIFF_LINT_THINKING || process.env.DEEPSEEK_THINKING || "disabled",
      });
      jobs.push({ rule, provider: "google-vertex", model: "gemini-3-flash-preview" });
    }
    if (includeArchitecture) {
      jobs.push({
        rule: ARCHITECTURE_RULE,
        provider: "openai",
        model: process.env.LLM_DIFF_LINT_CODEX_MODEL || "gpt-5.3-codex",
        reasoningEffort: process.env.LLM_DIFF_LINT_CODEX_REASONING_EFFORT || "medium",
      });
    }
  }

  return jobs.map((job) => ({ ...job, missingEnv: args.mockResponse ? undefined : missingEnvFor(job) }));
}

function skippedResult(job: Job): LintResult {
  return {
    rule_id: job.rule,
    provider: job.provider,
    model: job.model,
    violated: false,
    severity: "none",
    summary: `${job.missingEnv || "provider credentials"} is not set, skipped.`,
    findings: [],
    skipped: true,
  };
}

function writeSkippedResult(job: Job, resultFile: string): void {
  const result = skippedResult(job);
  const json = `${JSON.stringify(result, null, 2)}\n`;
  writeFileSync(resultFile, json);
  process.stdout.write(json);
}

function runJob(job: Job, args: Args, outDir: string, diffFile: string | undefined): number {
  const rulePath = path.join(".github", "llm-diff-lint", "rules", `${job.rule}.md`);
  const artifactDir = path.join(outDir, `llm-diff-lint-${safeName(job.provider)}-${safeName(job.model)}-${job.rule}`);
  mkdirSync(artifactDir, { recursive: true });
  const resultFile = path.join(artifactDir, "result.json");

  if (job.missingEnv) {
    if (args.strict) {
      console.error(`${job.provider}/${job.rule}: ${job.missingEnv} is required`);
      return 2;
    }
    writeSkippedResult(job, resultFile);
    return 0;
  }

  const commandArgs = [
    "scripts/llm_diff_lint.ts",
    "--rule",
    rulePath,
    "--source-label",
    args.prNumber ? `pull request ${args.prNumber}` : args.diffFile ? `diff file ${args.diffFile}` : `git diff ${args.base}...${args.head}`,
    "--provider",
    job.provider,
    "--model",
    job.model,
    "--output",
    resultFile,
  ];
  if (diffFile) {
    commandArgs.push("--diff-file", diffFile);
  } else {
    commandArgs.push("--base", args.base, "--head", args.head);
  }
  if (job.reasoningEffort) {
    commandArgs.push("--reasoning-effort", job.reasoningEffort);
  }
  if (job.thinking) {
    commandArgs.push("--thinking", job.thinking);
  }
  if (args.maxTokens) {
    commandArgs.push("--max-tokens", args.maxTokens);
  }
  if (args.timeout) {
    commandArgs.push("--timeout", args.timeout);
  }
  if (args.maxDiffBytes) {
    commandArgs.push("--max-diff-bytes", args.maxDiffBytes);
  }
  if (args.retries) {
    commandArgs.push("--retries", args.retries);
  }
  if (args.mockResponse) {
    commandArgs.push("--mock-response", args.mockResponse);
  }

  console.error(`Running ${job.provider}/${job.model} on ${job.rule}`);
  const child = spawnSync("bun", commandArgs, {
    cwd: process.cwd(),
    env: process.env,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (child.stdout) {
    process.stdout.write(child.stdout);
  }
  if (child.stderr) {
    process.stderr.write(child.stderr);
  }
  return child.status ?? 2;
}

function commentArgs(args: Args, outDir: string): string[] {
  const prNumber = args.prNumber || "0";
  const prUrl = args.prNumber ? `https://github.com/${args.repo}/pull/${args.prNumber}` : "local";
  const diffUrl = args.prNumber ? `https://github.com/${args.repo}/pull/${args.prNumber}.diff` : "local";
  return [
    "scripts/llm_diff_lint_comment.py",
    "--results-dir",
    outDir,
    "--pr-number",
    prNumber,
    "--pr-url",
    prUrl,
    "--diff-url",
    diffUrl,
    "--run-url",
    "local llm_diff_lint_all.ts",
    ...(args.postComment ? [] : ["--dry-run"]),
  ];
}

function writeComment(args: Args, outDir: string): number {
  const env = { ...process.env, GITHUB_REPOSITORY: args.repo };
  if (args.postComment && !env.GH_TOKEN && !env.GITHUB_TOKEN) {
    env.GH_TOKEN = execFileSync("gh", ["auth", "token"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
  }
  const child = spawnSync("python3", commentArgs(args, outDir), {
    cwd: process.cwd(),
    env,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (child.stderr) {
    process.stderr.write(child.stderr);
  }
  if (child.stdout) {
    const commentFile = path.join(outDir, "comment.md");
    writeFileSync(commentFile, child.stdout);
    process.stdout.write(child.stdout);
    console.error(`Wrote ${commentFile}`);
  }
  return child.status ?? 2;
}

function main(argv: string[]): number {
  let args: Args;
  try {
    args = parseArgs(argv);
    for (const envFile of args.envFiles) {
      loadEnvFile(envFile);
    }
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    console.error(usage());
    return 2;
  }

  const outDir = resolveOutDir(args);
  mkdirSync(outDir, { recursive: true });
  const diffFile = diffPathFor(args, outDir);
  const jobs = buildJobs(args);
  if (jobs.length === 0) {
    console.error("No lint jobs selected.");
    return 2;
  }

  let worstCode = 0;
  for (const job of jobs) {
    const code = runJob(job, args, outDir, diffFile);
    if (code > 1) {
      worstCode = 2;
    } else if (code === 1 && worstCode === 0) {
      worstCode = 1;
    }
  }

  const commentCode = writeComment(args, outDir);
  if (commentCode !== 0) {
    worstCode = 2;
  }

  console.error(`Results directory: ${outDir}`);
  if (!args.failOnViolation && worstCode === 1) {
    return 0;
  }
  return worstCode;
}

process.exitCode = main(process.argv.slice(2));
