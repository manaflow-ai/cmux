// l10n-allow-file: test fixture paths and file text, not shipped UI.
// A Write's transcript row reads as an edit's does ("Edited batch38.sh +18 -0"): "Writing x.ts"
// while it runs, "Wrote x.ts" once done with the counts its edits line shows (a create "+N", a
// known overwrite "+a -d", none when the old contents are unknown), the file name opening the
// file, and "Writing x.ts failed" when it failed. Leo (2026-10-21): "there's this 'write' tool call and i think it can be
// called better than just 'write' with that icon... writing? writing something?"
//
// Before: Claude Code names a Write as its block starts, before any input, and the row read the
// bare "Write" until the call finished; then it read "Edited x.ts" with no counts.
import { afterEach, expect, test } from "bun:test";
import { FOLDER, setupText, toolCall, useDom } from "./support/unknownWrite";
import type { AcpmuxActivity } from "../src/agent-session/acpmux/model";

const dom = useDom();
const PATH = `${FOLDER}/x.ts`;
const fragment = { type: "diff", path: PATH, oldText: null, newText: setupText, _meta: { acpmux: { fragment: true } } };
/// The Write's end as `settle_write` sends it: a confirmed create, or an overwrite with its old text.
const created = { status: "completed", content: [{ type: "diff", path: PATH, oldText: null, newText: setupText }] };
const oldText = setupText.replace("step 4\n", "step four\n");
const overwrote = { status: "completed", content: [{ type: "diff", path: PATH, oldText, newText: setupText }] };

/// Claude Code's Write as the acpmux translator sends it: named as its block starts (no input),
/// then the whole call with its text, then its end.
const announced = { title: "Write", kind: "edit", status: "pending" };
const whole = {
  title: "Write x.ts",
  kind: "edit",
  status: "in_progress",
  rawInput: { file_path: PATH, content: setupText },
  content: [fragment],
  locations: [{ path: PATH }],
};

async function row(item: AcpmuxActivity) {
  const { toolGroups } = await import("../src/agent-session/acpmux/conversation/toolGroups");
  const { ToolGroupRow } = await import("../src/agent-session/acpmux/conversation/ToolGroupRow");
  const { ToolRow } = await import("../src/agent-session/acpmux/conversation/ToolRow");
  // Drawn where the transcript draws it (TurnRows.tsx groupNode): a lone edit with a diff on the
  // edits line, anything else on its own row.
  const [group] = toolGroups([item]);
  await dom.render(
    group!.type === "group" ? (
      <ToolGroupRow kind={group!.kind} items={group!.items} disclosureKey={`group:${item.tool!.id}`} />
    ) : (
      <ToolRow item={item} />
    ),
  );
  return dom.text(".cv-tool__text");
}

afterEach(async () => {
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  setChipHost(undefined);
});

test("a Write named before its input reads Writing a file, not Write", async () => {
  expect(await row(await toolCall("w1", [announced]))).toBe("Writing a file");
});

test("a running Write reads Writing x.ts", async () => {
  expect(await row(await toolCall("w2", [announced, whole]))).toBe("Writing x.ts");
  expect(dom.host().querySelector(".cv-tool__counts")).toBeNull();
});

test("a Write waiting on a permission keeps its own title", async () => {
  const item = await toolCall("w2p", [{ ...whole, status: "pending" }]);
  // The label it had before this change (toolLabel), never "Writing": nothing is written yet.
  expect(await row(item)).toBe(`Write ${PATH}`);
});

test("a Write that created its file reads Wrote x.ts +N, N the lines it wrote, in the diff's add color", async () => {
  expect(await row(await toolCall("w3", [announced, whole, created]))).toBe("Wrote x.ts+9");
  expect(dom.text(".cv-tool__counts .cv-edit-diff__add")).toBe("+9");
  expect(dom.host().querySelector(".cv-tool__counts .cv-edit-diff__del")).toBeNull();
});

test("the file name is a link that opens the file and leaves the row as it was", async () => {
  const calls: [string, Record<string, unknown>][] = [];
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  setChipHost(async (method, params) => void calls.push([method, params]));
  await row(await toolCall("w4", [announced, whole, created]));
  const link = dom.host().querySelector('.cv-tool__text [role="link"]');
  expect(link?.textContent).toBe("x.ts");
  expect(link?.getAttribute("data-path")).toBe(PATH);
  const toggle = dom.host().querySelector("button.cv-tool");
  expect(toggle?.getAttribute("aria-expanded")).toBe("false");
  await dom.click(link);
  await Promise.resolve();
  expect(calls).toEqual([["link.openPath", { path: PATH }]]);
  expect(toggle?.getAttribute("aria-expanded")).toBe("false");
});

test("a Write over a file whose old text is known shows its real +a -d", async () => {
  expect(await row(await toolCall("w3k", [announced, whole, overwrote]))).toBe("Wrote x.ts+1-1");
});

test("a Write over a file of unknown old contents shows no counts", async () => {
  expect(await row(await toolCall("w3u", [announced, whole, { status: "completed" }]))).toBe("Wrote x.ts");
  expect(dom.host().querySelector(".cv-tool__counts")).toBeNull();
});

for (const key of ["Enter", " "])
  test(`${key === " " ? "Space" : key} on the file name opens the file and leaves the row closed`, async () => {
    const calls: [string, Record<string, unknown>][] = [];
    const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
    setChipHost(async (method, params) => void calls.push([method, params]));
    await row(await toolCall(`wk${key}`, [announced, whole, created]));
    const link = dom.host().querySelector<HTMLElement>('.cv-tool__text [role="link"]')!;
    const toggle = dom.host().querySelector("button.cv-tool");
    const { act } = await import("react");
    await act(async () => {
      link.dispatchEvent(new window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
    });
    await Promise.resolve();
    expect(calls).toEqual([["link.openPath", { path: PATH }]]);
    expect(toggle?.getAttribute("aria-expanded")).toBe("false");
  });

test("a failed Write reads Writing x.ts failed, with no counts", async () => {
  expect(await row(await toolCall("w5", [announced, whole, { status: "failed" }]))).toBe("Writing x.ts failed");
  expect(dom.host().querySelector(".cv-tool__counts")).toBeNull();
  expect(dom.text(".cv-tool__failed")?.trim()).toBe("failed");
});

test("a Write that failed before its input came reads Writing a file failed", async () => {
  expect(await row(await toolCall("w6", [announced, { status: "failed" }]))).toBe("Writing a file failed");
});

test("a Write with a path but no text names the file without counts", async () => {
  const item = await toolCall("w7", [
    { title: "Write x.ts", kind: "edit", status: "completed", rawInput: { file_path: PATH } },
  ]);
  expect(await row(item)).toBe("Wrote x.ts");
  expect(dom.host().querySelector(".cv-tool__counts")).toBeNull();
});

test("a done Write with no path at all reads Wrote a file", async () => {
  expect(await row(await toolCall("w8", [announced, { status: "completed" }]))).toBe("Wrote a file");
});

test("opencode's write reads the same, a relative path opening inside the session's folder", async () => {
  const item = await toolCall("w9", [
    {
      title: "write",
      kind: "edit",
      status: "completed",
      rawInput: { filePath: "docs/notes.md", content: "# Notes\n" },
    },
  ]);
  const { SessionCwdContext } = await import("../src/agent-session/acpmux/turnChanges/sessionRows");
  const { ToolRow } = await import("../src/agent-session/acpmux/conversation/ToolRow");
  await dom.render(
    <SessionCwdContext.Provider value={FOLDER}>
      <ToolRow item={item} />
    </SessionCwdContext.Provider>,
  );
  // Its input carries the text but no diff: it may have overwritten a file, so no counts.
  expect(dom.text(".cv-tool__text")).toBe("Wrote notes.md");
  expect(dom.host().querySelector('[role="link"]')?.getAttribute("data-path")).toBe(`${FOLDER}/docs/notes.md`);
});

test("a Codex patch that adds a file (adopted as Write retry.ts) reads Wrote retry.ts +N", async () => {
  const path = `${FOLDER}/src/retry.ts`;
  const item = await toolCall("w10", [
    {
      title: "Write retry.ts",
      kind: "edit",
      status: "completed",
      rawInput: { changes: { [path]: { type: "add" } } },
      content: [{ type: "diff", path, oldText: null, newText: "export const retry = 3;\nexport const wait = 50;\n" }],
    },
  ]);
  expect(await row(item)).toBe("Wrote retry.ts+2");
});

test("a key file's name stays plain text", async () => {
  const item = await toolCall("w11", [
    {
      title: "Write .env",
      kind: "edit",
      status: "completed",
      rawInput: { file_path: `${FOLDER}/.env`, content: "A=1\n" },
    },
  ]);
  expect(await row(item)).toBe("Wrote .env");
  expect(dom.host().querySelector('[role="link"]')).toBeNull();
});

test("an Edit still reads Edited x.ts +a -d", async () => {
  const item = await toolCall("e1", [
    {
      title: "Edit x.ts",
      kind: "edit",
      status: "completed",
      content: [{ type: "diff", path: PATH, oldText: "a\n", newText: "b\n" }],
    },
  ]);
  expect(await row(item)).toBe("Edited x.ts+1-1");
  expect(dom.host().querySelector('[role="link"]')).toBeNull();
});
