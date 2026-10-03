import { describe, expect, test } from "bun:test";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { PermissionPanel } from "./Panel";
import type { PermissionClientState, PermissionGroup } from "./protocol";

const group: PermissionGroup = {
  groupId: "g",
  sessionId: "s",
  turnId: "t",
  revision: 3,
  state: "pending",
  decision: null,
  decisions: ["allow_once", "allow_chat", "deny"],
  items: [
    {
      permissionId: "p",
      state: "pending",
      request: {
        toolCall: {
          title: "Write app.ts",
          kind: "edit",
          rawInput: { path: "app.ts", content: "<script>bad()</script>" },
        },
        options: [{ optionId: "yes", kind: "allow_once", name: "Allow" }],
      },
    },
  ],
};
function render(partial: Partial<PermissionClientState> = {}) {
  const state: PermissionClientState = {
    supported: true,
    ready: true,
    groups: [group],
    chatAllowance: false,
    loading: false,
    busy: false,
    ...partial,
  };
  return renderToStaticMarkup(
    <PermissionPanel state={state} onRespond={() => {}} onRetry={() => {}} onRevoke={() => {}} onRefresh={() => {}} />,
  );
}
describe("grouped tool permission panel", () => {
  test("one ask with expandable original input and explicit scope and coverage", () => {
    const html = render();
    expect(html).toContain("Allow once");
    expect(html).toContain("Allow for this chat");
    expect(html).toContain("Deny");
    expect(html).toContain("future eligible requests");
    expect(html).toContain("ACP requests only");
    expect(html).toContain("Isolation unverified");
    expect(html).toContain("<details>");
    expect(html).toContain("app.ts");
    expect(html).not.toContain("<script>bad()");
  });
  test("tool content stays reviewable when raw input is absent", () => {
    const html = render({
      groups: [
        {
          ...group,
          items: [
            {
              ...group.items[0]!,
              request: {
                toolCall: {
                  title: "Write app.ts",
                  kind: "edit",
                  content: [{ type: "content", content: { type: "text", text: "Keep the existing lockfile" } }],
                },
              },
            },
          ],
        },
      ],
    });
    expect(html).toContain("Keep the existing lockfile");
    expect(html).not.toContain("No additional input was provided");
  });
  test("collecting groups cannot be answered", () => {
    const html = render({ groups: [{ ...group, state: "collecting" }] });
    expect(html).toContain("Collecting requests");
    expect(html).not.toContain("<button");
  });
  test("deny-only groups expose no allow action", () => {
    const html = render({ groups: [{ ...group, decisions: ["deny"] }] });
    expect(html).not.toContain(">Allow once<");
    expect(html).not.toContain(">Allow for this chat<");
    expect(html).toContain("only be denied");
  });
  test("uncertain decisions disable approval and expose read-first retry", () => {
    const html = render({ uncertain: true, error: "The reply was interrupted." });
    expect(html).toContain('disabled="">Allow once');
    expect(html).toContain("Check and retry");
  });
  test("a failed or disconnected owner read disables stale approval controls", () => {
    const html = render({ ready: false, error: "Refresh before answering." });
    expect(html).toContain('disabled="">Allow once');
    expect(html).toContain("Refresh");
  });
  test("chat grant is revocable without pending requests and old daemons are hidden", () => {
    expect(render({ groups: [], chatAllowance: true })).toContain("Revoke");
    expect(render({ supported: false })).toBe("");
  });
  test("terminal group is a receipt without approval actions", () => {
    const html = render({ groups: [{ ...group, state: "resolved", decision: "allow_once" }] });
    expect(html).toContain("acpmux-permission-receipt");
    expect(html).not.toContain("<button");
  });
  test("Japanese pane localizes approval and recovery controls while preserving agent input", () => {
    const navigator = Object.getOwnPropertyDescriptor(globalThis, "navigator");
    try {
      Object.defineProperty(globalThis, "navigator", { configurable: true, value: { languages: ["ja-JP"] } });
      const html = render({
        chatAllowance: true,
        uncertain: true,
        error: "Owner error remains intact",
        groups: [{ ...group, items: [{ ...group.items[0]!, request: { toolCall: { title: "Write app.ts" } } }] }],
      });
      expect(html).toContain('aria-label="ツールの権限"');
      expect(html).toContain("1 回だけ許可");
      expect(html).toContain("このチャットで許可");
      expect(html).toContain("拒否");
      expect(html).toContain("取り消す");
      expect(html).toContain("確認して再試行");
      expect(html).toContain("このターンのリクエスト 1 件");
      expect(html).toContain("隔離は未検証");
      expect(html).toContain("追加の入力はありません。");
      expect(html).toContain("Write app.ts");
      expect(html).toContain("Owner error remains intact");
      expect(html).not.toContain("Allow once");
    } finally {
      if (navigator) Object.defineProperty(globalThis, "navigator", navigator);
      else Reflect.deleteProperty(globalThis, "navigator");
    }
    expect(render()).toContain("Allow once");
  });
});
