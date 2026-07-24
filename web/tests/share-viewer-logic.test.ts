import { describe, expect, mock, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";

import type { ShareClient } from "../app/[locale]/share/[code]/share-connection";
import type {
  LayoutNode,
  RenderGridFrame,
} from "../app/[locale]/share/[code]/share-protocol";
import { TerminalGridModel } from "../app/[locale]/share/[code]/terminal-grid";
import { keyEventToBytes } from "../app/[locale]/share/[code]/terminal-keys";

mock.module("next-intl", () => ({
  useTranslations: () => (key: string) => key,
}));

const {
  createAnimationFrameScheduler,
  LayoutView,
  paneKeyOf,
  paneRefFromKey,
} = await import(
  "../app/[locale]/share/[code]/share-panes"
);
const { submitChatDraft } = await import(
  "../app/[locale]/share/[code]/share-chat"
);
const {
  hasEditableShortcutFocus,
  installKeydownListener,
  shouldOpenBubbleShortcut,
} = await import("../app/[locale]/share/[code]/share-viewer");

function fullFrame(overrides: Partial<RenderGridFrame> = {}): RenderGridFrame {
  return {
    format: "cmux.render-grid.v1",
    surface_id: "s-1",
    state_seq: 1,
    columns: 10,
    rows: 3,
    full: true,
    styles: [{ id: 0 }],
    row_spans: [
      { row: 0, column: 0, style_id: 0, text: "hello" },
      { row: 1, column: 2, style_id: 0, text: "world" },
    ],
    cursor: { row: 1, column: 7 },
    terminal_background: "1e1e2e",
    terminal_foreground: "cdd6f4",
    ...overrides,
  };
}

describe("TerminalGridModel", () => {
  test("applies a full frame and reads theme colors", () => {
    const model = new TerminalGridModel();
    expect(model.apply(fullFrame())).toBe(true);
    expect(model.ready).toBe(true);
    expect(model.cols).toBe(10);
    expect(model.background).toBe("#1e1e2e");
    expect(model.rowSpans(0)[0]?.text).toBe("hello");
    expect(model.cursor?.column).toBe(7);
  });

  test("rejects deltas before any full frame", () => {
    const model = new TerminalGridModel();
    expect(
      model.apply(fullFrame({ full: false, cleared_rows: [0], row_spans: [] })),
    ).toBe(false);
  });

  test("delta clears rows then repaints the spans it carries", () => {
    const model = new TerminalGridModel();
    model.apply(fullFrame());
    const ok = model.apply(
      fullFrame({
        full: false,
        cleared_rows: [0, 1],
        row_spans: [{ row: 1, column: 0, style_id: 0, text: "changed" }],
        cursor: { row: 0, column: 0 },
      }),
    );
    expect(ok).toBe(true);
    expect(model.rowSpans(0)).toEqual([]);
    expect(model.rowSpans(1)[0]?.text).toBe("changed");
  });

  test("a frame without a cursor clears the previously painted cursor", () => {
    const model = new TerminalGridModel();
    expect(model.apply(fullFrame())).toBe(true);
    expect(model.cursor?.column).toBe(7);

    expect(
      model.apply(fullFrame({ full: false, cursor: undefined, row_spans: [] })),
    ).toBe(true);
    expect(model.cursor).toBeNull();
  });

  test("rejects wrong formats, geometry-changing deltas, and oversized allocations", () => {
    const model = new TerminalGridModel();
    expect(model.apply(fullFrame({ format: "cmux.render-grid.v2" }))).toBe(false);
    expect(() => model.apply({ ...fullFrame(), rows: 1_000_000 })).not.toThrow();
    expect(model.apply({ ...fullFrame(), rows: 1_000_000 })).toBe(false);
    expect(model.apply(null)).toBe(false);
    model.apply(fullFrame());
    expect(model.apply(fullFrame({ full: false, columns: 12 }))).toBe(false);
  });

  test("rejects oversized grid styles, palettes, and cleared-row collections", () => {
    const model = new TerminalGridModel();
    expect(
      model.apply({
        ...fullFrame(),
        styles: Array.from({ length: 4_097 }, (_, id) => ({ id })),
      }),
    ).toBe(false);
    expect(
      model.apply({
        ...fullFrame(),
        terminal_theme: {
          background: "#000000",
          foreground: "#ffffff",
          cursor: "#ffffff",
          palette: Array.from({ length: 257 }, () => "#000000"),
        },
      }),
    ).toBe(false);
    expect(
      model.apply({
        ...fullFrame(),
        cleared_rows: Array.from({ length: 501 }, () => 0),
      }),
    ).toBe(false);
    expect(model.generation).toBe(0);
  });

  test("coalesces repeated grid notifications into one animation-frame paint", () => {
    let nextID = 1;
    const callbacks = new Map<number, () => void>();
    const cancelled: number[] = [];
    let paints = 0;
    const scheduler = createAnimationFrameScheduler(
      (callback) => {
        const id = nextID;
        nextID += 1;
        callbacks.set(id, callback);
        return id;
      },
      (id) => {
        callbacks.delete(id);
        cancelled.push(id);
      },
      () => {
        paints += 1;
      },
    );

    scheduler.schedule();
    scheduler.schedule();
    scheduler.schedule();
    expect(callbacks.size).toBe(1);
    callbacks.get(1)?.();
    expect(paints).toBe(1);

    scheduler.schedule();
    scheduler.cancel();
    expect(cancelled).toEqual([2]);
    expect(paints).toBe(1);
  });
});

describe("chat draft admission", () => {
  test("clears only after the socket accepts the message", () => {
    expect(submitChatDraft("keep me", () => false)).toBe("keep me");
    expect(submitChatDraft("send me", () => true)).toBe("");
    expect(submitChatDraft("   ", () => true)).toBe("   ");
  });
});

describe("terminal-only split renderer", () => {
  test("round-trips opaque workspace and pane ids for cursor targeting", () => {
    const key = paneKeyOf("workspace with spaces", "pane with spaces");
    expect(paneRefFromKey(key)).toEqual([
      "workspace with spaces",
      "pane with spaces",
    ]);
    expect(paneRefFromKey("malformed")).toBeNull();
  });

  test("preserves split ratios and renders non-terminal leaves as stable placeholders", () => {
    const layout: LayoutNode = {
      kind: "split",
      axis: "h",
      ratio: 0.25,
      a: { kind: "pane", pane: "terminal:1", content: "terminal" },
      b: {
        kind: "split",
        axis: "v",
        ratio: 0.6,
        a: { kind: "pane", pane: "browser:1", content: "browser" },
        b: {
          kind: "split",
          axis: "h",
          ratio: 0.5,
          a: { kind: "pane", pane: "agent:1", content: "agent" },
          b: { kind: "pane", pane: "other:1", content: "other" },
        },
      },
    };
    const client = {} as ShareClient;

    const html = renderToStaticMarkup(
      createElement(LayoutView, {
        client,
        ws: "workspace:1",
        node: layout,
        canType: false,
      }),
    );

    expect(html).toContain("flex-basis:25%");
    expect(html).toContain("flex-basis:75%");
    expect(html).toContain('data-share-placeholder="browser"');
    expect(html).toContain('data-share-placeholder="agent"');
    expect(html).toContain('data-share-placeholder="other"');
    expect(html.match(/data-share-placeholder=/g)).toHaveLength(3);
    expect(html.match(/data-share-pane=/g)).toHaveLength(1);
    expect(html.match(/<canvas/g)).toHaveLength(1);
    expect(html).not.toContain("<textarea");
    expect(html).not.toContain('role="application"');
  });

  test("viewer terminal overlay is non-editable", () => {
    const html = renderToStaticMarkup(
      createElement(LayoutView, {
        client: {} as ShareClient,
        ws: "workspace:1",
        node: { kind: "pane", pane: "terminal:1", content: "terminal" },
        canType: false,
      }),
    );

    expect(html).toContain('role="presentation"');
    expect(html).toContain('tabindex="-1"');
    expect(html).not.toContain('role="textbox"');
  });
});

describe("bubble shortcut", () => {
  function focusElement({
    tagName = "DIV",
    attributes = {},
    disabled = false,
    readOnly = false,
    parentElement = null,
  }: {
    tagName?: string;
    attributes?: Record<string, string>;
    disabled?: boolean;
    readOnly?: boolean;
    parentElement?: Element | null;
  } = {}): Element {
    return {
      tagName,
      disabled,
      readOnly,
      parentElement,
      getAttribute(name: string) {
        return attributes[name] ?? null;
      },
    } as unknown as Element;
  }

  test("opens only for slash with a terminal pointer, no draft, and no editable focus", () => {
    const eligible = {
      key: "/",
      hasEditableFocus: false,
      hasPointer: true,
      hasDraft: false,
    };
    expect(shouldOpenBubbleShortcut(eligible)).toBe(true);
    expect(shouldOpenBubbleShortcut({ ...eligible, key: "a" })).toBe(false);
    expect(
      shouldOpenBubbleShortcut({ ...eligible, hasEditableFocus: true }),
    ).toBe(false);
    expect(shouldOpenBubbleShortcut({ ...eligible, hasPointer: false })).toBe(false);
    expect(shouldOpenBubbleShortcut({ ...eligible, hasDraft: true })).toBe(false);
  });

  test("recognizes terminal textboxes and common editable focus targets", () => {
    expect(
      hasEditableShortcutFocus(
        focusElement({ attributes: { role: "textbox" } }),
      ),
    ).toBe(true);
    expect(hasEditableShortcutFocus(focusElement({ tagName: "INPUT" }))).toBe(true);
    expect(hasEditableShortcutFocus(focusElement({ tagName: "TEXTAREA" }))).toBe(true);
    expect(
      hasEditableShortcutFocus(
        focusElement({ attributes: { contenteditable: "true" } }),
      ),
    ).toBe(true);
    expect(
      hasEditableShortcutFocus(
        focusElement({
          parentElement: focusElement({ attributes: { role: "textbox" } }),
        }),
      ),
    ).toBe(true);
    expect(
      hasEditableShortcutFocus(
        focusElement({ tagName: "INPUT", readOnly: true }),
      ),
    ).toBe(false);
    expect(hasEditableShortcutFocus(focusElement())).toBe(false);
  });

  test("removes the exact window listener during callback-ref cleanup", () => {
    let installed: ((event: KeyboardEvent) => void) | null = null;
    const target = {
      addEventListener(type: "keydown", listener: (event: KeyboardEvent) => void) {
        expect(type).toBe("keydown");
        installed = listener;
      },
      removeEventListener(type: "keydown", listener: (event: KeyboardEvent) => void) {
        expect(type).toBe("keydown");
        if (installed === listener) installed = null;
      },
    };
    const listener = () => {};

    const cleanup = installKeydownListener(target, listener);

    expect(installed).toBe(listener);
    cleanup();
    expect(installed).toBeNull();
  });
});

describe("keyEventToBytes", () => {
  const key = (
    value: string,
    mods: Partial<
      Record<"ctrlKey" | "altKey" | "metaKey" | "shiftKey", boolean>
    > = {},
  ) =>
    keyEventToBytes({
      key: value,
      ctrlKey: false,
      altKey: false,
      metaKey: false,
      shiftKey: false,
      ...mods,
    });

  test("printables, enter, backspace, arrows", () => {
    expect(key("a")).toBe("a");
    expect(key("Enter")).toBe("\r");
    expect(key("Backspace")).toBe("\x7f");
    expect(key("ArrowUp")).toBe("\x1b[A");
    expect(key("ArrowLeft", { shiftKey: true })).toBe("\x1b[1;2D");
  });

  test("control combos and meta passthrough", () => {
    expect(key("c", { ctrlKey: true })).toBe("\x03");
    expect(key("c", { metaKey: true })).toBeNull();
    expect(key("Shift")).toBeNull();
  });
});
