// The plain attach says on screen apart from the reader's hand on it, and asks acpmux to leave the
// agent's stream out while the page is not on screen (CMUX-571: about 5 MB/s reached the app's panes
// with chats open, hidden panes included). The host lets exactly these params through.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { plainAttach } from "./attachParams";

const HOST_PARAMS = readFileSync(
  `${import.meta.dir}/../../../../Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AcpmuxPaneMethods+Params.swift`,
  "utf8",
);

/// The host's allowed top-level params of `method` (AcpmuxPaneMethods+Params.swift `knownParams`).
function hostParams(method: string): string[] {
  const line = HOST_PARAMS.split("\n").find((row) => row.trim().startsWith(`"${method}": (`));
  if (!line) throw new Error(`no params rule for ${method}`);
  const list = line.slice(line.indexOf("([") + 2, line.indexOf("]"));
  return [...list.matchAll(/"([^"]+)"/g)].map((match) => match[1]);
}

test("a hidden page's attach asks for no stream while hidden and keeps attending apart", () => {
  const params = plainAttach("chat-1", { settled: false, visible: false, attending: true, local: true, maxBytes: 1 });
  expect(params.visible).toBe(false);
  expect(params.attending).toBe(true);
  expect(params.quietHidden).toBe(true);
});

test("a shown page whose reader is away is still on screen", () => {
  const params = plainAttach("chat-1", { settled: true, visible: true, attending: false, local: false, maxBytes: 1 });
  expect(params.visible).toBe(true);
  expect(params.attending).toBe(false);
});

test("the host lets every param of the plain attach and the view through", () => {
  const params = plainAttach("chat-1", { settled: true, visible: true, attending: true, local: true, maxBytes: 1 });
  const allowed = new Set(hostParams("_acpmux/attach"));
  for (const key of Object.keys(params)) expect(allowed.has(key)).toBe(true);
  expect(hostParams("_acpmux/view")).toEqual(["sessionId", "visible", "attending", "seenSeq"]);
});
