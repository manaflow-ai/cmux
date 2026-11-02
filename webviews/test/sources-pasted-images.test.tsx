// Session Info's Sources lists what the agent took in: the pages, files and tools it read, and the
// images the person pasted into their prompts (Leo, ask-7e325f5c52: "the sources should be,
// like, whatever the agent reads and takes in for its own sources, and, like, whatever images
// you're pasting"). An image appears once however often it is sent, and its row opens the viewer.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { sessionSummary } from "../src/agent-session/acpmux/summary/sessionSummary";

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

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const shot = { id: "a".repeat(64), mimeType: "image/png", name: "Screenshot 2026-10-28.png" };
const unnamed = { id: "b".repeat(64), mimeType: "image/png" };
const prompt = (id: string, extra: Partial<AcpmuxRow>) => ({ ...extra, id, kind: "user", text: "look" }) as AcpmuxRow;

test("the person's pasted images are Sources, each once, and another agent's are not", () => {
  const rows = [
    prompt("u1", { images: [shot] }),
    prompt("u2", { images: [shot, unnamed] }),
    prompt("u3", { images: [{ id: "c".repeat(64), mimeType: "image/png" }], untyped: true }),
    prompt("u4", { images: [{ id: "d".repeat(64), mimeType: "image/png" }], from: "chief" }),
  ];
  const sources = sessionSummary(rows).sources;
  expect(sources).toEqual([
    { label: shot.name, kind: "image", image: { id: shot.id, src: undefined } },
    { label: "", kind: "image", image: { id: unnamed.id, src: undefined } },
  ]);
});

test("an image source's row reads its bytes by id and opens the viewer", async () => {
  const { createRoot } = await import("react-dom/client");
  const { SourcesSection } = await import("../src/agent-session/acpmux/session-info/SourcesSection");
  act(() => root?.unmount());
  root = createRoot(host);
  const opened: [string, string][] = [];
  const read: string[] = [];
  await act(async () =>
    root!.render(
      <SourcesSection
        sources={sessionSummary([prompt("u1", { images: [shot, unnamed] })]).sources}
        expanded={false}
        onExpandedChange={() => {}}
        onOpenImage={(src, alt) => opened.push([src, alt])}
        readImage={async (id) => (read.push(id), id === shot.id ? "data:image/png;base64,AA==" : undefined)}
      />,
    ),
  );
  const rows = [...host.querySelectorAll("li")];
  expect(rows.map((row) => row.textContent)).toEqual([shot.name, "Image"]);
  await act(async () => rows[0]!.querySelector("button")!.click());
  expect(read).toEqual([shot.id]);
  expect(opened).toEqual([["data:image/png;base64,AA==", shot.name]]);
  // Bytes acpmux no longer has: the row says so instead of opening nothing.
  await act(async () => rows[1]!.querySelector("button")!.click());
  expect(host.querySelectorAll("li")[1]!.querySelector("[role=alert]")?.textContent).toBe("Image unavailable");
});
