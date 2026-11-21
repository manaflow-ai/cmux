// l10n-allow-file: test fixtures, not shipped UI.
import { expect, test } from "bun:test";
import { experimentArm } from "../../../experiments/experiment";
import { githubConnect } from "./githubConnect.experiment";
import { needsGitHubConnection } from "./githubConnectModel";

const error = {
  code: "github.not_connected",
  retryable: true,
  connect: { action: "accounts.githubConnect", cli: "cmux accounts github-connect" },
};
const result = { isError: true, structuredContent: { error } };
const tool = (output: unknown) => ({
  id: "github-call",
  title: "mcp__github__get_me",
  status: "failed",
  output: JSON.stringify(output),
});

test("the experiment requires an explicit valid opt-in", () => {
  expect(experimentArm(githubConnect, { overrides: {}, stored: {} })).toBe("off");
  expect(experimentArm(githubConnect, { overrides: { [githubConnect.id]: "unknown" }, stored: {} })).toBe("off");
  expect(experimentArm(githubConnect, { overrides: { [githubConnect.id]: "on" }, stored: {} })).toBe("on");
});

test("accepts the bridge's structured refusal for both MCP harness shapes", () => {
  expect(needsGitHubConnection(tool(result))).toBe(true);
  expect(needsGitHubConnection(tool({ jsonrpc: "2.0", id: 1, result }))).toBe(true);
  expect(
    needsGitHubConnection({
      ...tool(result),
      title: "MCP tool call",
      inputSummary: JSON.stringify({ server: "github", tool: "get_me", arguments: {} }),
    }),
  ).toBe(true);
});

test("does not promote prose, policy denial, unrelated servers or arbitrary actions into connect", () => {
  for (const next of [
    { ...error, code: "policy.denied" },
    { ...error, retryable: false },
    { ...error, connect: { action: "shell.run" } },
    { ...error, connect: undefined },
  ])
    expect(needsGitHubConnection(tool({ ...result, structuredContent: { error: next } }))).toBe(false);
  expect(needsGitHubConnection(tool({ ...result, isError: false }))).toBe(false);
  expect(needsGitHubConnection({ ...tool(result), title: "mcp__other__get_me" })).toBe(false);
  expect(needsGitHubConnection(tool({ content: [{ type: "text", text: JSON.stringify(result) }] }))).toBe(false);
  for (const output of ["github.not_connected Next: Connect GitHub", "{broken", " ".repeat(64_001), ""])
    expect(needsGitHubConnection({ ...tool(result), output })).toBe(false);
});
