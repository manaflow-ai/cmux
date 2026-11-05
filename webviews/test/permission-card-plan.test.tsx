// l10n-allow-file: test fixture plans and option names, not shipped UI.
// A plan approval drew as a generic permission card: "Approve plan" with Allow and Reject, and no
// plan at all, so the person approved a plan they could not read in the pane. Leo, 2026-11-05: "i
// like these plans too... i want us to be able to render it in ours". The card reads the plan from
// Claude Code's ExitPlanMode input, or from the switch_mode ask acpmux builds for Grok and Cursor,
// renders it as Markdown, and names its answers Approve plan and Keep planning.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { permissionFromMessage, permissionPlan } from "../src/agent-session/acpmux/direct";
import { PermissionCard } from "../src/agent-session/acpmux/PermissionCard";

const PLAN = "## Retry uploads\n\n1. Add `withRetry`\n2. Wrap `uploadChunk`";

const ask = (toolCall: Record<string, unknown>, options = [
  { optionId: "allow_once", name: "Allow", kind: "allow_once" },
  { optionId: "reject_once", name: "Reject", kind: "reject_once" },
]) => permissionFromMessage({ sessionId: "s1", permissionId: "p1", request: { toolCall, options } }, "s1")!;

const card = (permission: ReturnType<typeof ask>) =>
  renderToStaticMarkup(<PermissionCard permission={permission} onAnswer={() => undefined} harness="claude" />);

test("Claude Code's ExitPlanMode ask carries its plan", () => {
  const permission = ask({
    toolCallId: "toolu_1",
    title: "Approve plan",
    kind: "other",
    rawInput: { plan: `  ${PLAN}\n` },
    _meta: { claude: { tool: "ExitPlanMode" } },
  });
  expect(permission.plan).toBe(PLAN);
});

test("a switch_mode ask acpmux builds for Grok or Cursor carries its plan, from input or content", () => {
  expect(ask({ toolCallId: "t", title: "Ready to code?", kind: "switch_mode", rawInput: { plan: PLAN } }).plan).toBe(
    PLAN,
  );
  expect(
    permissionPlan({ kind: "switch_mode", content: [{ type: "content", content: { type: "text", text: PLAN } }] }),
  ).toBe(PLAN);
});

test("any other ask, and a plan approval with no plan text, carries none", () => {
  expect(ask({ toolCallId: "t", title: "Write notes", kind: "edit", rawInput: { plan: PLAN } }).plan).toBeUndefined();
  expect(ask({ toolCallId: "t", title: "Ready to code?", kind: "switch_mode", rawInput: { plan: "  " } }).plan).toBeUndefined();
});

test("the card renders the plan as Markdown with Approve plan and Keep planning", () => {
  const html = card(
    ask({
      toolCallId: "toolu_1",
      title: "Approve plan",
      kind: "other",
      rawInput: { plan: PLAN },
      _meta: { claude: { tool: "ExitPlanMode" } },
    }),
  );
  const plan = html.match(/<div class="acpmux-permission-plan"[^>]*>.*?<\/ol>/s)?.[0] ?? "";
  expect(plan).toContain("Retry uploads</h2>");
  expect(plan).toContain("<code");
  expect(plan).toContain("withRetry");
  expect(html).toContain('aria-label="Approve plan"');
  expect(html).toContain('aria-label="Keep planning"');
  expect(html).not.toContain('aria-label="Allow once"');
});

test("an ordinary ask keeps Allow once and Deny and draws no plan", () => {
  const html = card(ask({ toolCallId: "t", title: "Edit src/app.ts", kind: "edit" }));
  expect(html).not.toContain("acpmux-permission-plan");
  expect(html).toContain('aria-label="Allow once"');
  expect(html).toContain('aria-label="Deny"');
});
