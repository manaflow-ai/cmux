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
import { translate } from "../src/agent-session/acpmux/i18n";
import { numberedImageLabels } from "../src/agent-session/acpmux/imageLabel";

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
// Two different screenshots pasted from the clipboard both come as image.png.
const twin = { id: "f".repeat(64), mimeType: "image/png", name: "image.png" };
const prompt = (id: string, extra: Partial<AcpmuxRow>) => ({ ...extra, id, kind: "user", text: "look" }) as AcpmuxRow;

test("the person's pasted images are Sources, each once, and another agent's are not", () => {
  const rows = [
    prompt("u1", { images: [shot] }),
    prompt("u2", { images: [shot, unnamed] }),
    prompt("u3", { images: [{ id: "c".repeat(64), mimeType: "image/png" }], untyped: true }),
    prompt("u4", { images: [{ id: "d".repeat(64), mimeType: "image/png" }], from: "chief" }),
    prompt("u5", { images: [{ id: "e".repeat(64), mimeType: "image/png" }], failed: true }),
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
  const errors: string[] = [];
  const consoleError = console.error;
  console.error = (...args: unknown[]) => errors.push(args.map(String).join(" "));
  const opened: [string, string][] = [];
  const read: string[] = [];
  await act(async () =>
    root!.render(
      <SourcesSection
        sources={
          sessionSummary([
            prompt("u1", { images: [shot, unnamed, twin] }),
            prompt("u2", { images: [{ ...twin, id: "9".repeat(64) }] }),
          ]).sources
        }
        expanded={false}
        onExpandedChange={() => {}}
        onOpenImage={(src, alt) => opened.push([src, alt])}
        readImage={async (id) => (read.push(id), id === shot.id ? "data:image/png;base64,AA==" : undefined)}
      />,
    ),
  );
  console.error = consoleError;
  // Each image is its own row even when two share a name.
  expect(errors.filter((error) => error.includes("same key"))).toEqual([]);
  const rows = [...host.querySelectorAll("li")];
  // Unnamed and "image.png" images read Screenshot 1, 2, 3 in chat order; a real name stays.
  expect(rows.map((row) => row.textContent)).toEqual([shot.name, "Screenshot 1", "Screenshot 2", "Screenshot 3"]);
  await act(async () => rows[0]!.querySelector("button")!.click());
  expect(read).toEqual([shot.id]);
  expect(opened).toEqual([["data:image/png;base64,AA==", shot.name]]);
  // Bytes acpmux no longer has: the row says so instead of opening nothing.
  await act(async () => rows[1]!.querySelector("button")!.click());
  expect(host.querySelectorAll("li")[1]!.querySelector("[role=alert]")?.textContent).toBe("Image unavailable");
});

// Leo, 2026-11-05, on five Sources rows all reading "image.png": "instead of, like screenshot
// number one, two, three, four, or whatever."
test("a list numbers only the images with no name of their own, naming the app when known", () => {
  expect(
    numberedImageLabels(translate, [
      { name: "image.png" },
      { name: "Screenshot 2026-10-28.png" },
      { name: "Pasted Graphic 2" },
      { name: "image.png", source: "Safari" },
      {},
    ]),
  ).toEqual(["Screenshot 1", "Screenshot 2026-10-28.png", "Screenshot 2", "Safari screenshot 3", "Screenshot 4"]);
});

test("Sources numbers pasted screenshots across the whole list, in the web and native rows alike", async () => {
  const { sourceLabels } = await import("../src/agent-session/acpmux/session-info/SourcesSection");
  const { sourcesSection } = await import("../src/agent-session/acpmux/session-info/native/sources");
  const { NativeInfoActions } = await import("../src/agent-session/acpmux/session-info/native/model");
  const hex = (n: number) => n.toString(16).repeat(64);
  const rows = [
    prompt("u1", { images: [{ ...twin, id: hex(1) }] }),
    { id: "a1", kind: "assistant", text: "see https://example.com/docs" } as AcpmuxRow,
    prompt("u2", { images: [shot, { ...twin, id: hex(2), source: { name: "Safari" } }] }),
    ...[3, 4, 5, 6].map((n) => prompt(`u${n}`, { images: [{ ...twin, id: hex(n) }] })),
  ];
  const sources = sessionSummary(rows).sources;
  expect(sources[3]!.image).toEqual({ id: hex(2), src: undefined, source: "Safari" });
  const expected = [
    "Screenshot 1",
    "example.com/docs",
    shot.name,
    "Safari screenshot 2",
    "Screenshot 3",
    "Screenshot 4",
    "Screenshot 5",
    "Screenshot 6",
  ];
  expect(sourceLabels(translate, sources)).toEqual(expected);
  const section = (expanded: boolean) =>
    sourcesSection(
      { sources, expanded, onExpandedChange: () => {}, open: true },
      new NativeInfoActions(),
      translate,
    )!;
  // Folded, the first five keep the numbers they have unfolded.
  expect(section(false).rows.map((row) => row.title)).toEqual(expected.slice(0, 5));
  expect(section(true).rows.map((row) => row.title)).toEqual(expected);
});
