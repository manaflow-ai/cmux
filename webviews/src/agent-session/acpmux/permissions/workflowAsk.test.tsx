// l10n-allow-file: test fixture workflow and phase names, not shipped UI.
// A Claude Workflow call's permission ask drawn as the workflow's approval card (Labs
// `workflowLabs`): acpmux sends the run's name and phases read from its script
// (`_meta.claude.workflow`, claude_stdio/workflow_ask.rs); the card shows them with a token caution,
// and its answers are Claude's own ask's.
import { afterEach, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { permissionFromMessage } from "../direct";
import { PermissionCard } from "../PermissionCard";
import { configureWorkflowLabs, usageLimitHold } from "../summary/workflowCardModel";
import { permissionCardHeight } from "./cardHeight";

afterEach(() => configureWorkflowLabs(false));

/// The pending ask acpmux sends for Claude's `can_use_tool` on a Workflow call.
function workflowAsk(workflow?: unknown, input: unknown = { script: "export const meta = {}" }) {
  return {
    sessionId: "s1",
    permissionId: "p1",
    request: {
      sessionId: "s1",
      toolCall: {
        toolCallId: "toolu_9",
        status: "pending",
        title: "Workflow",
        kind: "other",
        rawInput: input,
        _meta: { claude: { tool: "Workflow", interactive: false, ...(workflow ? { workflow } : {}) } },
      },
      options: [
        { optionId: "allow_once", name: "Allow", kind: "allow_once" },
        { optionId: "allow_always", name: "Allow for this session", kind: "allow_always" },
        { optionId: "reject_once", name: "Reject", kind: "reject_once" },
      ],
    },
  };
}

const REVIEW = { name: "review-changes", description: "Review, then verify", phases: ["Review", "Verify", "Report"] };

test("a Workflow ask carries the run acpmux read, and only a Workflow ask does", () => {
  expect(permissionFromMessage(workflowAsk(REVIEW), "s1")?.workflow).toEqual(REVIEW);
  // No script read: the call's own name, no phases.
  expect(permissionFromMessage(workflowAsk(undefined, { name: "deep-review" }), "s1")?.workflow).toEqual({
    name: "deep-review",
    description: undefined,
    phases: [],
  });
  const bash = workflowAsk(REVIEW);
  bash.request.toolCall._meta.claude.tool = "Bash";
  expect(permissionFromMessage(bash, "s1")?.workflow).toBeUndefined();
});

test("with Labs on, the card names the workflow, lists its phases and cautions about tokens", () => {
  configureWorkflowLabs(true);
  const permission = permissionFromMessage(workflowAsk(REVIEW), "s1")!;
  const html = renderToStaticMarkup(
    <PermissionCard permission={permission} harness="claude" onAnswer={() => undefined} />,
  );
  expect(html).toContain("Run workflow review-changes?");
  expect(html).toContain("Review, then verify");
  expect(html).toMatch(/<ol[^>]*acpmux-permission-workflow-phases/);
  for (const phase of REVIEW.phases) expect(html).toContain(phase);
  expect(html).toContain("can use a lot of tokens");
  expect(html).toContain("Run once");
  expect(html).toContain("Always run");
  expect(html).toContain("Deny");
});

test("with Labs off, the same ask draws as any tool's", () => {
  const permission = permissionFromMessage(workflowAsk(REVIEW), "s1")!;
  const html = renderToStaticMarkup(
    <PermissionCard permission={permission} harness="claude" onAnswer={() => undefined} />,
  );
  expect(html).not.toContain("acpmux-permission-workflow");
  expect(html).not.toContain("Run once");
});

test("the card's height estimate grows with its phases", () => {
  const few = permissionFromMessage(workflowAsk(REVIEW), "s1")!;
  const many = permissionFromMessage(workflowAsk({ ...REVIEW, phases: [...REVIEW.phases, "A", "B", "C"] }), "s1")!;
  configureWorkflowLabs(true);
  expect(permissionCardHeight(many, 600)).toBeGreaterThan(permissionCardHeight(few, 600));
});

test("a usage-limit hold needs a capacity wait and a used-up window", () => {
  const full = { windows: [{ id: "session", usedPercent: 100, resetsAt: 1 }] };
  const half = { windows: [{ id: "session", usedPercent: 50 }] };
  expect(usageLimitHold({ reason: "capacity", nextAt: 5 }, full)).toEqual({ nextAt: 5 });
  expect(usageLimitHold({ reason: "capacity" }, full)).toEqual({});
  // A provider that is only full (529) has no window used up: not a usage limit.
  expect(usageLimitHold({ reason: "capacity", nextAt: 5 }, half)).toBeUndefined();
  expect(usageLimitHold({ reason: "transport", nextAt: 5 }, full)).toBeUndefined();
  expect(usageLimitHold(undefined, full)).toBeUndefined();
});
