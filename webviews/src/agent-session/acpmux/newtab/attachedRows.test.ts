import { expect, test } from "bun:test";
import { EMPTY_OMNIBAR } from "../omnibar";
import { attachedRows, returnRow, screenRows } from "./screenModel";

// A pasted image's draft offered "Search the web for …", tabs and commands beside Ask; each of them
// left the file behind (Lucas 2026-11-26). With a staged file only the Ask rows stay.
test("a draft with staged files keeps only its Ask rows", () => {
  const rows = screenRows("next", {
    omnibar: { ...EMPTY_OMNIBAR, workspaces: [{ id: "ws", name: "next-scratch" }] },
    create: ["terminal", "browser", "chat"],
    ask: { harness: "claude", agent: "Claude Code" },
  });
  expect(rows.some((row) => row.type === "search")).toBe(true);
  expect(rows.some((row) => row.type === "workspace")).toBe(true);
  const kept = attachedRows(rows);
  expect(kept.length).toBeGreaterThan(0);
  expect(kept.every((row) => row.type === "ask")).toBe(true);
});

test("with staged files Return takes only an Ask row", () => {
  const search = { type: "search", text: "next" } as const;
  const ask = { type: "ask", text: "next", harness: "codex", agent: "Codex" } as const;
  const create = { type: "create", kind: "terminal", title: "New terminal" } as const;
  const context = { address: false, attachments: 1 };
  expect(returnRow([ask], [], 0, context).takes).toBe(true);
  expect(returnRow([search], [], 0, context).takes).toBe(false);
  expect(returnRow([create], [], 0, context).takes).toBe(false);
});
