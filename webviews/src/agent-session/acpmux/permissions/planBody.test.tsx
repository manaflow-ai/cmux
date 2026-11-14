// l10n-allow-file: test fixture plan text, not shipped UI.
// Leo 2026-11-03: "it would be an absolute shame if we didn't [render Gemini's plans]". Gemini's
// plan approval names only its plan file; acpmux reads it into `_meta.acpmux.plan` (hub/gemini_plan.rs),
// and the approval card draws that plan as Markdown above its buttons.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { permissionFromMessage } from "../direct";
import { PermissionCard } from "../PermissionCard";

const PLAN = "# Add dark mode\n\n1. Read the theme tokens\n2. Add a `dark` palette\n3. Test the toggle";
const PATH = "/Users/you/.gemini/tmp/app/plans/dark-mode.md";

/// The pending ask acpmux sends for Gemini's `exit_plan_mode`, with the plan it attached.
function geminiAsk(meta: unknown = { acpmux: { plan: { markdown: PLAN, path: PATH } } }) {
  return {
    sessionId: "s1",
    permissionId: "p1",
    request: {
      sessionId: "s1",
      toolCall: {
        toolCallId: "exit_plan_mode-1",
        status: "pending",
        title: `Requesting plan approval for: ${PATH}`,
        kind: "other",
        content: [{ type: "content", content: { type: "text", text: PLAN } }],
        rawInput: { plan: PLAN, plan_path: PATH },
        _meta: meta,
      },
      options: [
        { optionId: "proceed_once", name: "Allow", kind: "allow_once" },
        { optionId: "cancel", name: "Reject", kind: "reject_once" },
      ],
    },
  };
}

test("a plan approval's ask carries its plan", () => {
  const permission = permissionFromMessage(geminiAsk(), "s1");
  expect(permission?.plan).toBe(PLAN);
});

test("an ask without acpmux's plan has none", () => {
  expect(permissionFromMessage(geminiAsk({}), "s1")?.plan).toBeUndefined();
  expect(permissionFromMessage(geminiAsk({ acpmux: { plan: { markdown: "  " } } }), "s1")?.plan).toBeUndefined();
});

test("the approval card draws the plan's steps as Markdown", () => {
  const permission = permissionFromMessage(geminiAsk(), "s1")!;
  const html = renderToStaticMarkup(
    <PermissionCard permission={permission} harness="gemini" onAnswer={() => undefined} />,
  );
  expect(html).toContain("acpmux-permission-plan");
  expect(html).toMatch(/<h1[^>]*>Add dark mode<\/h1>/);
  expect(html).toMatch(/<ol[^>]*>/);
  expect(html).toContain("Read the theme tokens");
  // The steps are drawn once, as Markdown, never also as raw text.
  expect(html).not.toContain("# Add dark mode");
});
