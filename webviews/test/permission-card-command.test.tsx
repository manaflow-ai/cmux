// l10n-allow-file: test fixture tool titles and commands, not shipped UI.
// A single permission card drew a command block for every ask with a title: with no command in
// the request it showed the title, minus a leading "Run", as code. An edit, a fetch or an MCP
// call read "Edit src/app.ts" as its label and again as a command under it. The card shows a
// command when the request carries one, and reads it from the title only for a command ask
// (kind execute) whose title is the command, the way Codex titles it ("Run npm test").
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxPermission } from "../src/agent-session/acpmux/model";
import { PermissionCard } from "../src/agent-session/acpmux/PermissionCard";

const options: AcpmuxPermission["options"] = [
  { id: "allow", name: "Allow", kind: "allow_once", allow: true },
  { id: "deny", name: "Deny", kind: "reject_once", allow: false },
];
const ask = (fields: Partial<AcpmuxPermission>): AcpmuxPermission => ({
  permissionId: "p1",
  pending: true,
  options,
  ...fields,
});
const card = (permission: AcpmuxPermission) =>
  renderToStaticMarkup(<PermissionCard permission={permission} onAnswer={() => undefined} harness="codex" />);
const commandBlock = (html: string) => html.match(/<div class="acpmux-permission-command"[^>]*>.*?<\/code>/s)?.[0];

test("an edit ask without a command draws no command block", () => {
  const html = card(ask({ title: "Edit src/app.ts", kind: "edit" }));
  expect(html).toContain("Edit src/app.ts");
  expect(commandBlock(html)).toBeUndefined();
});

test("a fetch or tool ask without a kind draws no command block either", () => {
  expect(commandBlock(card(ask({ title: "Fetch https://example.com", kind: "fetch" })))).toBeUndefined();
  expect(commandBlock(card(ask({ title: "mcp__linear__create_issue" })))).toBeUndefined();
});

test("a command ask shows its command", () => {
  const html = card(ask({ title: "Run tests", kind: "execute", command: "bun test" }));
  expect(commandBlock(html)).toContain("bun test");
});

test("a command ask titled with its command shows it without the Run", () => {
  const html = card(ask({ title: "Run npm test", kind: "execute" }));
  expect(commandBlock(html)).toContain('<div class="acpmux-permission-command-preview"><code>npm test</code>');
});

test("a command given as an argv array reads as the shell command", async () => {
  const { permissionFromMessage } = await import("../src/agent-session/acpmux/direct");
  const permission = permissionFromMessage(
    {
      sessionId: "s1",
      permissionId: "p1",
      request: {
        toolCall: {
          toolCallId: "t1",
          title: "Run tests",
          kind: "execute",
          rawInput: { command: ["bash", "-lc", "npm test"] },
        },
        options: [{ optionId: "allow", name: "Allow", kind: "allow_once" }],
      },
    },
    "s1",
  );
  expect(permission?.command).toBe("npm test");
  expect(commandBlock(card(permission!))).toContain(
    '<div class="acpmux-permission-command-preview"><code>npm test</code>',
  );
});

test("an ACP subject's app scope reaches the approval card without broadening its answer", async () => {
  const { permissionFromMessage } = await import("../src/agent-session/acpmux/direct");
  const permission = permissionFromMessage(
    {
      sessionId: "s1",
      permissionId: "p-scope",
      request: {
        subject: {
          type: "tool_call",
          toolCall: {
            toolCallId: "t1",
            title: "Open Calculator",
            kind: "computer_use",
            rawInput: { app: "Calculator" },
          },
        },
        options: [
          { optionId: "allow", name: "Allow", kind: "allow_once" },
          { optionId: "deny", name: "Deny", kind: "reject_once" },
        ],
      },
    },
    "s1",
  );
  expect(permission?.scope).toEqual({ kind: "app", value: "Calculator" });
  expect(permission?.options.map((option) => option.id)).toEqual(["allow", "deny"]);
});

test("an ACP command subject keeps its command preview and directory scope", async () => {
  const { permissionFromMessage } = await import("../src/agent-session/acpmux/direct");
  const permission = permissionFromMessage(
    {
      sessionId: "s1",
      permissionId: "p-command-scope",
      request: {
        title: "Run the check",
        subject: { type: "command", command: "bun test", cwd: "/workspace/project" },
        options: [{ optionId: "allow", name: "Allow", kind: "allow_once" }],
      },
    },
    "s1",
  );
  expect(permission?.command).toBe("bun test");
  expect(permission?.kind).toBe("execute");
  expect(permission?.scope).toEqual({ kind: "directory", value: "/workspace/project" });
});
