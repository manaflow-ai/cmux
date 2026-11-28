import { describe, expect, test } from "bun:test";
import { repoRecoveryFor } from "./repoRecoveryCardModel";

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

  test("Claude Code's MCP title and its text-only output (the one-line refusal, then the payload)", () => {
    const output = [
      "This chat's GitHub grant does not cover manaflow-ai: the cmux GitHub App is not installed on manaflow-ai for this cmux team. Install it from the chat's Install GitHub App button or https://github.com/apps/cmux/installations/new, then retry.",
      JSON.stringify({
        code: "repo.no_access",
        org: "manaflow-ai",
        install_url: "https://github.com/apps/cmux/installations/new",
        retry: { action: "cloud.repo.add", args: { session: "s", repo: "manaflow-ai/cmux" } },
      }),
    ].join("\n");
    expect(
      repoRecoveryFor({
        id: "a",
        title: "mcp__cmux-cloud-repos__add_repo",
        status: "failed",
        inputSummary: '{"repo":"manaflow-ai/cmux"}',
        output,
      }),
    ).toMatchObject({
      code: "repo.no_access",
      org: "manaflow-ai",
      installUrl: "https://github.com/apps/cmux/installations/new",
      retry: { action: "cloud.repo.add", args: { repo: "manaflow-ai/cmux" } },
    });
    // Another server's tool of the same name, and a shell call titled like one, are not this card.
    for (const title of ["mcp__other__add_repo"])
      expect(repoRecoveryFor({ id: "a", title, status: "failed", inputSummary: "{}", output })).toBeUndefined();
    expect(
      repoRecoveryFor({
        id: "a",
        title: "mcp__cmux-cloud-repos__add_repo",
        kind: "execute",
        command: "echo",
        status: "failed",
        output,
      }),
    ).toBeUndefined();
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
