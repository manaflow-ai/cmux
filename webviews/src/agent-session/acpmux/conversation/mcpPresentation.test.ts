import { expect, test } from "bun:test";
import { isMcpLifecycleOutput, isToolDiscoveryNoise, usefulMcpRequest, usefulMcpResponse } from "./mcpPresentation";
import { mixedToolRunFixture } from "./mixedToolRunFixture";

test("only successful builtin discovery is hidden, never a similarly named operation or an error", () => {
  const discovery = mixedToolRunFixture()[2]!.tool!;
  expect(isToolDiscoveryNoise(discovery)).toBe(true);
  expect(isToolDiscoveryNoise({ ...discovery, output: '{"isError": false,"message":"Loaded tools"}' })).toBe(true);
  for (const extra of [
    { status: "pending" }, { status: "failed" }, { output: '{"isError":true,"message":"unavailable"}' },
    { output: '{"status":"failed","message":"Offline"}' }, { output: "Error: connection refused" }, { output: '{"error":{"message":"offline"}}' }, { title: "mcp__repo__load_tools" }, { title: "download_tools" },
    { command: "load_tools" }, { approved: true },
  ]) expect(isToolDiscoveryNoise({ ...discovery, ...extra })).toBe(false);
});

test("detail uses values and meaningful results instead of raw argument keys or lifecycle placeholders", () => {
  expect(usefulMcpRequest({ paths: ["src/retry.ts"], pattern: "retry", repo: "app" }))
    .toEqual({ context: "src/retry.ts\nretry" });
  expect(usefulMcpRequest({ command: "git status", timeout_ms: 1000 })).toEqual({ command: "git status" });
  expect(usefulMcpResponse('{"matches":[{"path":"a.ts","line":12,"text":"retry()"}]}'))
    .toBe("a.ts:12: retry()");
  for (const output of ["", "Waiting…", "Running...", '"Waiting…"', '{"content":[{"type":"text","text":"Pending"}]}'])
    expect(usefulMcpResponse(output)).toBeUndefined();
  expect(usefulMcpResponse("Waiting…\nthen returned 4 matches")).toContain("4 matches");
  expect(usefulMcpResponse('{"private_protocol_key":42}')).toBe("private protocol key: 42");
  expect(usefulMcpResponse('{"error":{"reason":"Connection refused","detail":"Try again later"}}'))
    .toBe("Try again later\nConnection refused");
  expect(usefulMcpResponse('{"message":"Found matches","count":17}')).toBe("Found matches\ncount: 17");
  expect(usefulMcpResponse('{"data":{"count":17}}')).toBe("count: 17");
  expect(usefulMcpResponse('[17,17]')).toBe("17\n17");
  expect(usefulMcpResponse("17")).toBe("17");
  expect(usefulMcpResponse("false")).toBe("false");
  expect(usefulMcpResponse("null")).toBe("null");
  expect(usefulMcpResponse('{"matchedCount":17,"skipped_count":3}')).toBe("matched Count: 17\nskipped count: 3");
  expect(isMcpLifecycleOutput('{"status":"waiting"}')).toBe(true);
  expect(isMcpLifecycleOutput('{"status":"waiting","message":"Reconnect the agent"}')).toBe(false);
});
