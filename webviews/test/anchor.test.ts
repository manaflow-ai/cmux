import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, createElement, useRef, useState } from "react";
import { resolveUiOverlayPosition, useUiAnchor, UI_ANCHOR_GAP, type UiAnchorSide } from "../src/ui/anchor";

const menuCases: Array<{ name: string; side: UiAnchorSide }> = [
  { name: "composer-computer", side: "below" },
  { name: "composer-folder", side: "above" },
  { name: "model", side: "above" },
  { name: "effort", side: "above" },
  { name: "changes-file", side: "below" },
  { name: "changes-options", side: "below" },
  { name: "changes-scope", side: "below" },
  { name: "handoff", side: "below" },
  { name: "summary", side: "below" },
  { name: "project", side: "above" },
];

const menuGeometry = new Map(
  menuCases.map((entry, index) => [
    entry.name,
    {
      anchor: {
        left: 96 + index * 24,
        top: entry.side === "above" ? 360 : 100,
        right: 160 + index * 24,
        bottom: entry.side === "above" ? 392 : 132,
      },
      overlay: { width: 180, height: 100 },
    },
  ]),
);

let dom: JSDOM;
let root: { render(node: unknown): void; unmount(): void };
const savedGlobals = new Map<string, unknown>();

function AnchorFixture({
  name,
  side,
  open,
  onOpen,
}: {
  name: string;
  side: UiAnchorSide;
  open: boolean;
  onOpen(): void;
}) {
  const geometry = menuGeometry.get(name)!;
  const anchor = useRef<HTMLButtonElement>(null);
  const overlay = useRef<HTMLDivElement>(null);
  const style = useUiAnchor(anchor, overlay, open, { side, align: "start" });
  return createElement(
    "div",
    { className: "anchor-fixture" },
    createElement(
      "button",
      {
        ref: (node: HTMLButtonElement | null) => {
          anchor.current = node;
          if (node) node.getBoundingClientRect = () => ({ ...geometry.anchor, width: 64, height: 32 }) as DOMRect;
        },
        "data-menu-trigger": name,
        onClick: onOpen,
      },
      name,
    ),
    open &&
      createElement(
        "div",
        {
          ref: (node: HTMLDivElement | null) => {
            overlay.current = node;
            if (node)
              node.getBoundingClientRect = () =>
                ({ ...geometry.overlay, left: 0, top: 0, right: 180, bottom: 100 }) as DOMRect;
          },
          "data-menu-overlay": name,
          className: "test-menu",
          style,
        },
        name,
      ),
  );
}

function AnchorFixtureRun() {
  const [open, setOpen] = useState<string | undefined>();
  return createElement(
    "div",
    null,
    menuCases.map((entry) =>
      createElement(AnchorFixture, {
        key: entry.name,
        ...entry,
        open: open === entry.name,
        onOpen: () => setOpen(entry.name),
      }),
    ),
  );
}

beforeAll(async () => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
  const names = [
    "window",
    "document",
    "navigator",
    "Element",
    "HTMLElement",
    "Node",
    "getComputedStyle",
    "IS_REACT_ACT_ENVIRONMENT",
  ];
  for (const name of names) savedGlobals.set(name, (globalThis as Record<string, unknown>)[name]);
  Object.assign(globalThis, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Element: dom.window.Element,
    HTMLElement: dom.window.HTMLElement,
    Node: dom.window.Node,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const client = await import("react-dom/client");
  root = client.createRoot(dom.window.document.getElementById("root")!);
});

afterAll(() => {
  root?.unmount();
  dom?.window.close();
  for (const [name, value] of savedGlobals) {
    if (value === undefined) delete (globalThis as Record<string, unknown>)[name];
    else (globalThis as Record<string, unknown>)[name] = value;
  }
});

describe("anchored overlay placement", () => {
  const viewport = { width: 800, height: 600 };

  test("keeps the leading edge on the trigger with the shared gap", () => {
    const placement = resolveUiOverlayPosition(
      { left: 120, top: 220, right: 180, bottom: 252 },
      { width: 240, height: 120 },
      viewport,
      { side: "above", align: "start" },
    );
    expect(placement.side).toBe("above");
    expect(Math.abs(placement.left - 120)).toBeLessThanOrEqual(2);
    expect(Math.abs(placement.top - (220 - 6 - 120))).toBeLessThanOrEqual(2);
  });

  test("flips below when the requested side has less room", () => {
    const placement = resolveUiOverlayPosition(
      { left: 300, top: 40, right: 360, bottom: 72 },
      { width: 180, height: 220 },
      viewport,
      { side: "above", align: "start" },
    );
    expect(placement.side).toBe("below");
    expect(Math.abs(placement.top - (72 + 6))).toBeLessThanOrEqual(2);
  });

  test("clamps a wide menu without losing its requested edge where possible", () => {
    const placement = resolveUiOverlayPosition(
      { left: 780, top: 260, right: 800, bottom: 292 },
      { width: 260, height: 100 },
      viewport,
      { side: "below", align: "start" },
    );
    expect(placement.left).toBe(532);
    expect(placement.maxHeight).toBeGreaterThan(0);
  });

  test("mirrors leading alignment for right-to-left pages", () => {
    const placement = resolveUiOverlayPosition(
      { left: 420, top: 220, right: 500, bottom: 252 },
      { width: 160, height: 100 },
      viewport,
      { side: "below", align: "start", direction: "rtl" },
    );
    expect(placement.left).toBe(340);
  });

  test("opens every anchored menu and keeps it within 2px of its trigger", async () => {
    await act(async () => root.render(createElement(AnchorFixtureRun)));
    for (const entry of menuCases) {
      const trigger = dom.window.document.querySelector<HTMLButtonElement>(`[data-menu-trigger="${entry.name}"]`)!;
      await act(async () => trigger.click());
      await act(async () => dom.window.dispatchEvent(new dom.window.Event("resize")));
      const overlay = dom.window.document.querySelector<HTMLElement>(`[data-menu-overlay="${entry.name}"]`)!;
      const geometry = menuGeometry.get(entry.name)!;
      const expectedLeft = geometry.anchor.left;
      const expectedTop =
        entry.side === "below"
          ? geometry.anchor.bottom + UI_ANCHOR_GAP
          : geometry.anchor.top - UI_ANCHOR_GAP - geometry.overlay.height;
      expect(Math.abs(Number.parseFloat(overlay.style.left) - expectedLeft)).toBeLessThanOrEqual(2);
      expect(Math.abs(Number.parseFloat(overlay.style.top) - expectedTop)).toBeLessThanOrEqual(2);
    }
  });
});
