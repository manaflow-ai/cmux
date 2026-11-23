// A new page's folder menu lists the GitHub repositories an earlier page read on its first open
// (githubRepos.ts GitHubMemory), then reads the status and the repositories again behind them; a
// status that is no longer connected forgets them, so the next page shows none from before.
import { expect, test } from "bun:test";
import { createGitHubPicker, type GitHubMemory, type GitHubSeen } from "../src/agent-session/acpmux/githubRepos";

const READY = { state: "ready", repos_scope: "all" };
const REPOS = {
  repos: [{ full_name: "acme/api", private: true, default_branch: "main" }],
  truncated: false,
};

function memory(): GitHubMemory & { seen?: GitHubSeen } {
  const box: GitHubMemory & { seen?: GitHubSeen } = {
    read: () => box.seen,
    write: (seen) => {
      box.seen = seen;
    },
  };
  return box;
}

function picker(answers: Record<string, unknown>, kept: GitHubMemory) {
  const calls: string[] = [];
  const store = createGitHubPicker(
    async (method) => {
      calls.push(method);
      return answers[method];
    },
    () => () => undefined,
    () => true,
    () => () => undefined,
    kept,
  );
  return { store, calls };
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

test("the next page's menu lists the repositories an earlier page read, before any host call", async () => {
  const kept = memory();
  const first = picker({ "github.status": READY, "github.repos.list": REPOS }, kept);
  expect(first.store.snapshot().repos).toBeUndefined();
  first.store.open();
  await settle();
  expect(kept.seen?.repos.map((repo) => repo.fullName)).toEqual(["acme/api"]);

  const next = picker(
    {
      "github.status": READY,
      "github.repos.list": { repos: [{ full_name: "acme/web", private: false }] },
    },
    kept,
  );
  expect(next.calls).toEqual([]);
  expect(next.store.snapshot().status?.state).toBe("ready");
  expect(next.store.snapshot().repos?.map((repo) => repo.fullName)).toEqual(["acme/api"]);
  // Opening reads both again behind what it shows, and the answer replaces it.
  next.store.open();
  await settle();
  expect(next.calls).toEqual(["github.status", "github.repos.list"]);
  expect(next.store.snapshot().repos?.map((repo) => repo.fullName)).toEqual(["acme/web"]);
});

test("a status that is no longer connected forgets the repositories", async () => {
  const kept = memory();
  kept.seen = { status: { state: "ready", reposScope: "all" }, repos: [], truncated: false };
  const page = picker({ "github.status": { state: "not_connected", repos_scope: null } }, kept);
  page.store.open();
  await settle();
  expect(kept.seen).toBeUndefined();
  expect(page.calls).toEqual(["github.status"]);
});
