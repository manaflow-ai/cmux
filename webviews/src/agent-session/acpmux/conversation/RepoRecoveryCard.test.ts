import { describe, expect, test } from "bun:test";
import { repoRecoveryFor } from "./RepoRecoveryCard";

describe("repository tool recovery", () => {
  test("recognizes needs_github and keeps retry contract", () => {
    const recovery = repoRecoveryFor({
      id: "a",
      title: "add_repo",
      status: "failed",
      output: JSON.stringify({
        code: "repo.needs_github",
        install_url: "https://github.com/apps/cmux/installations/new",
        retry: {
          action: "cloud.repo.add",
          args: { session: "s", repo: "acme/demo" },
          wait_action: "cloud.repo.wait_github",
        },
      }),
    });
    expect(recovery).toMatchObject({
      code: "repo.needs_github",
      installUrl: "https://github.com/apps/cmux/installations/new",
    });
    expect(recovery?.retry?.wait_action).toBe("cloud.repo.wait_github");
  });

  test("recognizes organization access and ambiguous choices", () => {
    expect(
      repoRecoveryFor({
        id: "a",
        title: "list_repos",
        status: "failed",
        output: '{"code":"repo.no_access","org":"acme"}',
      }),
    ).toMatchObject({ code: "repo.no_access", org: "acme" });
    expect(
      repoRecoveryFor({
        id: "a",
        title: "add_repo",
        status: "failed",
        output: '{"code":"repo.ambiguous","choices":[{"fullName":"acme/demo"}]}',
      })?.choices,
    ).toEqual([{ fullName: "acme/demo" }]);
  });

  test("does not hide unrelated failures", () => {
    expect(
      repoRecoveryFor({ id: "a", title: "add_repo", status: "failed", output: '{"code":"repo.not_found"}' }),
    ).toBeUndefined();
    expect(
      repoRecoveryFor({ id: "a", title: "bash", status: "failed", output: '{"code":"repo.needs_github"}' }),
    ).toBeUndefined();
  });
});
