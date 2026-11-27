// l10n-allow-file: test fixtures (a real Codex call and the English its row draws).
// Leo, 2026-11-21, on a row that read "Read $f": "this is not a good enough tool call heading that we
// have derived". Codex parses `cat $f` in a loop as a read at `$f`; the drawn row read the file at
// that location (readPath.ts, ReadLabel.tsx) and showed `$f` even once its label was fixed. It now
// reads as its command: the loop's files.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { shownText, visibleLabelText } from "./support/factsCard";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "customElements", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    customElements: window.customElements,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.querySelector<HTMLElement>("#root")!;
});

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
});

const codexRead = (id: string, command: string, path: string) =>
  ({
    kind: "activity",
    text: "Read $f",
    tool: { id, kind: "read", title: "Read $f", status: "completed", command, locations: [{ path }] },
  }) as never;

test("a Codex read of a loop's $f draws the loop's files, never $f", async () => {
  const { createRoot } = await import("react-dom/client");
  const { ToolRow } = await import("../src/agent-session/acpmux/conversation/ToolRow");
  const { readPath } = await import("../src/agent-session/acpmux/conversation/readPath");
  const loop = codexRead("loop", "for f in a.md b.md; do cat $f; done", "$f");
  const one = codexRead("one", "for f in a.md; do cat $f; done", "${f}");
  expect(readPath((loop as { tool: never }).tool)).toBeUndefined();
  expect(readPath((one as { tool: never }).tool)).toBe("a.md");
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <>
        <ToolRow item={loop} />
        <ToolRow item={one} />
      </>,
    ),
  );
  const drawn = [...host.querySelectorAll(".cv-tool__text")].map(visibleLabelText);
  expect(drawn).toEqual(["Read 2 files (a.md, b.md)", "Read a.md"]);
  expect(host.textContent).not.toContain("$f");
});
