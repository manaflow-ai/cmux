// l10n-allow-file: test fixtures.
import { expect, test } from "bun:test";
import type { AcpmuxActivity } from "../model";
import { translate } from "../i18n";
import { dispatchCall } from "./dispatchCalls";
import { briefAnchor, lineLabel } from "./DispatchCard";
import { toolGroups } from "./toolGroups";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

const activity = (title: string, input: unknown, output?: unknown, status = "completed"): AcpmuxActivity => {
  const tool: Tool = {
    id: title,
    title,
    status,
    inputSummary: JSON.stringify(input),
    ...(output === undefined ? {} : { output: typeof output === "string" ? output : JSON.stringify(output) }),
  };
  return { kind: "tool", text: title, tool };
};

test("parses a non-Claude/Codex ACP dispatch event from the shared metadata envelope", () => {
  const item = activity(
    "acp.dispatch",
    {
      title: "Diff viewer on the right",
      brief: "Move the diff viewer right.",
      target: "cx3-s14-header",
      host: "cmux16",
    },
    {
      event: {
        kind: "dispatch",
        briefId: "b-17",
        title: "Diff viewer on the right",
        from: "opus",
        to: "cx3-s14-header",
        host: "cmux16",
        status: "running",
      },
    },
  );
  expect(dispatchCall(item)).toMatchObject({
    kind: "dispatch",
    briefId: "b-17",
    title: "Diff viewer on the right",
    from: "opus",
    to: "cx3-s14-header",
    host: "cmux16",
    status: "running",
  });
  expect(toolGroups([item])[0]?.type).toBe("dispatch");
  expect(
    dispatchCall(
      activity(
        "mcp__relay__call",
        { prompt: "ordinary" },
        { event: { kind: "report", briefId: "b-17", summary: "Done" } },
      ),
    ),
  ).toMatchObject({ kind: "report", briefId: "b-17" });
});

test("parses Codex MCP envelopes for dispatch and reports", () => {
  expect(
    dispatchCall(
      activity("codex_apps.dispatch call", {
        server: "codex_apps",
        tool: "dispatch",
        arguments: { title: "Qwen task", brief: "Inspect it." },
      }),
    ),
  ).toMatchObject({ kind: "dispatch", title: "Qwen task", text: "Inspect it." });
  expect(
    dispatchCall(
      activity("codex_apps.report call", {
        server: "codex_apps",
        tool: "report",
        arguments: { brief_id: "b-17", summary: "Done" },
      }),
    ),
  ).toMatchObject({ kind: "report", briefId: "b-17", summary: "Done" });
});

test("parses canonical cmux MCP names and nested brief identities", () => {
  const item = activity(
    "mcp__cmux__agent_dispatch",
    { title: "T", body: "B", target: "cmux16", stop_condition: "pass" },
    {
      brief: {
        id: "brf_1",
        from: { actor_id: "opus", session_id: "src", harness: "opencode", host: "cosmic-gray" },
        to: { host: "cmux16", session_id: "dst", harness: "pi" },
        status: "running",
      },
    },
  );
  expect(dispatchCall(item)).toMatchObject({
    kind: "dispatch",
    briefId: "brf_1",
    from: "opus",
    to: "cmux16",
    host: "cmux16",
    sessionId: "dst",
  });
  expect(dispatchCall(activity("cmux.agent_steer", { brief_id: "brf_1", text: "Keep going" }))).toMatchObject({
    kind: "steer",
    briefId: "brf_1",
  });
});

test("parses descriptor names in a generic Codex MCP envelope", () => {
  expect(
    dispatchCall(
      activity("MCP call", {
        server: "cmux",
        tool: "agent_dispatch",
        arguments: { title: "T", body: "B" },
      }),
    ),
  ).toMatchObject({ kind: "dispatch", title: "T", text: "B" });
});

test("does not classify unrelated MCP or shell envelopes by tool word alone", () => {
  expect(
    dispatchCall(activity("github.report", { server: "github", tool: "report", arguments: { issue: 4 } })),
  ).toBeUndefined();
  expect(dispatchCall(activity("Shell", { tool: "report", command: "echo report" }))).toBeUndefined();
});

test("recognizes steer, report and briefs aliases without classifying ordinary shell work", () => {
  expect(
    dispatchCall(activity("mcp__acpmux__steer", { brief_id: "b-17", text: "Keep the title short." })),
  ).toMatchObject({
    kind: "steer",
    briefId: "b-17",
  });
  expect(dispatchCall(activity("cmux.report", { briefId: "b-17", summary: "Done", status: "reported" }))).toMatchObject(
    {
      kind: "report",
      briefId: "b-17",
      summary: "Done",
    },
  );
  expect(dispatchCall(activity("acpmux.briefs_ls", {}, { briefs: [{ id: "b-17" }, { id: "b-18" }] }))).toMatchObject({
    kind: "briefs",
    count: 2,
  });
  const shell = activity("Shell", { command: "bun run dispatch" });
  expect(dispatchCall(shell)).toBeUndefined();
  expect(toolGroups([shell])[0]?.type).toBe("item");
  for (const title of ["mcp__github__report_issue", "mcp__slack__steer_message", "mcp__foo__dispatch_file"]) {
    expect(dispatchCall(activity(title, { title: "ordinary MCP call" }))).toBeUndefined();
  }
  expect(dispatchCall(activity("mcp__relay__call", { result: { kind: "report" } }))).toBeUndefined();
  expect(dispatchCall(activity("dispatch", { title: "A brief" }))).toMatchObject({ kind: "dispatch" });
  expect(dispatchCall(activity("Shell", { command: "echo acpmux dispatch" }))).toBeUndefined();
  const cli = activity("Shell", { command: "acpmux dispatch brief.md --host cmux16" });
  cli.tool!.command = "acpmux dispatch brief.md --host cmux16";
  expect(dispatchCall(cli)).toMatchObject({ kind: "dispatch" });
  expect(toolGroups([cli])[0]?.type).toBe("dispatch");
});

test("dispatch cards use the compact copy and link wording", () => {
  const call = {
    kind: "dispatch" as const,
    briefId: "b-17",
    title: "Diff viewer on the right",
    to: "cx3-s14-header",
    host: "cmux16",
  };
  expect(lineLabel(translate, call, "'Diff viewer on the right'", "cx3-s14-header · cmux16")).toBe(
    "Sent to 'Diff viewer on the right' → cx3-s14-header · cmux16",
  );
  expect(briefAnchor("b:17")).toBe("brief-b-17");
});
