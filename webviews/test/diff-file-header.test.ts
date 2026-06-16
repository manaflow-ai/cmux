import { expect, test } from "bun:test";
import type { FileDiffMetadata } from "@pierre/diffs";
import { JSDOM } from "jsdom";
import { act, createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { createRoot } from "react-dom/client";
import { DiffFileHeader, diffFileLanguageLabel, diffFileLineTotals } from "../src/diff-file-header";
import { createDiffViewerLabelResolver } from "../src/labels";

function fileDiff(partial: Partial<FileDiffMetadata>): FileDiffMetadata {
  return { name: "", type: "change", hunks: [], ...partial } as FileDiffMetadata;
}

function visibleText(markup: string): string {
  return markup.replace(/<[^>]*>/g, "");
}

test("diffFileLanguageLabel is the uppercased file extension (locale-independent)", () => {
  expect(diffFileLanguageLabel(fileDiff({ name: "src/App.tsx" }))).toBe("TSX");
  expect(diffFileLanguageLabel(fileDiff({ name: "src/util.ts" }))).toBe("TS");
  expect(diffFileLanguageLabel(fileDiff({ name: "Sources/Foo.swift" }))).toBe("SWIFT");
  expect(diffFileLanguageLabel(fileDiff({ name: "notes.xyz" }))).toBe("XYZ");
  expect(diffFileLanguageLabel(fileDiff({ name: "data.toml" }))).toBe("TOML");
});

test("diffFileLanguageLabel returns empty string for files without a usable extension", () => {
  expect(diffFileLanguageLabel(fileDiff({ name: "zzqqxnotathing" }))).toBe(""); // no extension
  expect(diffFileLanguageLabel(fileDiff({ name: "Makefile" }))).toBe(""); // no extension
  expect(diffFileLanguageLabel(fileDiff({ name: ".gitignore" }))).toBe(""); // dotfile, not an extension
  expect(diffFileLanguageLabel(fileDiff({ name: "archive.tar.gz" }))).toBe("GZ");
  expect(diffFileLanguageLabel(fileDiff({ name: "weird.extension12345" }))).toBe(""); // too long to be a tidy badge
});

test("diffFileLineTotals sums per-hunk addition/deletion line counts", () => {
  const totals = diffFileLineTotals(
    fileDiff({
      hunks: [
        { additionLines: 3, deletionLines: 1 },
        { additionLines: 6, deletionLines: 2 },
      ] as FileDiffMetadata["hunks"],
    }),
  );
  expect(totals).toEqual({ additions: 9, deletions: 3 });
});

test("diffFileLineTotals is zero for an empty hunk list", () => {
  expect(diffFileLineTotals(fileDiff({ hunks: [] }))).toEqual({ additions: 0, deletions: 0 });
});

test("DiffFileHeader renders rename source path as visible text", () => {
  const markup = renderToStaticMarkup(
    createElement(DiffFileHeader, {
      fileDiff: fileDiff({
        name: "Sources/NewName.swift",
        prevName: "Sources/OldName.swift",
      }),
    }),
  );
  const text = visibleText(markup);

  expect(text).toContain("Sources/OldName.swift");
  expect(text).toContain("→");
  expect(text).toContain("Sources/NewName.swift");
});

test("DiffFileHeader renders parsed oldName/newName fallback paths", () => {
  const diff = {
    type: "change",
    hunks: [],
    oldName: "src/OldWidget.ts",
    newName: "src/NewWidget.ts",
  } as unknown as FileDiffMetadata;
  const markup = renderToStaticMarkup(createElement(DiffFileHeader, { fileDiff: diff }));
  const text = visibleText(markup);

  expect(diffFileLanguageLabel(diff)).toBe("TS");
  expect(text).toContain("src/OldWidget.ts");
  expect(text).toContain("→");
  expect(text).toContain("src/NewWidget.ts");
});

test("DiffFileHeader toggles collapse and opens a dedicated tab without also toggling", async () => {
  const dom = new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>");
  const previousWindow = (globalThis as any).window;
  const previousDocument = (globalThis as any).document;
  const previousHTMLElement = (globalThis as any).HTMLElement;
  const previousActEnvironment = (globalThis as any).IS_REACT_ACT_ENVIRONMENT;
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).HTMLElement = dom.window.HTMLElement;
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  let toggleCount = 0;
  let openCount = 0;
  const root = createRoot(dom.window.document.getElementById("root")!);

  try {
    await act(async () => {
      root.render(createElement(DiffFileHeader, {
        collapsed: false,
        fileDiff: fileDiff({ name: "src/App.tsx" }),
        label: createDiffViewerLabelResolver(undefined),
        onOpenInTab: () => {
          openCount += 1;
        },
        onToggleCollapsed: () => {
          toggleCount += 1;
        },
      }));
    });

    const header = dom.window.document.querySelector<HTMLElement>(".cmux-fileheader");
    expect(header?.getAttribute("role")).toBe("button");
    expect(header?.getAttribute("aria-expanded")).toBe("true");

    await act(async () => {
      header?.click();
    });
    expect(toggleCount).toBe(1);

    await act(async () => {
      header?.dispatchEvent(new dom.window.KeyboardEvent("keydown", { bubbles: true, key: "Enter" }));
    });
    expect(toggleCount).toBe(2);

    const openButton = dom.window.document.querySelector<HTMLButtonElement>(".cmux-fileheader-open");
    await act(async () => {
      openButton?.dispatchEvent(new dom.window.KeyboardEvent("keydown", { bubbles: true, key: "Enter" }));
    });
    expect(openCount).toBe(0);
    expect(toggleCount).toBe(2);

    await act(async () => {
      openButton?.click();
    });
    expect(openCount).toBe(1);
    expect(toggleCount).toBe(2);
  } finally {
    await act(async () => {
      root.unmount();
    });
    dom.window.close();
    if (previousWindow === undefined) {
      delete (globalThis as any).window;
    } else {
      (globalThis as any).window = previousWindow;
    }
    if (previousDocument === undefined) {
      delete (globalThis as any).document;
    } else {
      (globalThis as any).document = previousDocument;
    }
    if (previousHTMLElement === undefined) {
      delete (globalThis as any).HTMLElement;
    } else {
      (globalThis as any).HTMLElement = previousHTMLElement;
    }
    if (previousActEnvironment === undefined) {
      delete (globalThis as any).IS_REACT_ACT_ENVIRONMENT;
    } else {
      (globalThis as any).IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
    }
  }
});
