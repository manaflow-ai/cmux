// A cmux-forum post, reply or search becomes the forum card's group (toolGroups.ts `forum`), from
// Claude's `mcp__cmux-forum__*` name or Codex's nested input; the server's other tools and any other
// server's `post` keep their rows; a result older than the card's contract keeps the MCP row.
import { expect, test } from "bun:test";
import { tool } from "../../../gallery/fixtures/acpmux";
import { forumCall } from "./forumCalls";
import { mcpCall } from "./mcpCalls";
import { toolGroups } from "./toolGroups";
import { codexPostCall, mcpResult, postCall, replyCall, searchCall, unconfiguredCall } from "./forumCalls.fixtures";

const read = (item: ReturnType<typeof tool>) => forumCall(item.tool!, mcpCall(item.tool!));

test("a post reads the thread from the result", () => {
  const call = read(postCall())!;
  expect(call.tool).toBe("post");
  expect(call.status).toBe("done");
  expect(call.thread).toMatchObject({ number: 214, space: "fleet", comments: 0 });
  expect(call.thread?.url).toStartWith("https://");
});

test("a running post reads the thread from its arguments", () => {
  const call = read(postCall("in_progress"))!;
  expect(call.status).toBe("running");
  expect(call.thread).toMatchObject({ space: "fleet" });
  expect(call.thread?.title).toContain("Compile pool");
});

test("a reply names the thread with its reply count", () => {
  expect(read(replyCall())!.thread).toMatchObject({ number: 198, comments: 4, state: "answered" });
});

test("a search lists its hits", () => {
  const call = read(searchCall())!;
  expect(call.query).toBe("cargo cache");
  expect(call.hits.map((hit) => hit.number)).toEqual([198, 176, 151]);
});

test("Codex's nested call is the same card", () => {
  expect(read(codexPostCall())).toMatchObject({ tool: "post", thread: { number: 215 } });
});

test("a failed call carries the server's message", () => {
  const call = read(unconfiguredCall())!;
  expect(call.status).toBe("failed");
  expect(call.error).toContain("not set up");
});

test("a non-https link is never drawn", () => {
  const item = tool("mcp__cmux-forum__post", "other", "completed", {
    inputSummary: "{}",
    output: mcpResult({ forum: "post", thread: { number: 1, title: "x", space: "s", url: "javascript:alert(1)" } }),
  });
  expect(read(item)!.thread?.url).toBeUndefined();
});

test("other tools keep their rows", () => {
  for (const item of [
    tool("mcp__cmux-forum__announce", "other", "completed", { inputSummary: "{}", output: "ok" }),
    tool("mcp__slack__post", "other", "completed", { inputSummary: "{}", output: "ok" }),
    // A result that is not the card's contract.
    tool("mcp__cmux-forum__post", "other", "completed", { inputSummary: "{}", output: "posted" }),
  ]) {
    expect(read(item)).toBeUndefined();
    expect(toolGroups([item]).map((group) => group.type)).toEqual(["mcp"]);
  }
});

test("toolGroups draws each forum call as its own card", () => {
  const groups = toolGroups([searchCall(), replyCall(), postCall()]);
  expect(groups.map((group) => group.type)).toEqual(["forum", "forum", "forum"]);
});
