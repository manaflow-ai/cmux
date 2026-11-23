// The Cloud journey's GitHub cells: the team connection read (GET /v1/integrations/github/status and /repos), the
// live cells of cloud-github-e2e.sh (against a local bare repository and a fake gh), its --agent-pr read back, and
// the journey steps that run them (the fake Cloud API of cloud-journey-fake.ts). No network, no secret.
import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  GITHUB_AGENT_STEP,
  GITHUB_E2E_SH,
  GITHUB_STATUS_STEP,
  e2eLines,
  githubAgentAsk,
  githubConnectionBlocker,
  githubConnectionDetail,
  githubConnectionFacts,
  githubSandbox,
} from "./cloud-journey";
import { runJourney } from "./cloud-journey-fake";

const SANDBOX = "sandbox-org/cmux-cloud-e2e";
const ACTIVE = { configured: true, app_slug: "cmux-cloud", allowed: true, connection: { id: "conn_x", account: "sandbox-org", status: "active", repos: [SANDBOX, "sandbox-org/other-private"] } };
const LISTED = { repos: [{ full_name: SANDBOX, private: true }, { full_name: "sandbox-org/other-private", private: true }, { full_name: "sandbox-org/site", private: false }], cursor: null };

describe("the team's GitHub connection, as counts", () => {
  test("connected, with the sandbox listed and private; no other repository name in the detail", () => {
    const f = githubConnectionFacts(ACTIVE, LISTED, SANDBOX);
    expect(f).toEqual({ configured: true, allowed: true, connected: true, account: "sandbox-org", status: "active", selected: 2, listed: 3, private_listed: 2, sandbox_listed: true, sandbox_private: true });
    const detail = githubConnectionDetail(f);
    expect(detail).toBe("connected yes, App configured yes, policy allows yes, connection active, installation account sandbox-org, repos selected 2, listed 3 (private 2), sandbox listed yes (private yes)");
    expect(detail).not.toContain("other-private");
    expect(detail).not.toContain("site");
    expect(githubConnectionBlocker(f, SANDBOX)).toBeNull();
  });

  test("no connection: what the hourly run records, and the blocker once a sandbox is named", () => {
    const f = githubConnectionFacts({ configured: true, app_slug: "cmux-cloud", allowed: true, connection: null }, null);
    expect(githubConnectionDetail(f)).toBe("connected no, App configured yes, policy allows yes, connection none, installation account none, repos selected ?, listed ? (private ?)");
    expect(githubConnectionBlocker(f, SANDBOX)).toContain("no active GitHub connection");
    expect(githubConnectionBlocker(githubConnectionFacts({ configured: false }, null), SANDBOX)).toContain("no GitHub App configured");
    expect(githubConnectionBlocker(githubConnectionFacts({ ...ACTIVE, allowed: false }, null), SANDBOX)).toContain("policy");
  });

  test("an installation on all repositories, a sandbox it does not list, a public sandbox", () => {
    const all = githubConnectionFacts({ ...ACTIVE, connection: { ...ACTIVE.connection, repos: null } }, { repos: [{ full_name: "sandbox-org/a", private: true }] }, SANDBOX);
    expect(all.selected).toBe("all");
    expect(githubConnectionBlocker(all, SANDBOX)).toContain("does not list");
    const pub = githubConnectionFacts(ACTIVE, { repos: [{ full_name: SANDBOX.toUpperCase(), private: false }] }, SANDBOX);
    expect(pub.sandbox_listed).toBe(true);
    expect(githubConnectionBlocker(pub, SANDBOX)).toContain("is public");
  });

  test("an account that is not a GitHub login is not printed", () => {
    expect(githubConnectionFacts({ ...ACTIVE, connection: { ...ACTIVE.connection, account: "ghs_x y/z" } }, null).account).toBeNull();
  });

  test("CMUX_JOURNEY_GITHUB_REPO must be OWNER/REPO", () => {
    expect(githubSandbox(` ${SANDBOX} `)).toBe(SANDBOX);
    for (const bad of [undefined, "", "repo", "a/b/c", "a/b;rm", "https://github.com/a/b"]) expect(githubSandbox(bad)).toBeNull();
  });

  test("the agent's ask names the sandbox, a branch and a file the read back checks", () => {
    const ask = githubAgentAsk(SANDBOX, "jr-abc_1");
    expect(ask.branch).toBe("cmux-agent-e2e/jr-abc-1");
    expect(ask.file).toBe("cmux-e2e/agent-jr-abc-1.md");
    for (const part of [SANDBOX, ask.branch, ask.file, "draft pull request", "push"]) expect(ask.prompt).toContain(part);
  });

  test("e2eLines keeps only the cells", () => {
    expect(e2eLines("noise\ne2e: clone ok\n  e2e: push FAIL\n")).toBe("e2e: clone ok; e2e: push FAIL");
  });
});

/** A fake gh that answers the commands cloud-github-e2e.sh sends, logging each, and a fake acpmux github-mcp. */
function fakeTools(dir: string, opts: { private?: boolean; agentPr?: boolean } = {}) {
  const bin = join(dir, "bin");
  mkdirSync(bin);
  const log = join(dir, "gh.log");
  const comments = join(dir, "comments");
  writeFileSync(join(bin, "gh"), [
    "#!/bin/sh",
    `echo "GH_REPO=$GH_REPO $*" >> ${JSON.stringify(log)}`,
    'case "$*" in',
    '  "auth status"*) echo "not logged in" >&2; exit 1 ;;',
    `  "repo view"*) echo ${opts.private === false ? "false" : "true"} ;;`,
    '  "pr create"*) echo "https://github.com/$GH_REPO/pull/7" ;;',
    `  "pr comment"*) shift 4; echo "$1" >> ${JSON.stringify(comments)} ;;`,
    `  "api repos/"*"/issues/7/comments"*) cat ${JSON.stringify(comments)} ;;`,
    '  "api repos/"*"/check-runs"*) echo 2 ;;',
    '  "api repos/"*"/status"*) echo pending ;;',
    '  "pr close"*) : ;;',
    '  "api repos/"*"/branches/"*) echo b ;;',
    '  "api repos/"*"/contents/"*) echo f ;;',
    `  "pr list"*) ${opts.agentPr === false ? ":" : "echo 9"} ;;`,
    '  "api -X DELETE"*) : ;;',
    '  *) echo "fake gh: unexpected $*" >&2; exit 2 ;;',
    "esac",
    "",
  ].join("\n"));
  writeFileSync(join(bin, "acpmux"), [
    "#!/bin/sh",
    "cat >/dev/null",
    `echo '{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"[{\\"name\\":\\"main\\"}]"}]}}'`,
    "",
  ].join("\n"));
  chmodSync(join(bin, "gh"), 0o755);
  chmodSync(join(bin, "acpmux"), 0o755);
  return { bin, log };
}

/** A bare repository at ORIGIN/sandbox-org/cmux-cloud-e2e.git with one commit on main. */
function bareRepo(dir: string): { origin: string; bare: string } {
  const origin = join(dir, "origin");
  const bare = join(origin, `${SANDBOX}.git`);
  const git = (...args: string[]) => spawnSync("git", args, { encoding: "utf8" });
  git("init", "-q", "--bare", "-b", "main", bare);
  const seed = join(dir, "seed");
  git("init", "-q", "-b", "main", seed);
  writeFileSync(join(seed, "README.md"), "sandbox\n");
  git("-C", seed, "add", ".");
  git("-C", seed, "-c", "user.name=t", "-c", "user.email=t@t.invalid", "commit", "-q", "-m", "seed");
  git("-C", seed, "push", "-q", bare, "main");
  return { origin: `file://${origin}`, bare };
}

function runScript(dir: string, bin: string, origin: string, args: string[]) {
  const home = join(dir, "home");
  mkdirSync(home, { recursive: true });
  return spawnSync("sh", [GITHUB_E2E_SH, ...args], {
    encoding: "utf8",
    timeout: 60_000,
    env: { PATH: `${bin}:${process.env.PATH}`, HOME: home, CMUX_E2E_GITHUB_ORIGIN: origin, CMUX_E2E_ACPMUX: join(bin, "acpmux"), CMUX_E2E_REST_DIRS: home },
  });
}

const cells = (stdout: string) => Object.fromEntries(stdout.split("\n").map((l) => /^e2e: (\S+) (ok|FAIL)\b/.exec(l)).filter(Boolean).map((m) => [m![1], m![2]]));

describe("cloud-github-e2e.sh: the live cells", () => {
  test("every cell passes in a private sandbox, and the run leaves no branch behind", () => {
    const dir = mkdtempSync(join(tmpdir(), "gh-e2e-"));
    try {
      const { bin, log } = fakeTools(dir);
      const { origin, bare } = bareRepo(dir);
      const r = runScript(dir, bin, origin, [SANDBOX]);
      expect(cells(r.stdout)).toEqual({
        repo_private: "ok", clone: "ok", branch: "ok", commit: "ok", push: "ok", pr_create: "ok", pr_comments_read: "ok",
        pr_checks_read: "ok", pr_close: "ok", branch_delete: "ok", mcp_call: "ok", no_token_at_rest: "ok",
      });
      expect(r.status).toBe(0);
      expect(r.stdout).toContain("e2e: gh_auth_status info exit 1");
      expect(r.stdout).toContain("e2e: pr_create number 7");
      expect(r.stdout).toContain("e2e: pr_checks check_runs=2 status=pending");
      const sent = readFileSync(log, "utf8");
      expect(sent).toMatch(/GH_REPO=sandbox-org\/cmux-cloud-e2e pr create --draft --base main --head cmux-e2e\//);
      expect(sent).toContain("pr close 7");
      // The pushed branch was there for the PR, and the cleanup deleted it.
      const refs = spawnSync("git", ["-C", bare, "for-each-ref", "--format=%(refname)"], { encoding: "utf8" }).stdout;
      expect(refs.trim()).toBe("refs/heads/main");
      expect(sent).toMatch(/pr create .*--head (cmux-e2e\/\S+)/);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a public repository fails its cell and the run", () => {
    const dir = mkdtempSync(join(tmpdir(), "gh-e2e-"));
    try {
      const { bin } = fakeTools(dir, { private: false });
      const { origin } = bareRepo(dir);
      const r = runScript(dir, bin, origin, [SANDBOX]);
      expect(cells(r.stdout).repo_private).toBe("FAIL");
      expect(cells(r.stdout).push).toBe("ok");
      expect(r.status).toBe(1);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("a clone that fails says why and skips the git cells", () => {
    const dir = mkdtempSync(join(tmpdir(), "gh-e2e-"));
    try {
      const { bin } = fakeTools(dir);
      const r = runScript(dir, bin, `file://${join(dir, "nowhere")}`, [SANDBOX]);
      expect(cells(r.stdout).clone).toBe("FAIL");
      expect(r.stdout).toMatch(/e2e: clone says /);
      expect(cells(r.stdout).push).toBeUndefined();
      expect(r.status).toBe(1);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("not OWNER/REPO is refused before anything runs", () => {
    const dir = mkdtempSync(join(tmpdir(), "gh-e2e-"));
    try {
      const { bin, log } = fakeTools(dir);
      const r = runScript(dir, bin, "file:///nowhere", ["a/b;touch x"]);
      expect(r.stdout).toContain("e2e: repo FAIL not OWNER/REPO");
      expect(r.status).toBe(1);
      expect(() => readFileSync(log, "utf8")).toThrow();
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("cloud-github-e2e.sh --agent-pr: what the agent did, read back and cleaned up", () => {
  test("branch, file and open PR found; the PR closed and the branch deleted", () => {
    const dir = mkdtempSync(join(tmpdir(), "gh-e2e-"));
    try {
      const { bin, log } = fakeTools(dir);
      const r = runScript(dir, bin, "file:///nowhere", ["--agent-pr", SANDBOX, "cmux-agent-e2e/jr-1", "cmux-e2e/agent-jr-1.md"]);
      expect(cells(r.stdout)).toEqual({ agent_branch: "ok", agent_commit: "ok", agent_pr: "ok", pr_close: "ok", branch_delete: "ok", no_token_at_rest: "ok" });
      expect(r.status).toBe(0);
      const sent = readFileSync(log, "utf8");
      expect(sent).toContain(`api repos/${SANDBOX}/contents/cmux-e2e/agent-jr-1.md?ref=cmux-agent-e2e/jr-1`);
      expect(sent).toContain("pr close 9");
      expect(sent).toContain(`api -X DELETE repos/${SANDBOX}/git/refs/heads/cmux-agent-e2e/jr-1`);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("no PR from the branch fails the cell, and the branch is still deleted", () => {
    const dir = mkdtempSync(join(tmpdir(), "gh-e2e-"));
    try {
      const { bin, log } = fakeTools(dir, { agentPr: false });
      const r = runScript(dir, bin, "file:///nowhere", ["--agent-pr", SANDBOX, "cmux-agent-e2e/jr-1", "cmux-e2e/agent-jr-1.md"]);
      expect(cells(r.stdout).agent_pr).toBe("FAIL");
      expect(cells(r.stdout).branch_delete).toBe("ok");
      expect(r.status).toBe(1);
      expect(readFileSync(log, "utf8")).not.toContain("pr close");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("the journey's GitHub steps", () => {
  const step = (steps: { step: string }[], name: string) => steps.find((s) => s.step === name) as any;

  test("hourly, no sandbox: the connection is read and recorded, never red; the live cells skip", () => {
    const { steps, probe, log } = runJourney({ github: { status: { configured: true, allowed: true, connection: null } } });
    expect(step(steps, GITHUB_STATUS_STEP)).toMatchObject({ status: "pass", detail: expect.stringContaining("connected no") });
    expect(log.filter((l) => l.startsWith("github status"))).toHaveLength(1);
    expect(log).not.toContain("github repos");
    expect(step(steps, "GitHub on the machine (live)")).toMatchObject({ status: "skip", detail: "CMUX_JOURNEY_GITHUB_REPO is not set" });
    expect(step(steps, GITHUB_AGENT_STEP)).toMatchObject({ status: "skip" });
    expect(probe.outcome).toBe("ok");
  });

  test("a status read that fails is a skip without a sandbox", () => {
    const { steps, probe } = runJourney({});
    expect(step(steps, GITHUB_STATUS_STEP)).toMatchObject({ status: "skip", detail: expect.stringContaining("HTTP 404") });
    expect(probe.outcome).toBe("ok");
  });

  test("a sandbox with no connection: the status step fails and names the blocker", () => {
    const { steps } = runJourney({ github: { sandbox: SANDBOX, status: { configured: true, allowed: true, connection: null }, script: { live: ["clone FAIL"], agent: ["agent_pr FAIL"] } } });
    expect(step(steps, GITHUB_STATUS_STEP)).toMatchObject({ status: "fail", detail: expect.stringContaining("no active GitHub connection") });
  });

  test("a sandbox on a connected team: the live cells and the agent's cells run and pass", () => {
    const { steps, log } = runJourney({
      github: {
        sandbox: SANDBOX, status: ACTIVE, repos: LISTED,
        script: { live: ["clone ok", "push ok", "pr_create ok"], agent: ["agent_branch ok", "agent_commit ok", "agent_pr ok", "pr_close ok", "branch_delete ok"] },
      },
    });
    expect(step(steps, GITHUB_STATUS_STEP)).toMatchObject({ status: "pass", detail: expect.stringContaining("sandbox listed yes (private yes)") });
    expect(step(steps, "GitHub on the machine (live)")).toMatchObject({ status: "pass", detail: "e2e: clone ok; e2e: push ok; e2e: pr_create ok" });
    expect(step(steps, GITHUB_AGENT_STEP)).toMatchObject({ status: "pass", detail: expect.stringContaining("e2e: agent_pr ok") });
    expect(log).toContain("github live");
    expect(log).toContain("github agent-pr");
    // The agent's cell runs after the reply, outside the first-text window.
    expect(steps.findIndex((s) => s.step === GITHUB_AGENT_STEP)).toBeGreaterThan(steps.findIndex((s) => s.step === "reply"));
  });

  test("a failed read back fails the agent's cell, and the journey still cleans up", () => {
    const { steps, log } = runJourney({
      github: { sandbox: SANDBOX, status: ACTIVE, repos: LISTED, script: { live: ["clone ok"], agent: ["agent_pr FAIL", "branch_delete ok"] } },
    });
    expect(step(steps, GITHUB_AGENT_STEP)).toMatchObject({ status: "fail", detail: expect.stringContaining("e2e: agent_pr FAIL") });
    expect(log).toContain("delete");
  });
});
