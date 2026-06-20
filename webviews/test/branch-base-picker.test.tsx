import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { flushSync } from "react-dom";
import { createRoot, type Root } from "react-dom/client";
import { BranchBasePicker, buildFlatRows, type BranchPickerPayload } from "../src/BranchBasePicker";
import { createDiffViewerLabelResolver } from "../src/labels";

// Behavior coverage for the render cap (huge refs lists must not render every
// row) and the empty-state "type to filter" affordance, plus the filtered total
// cap. The data is fetched once; these assert only how many rows become DOM.

let root: Root | null = null;
let dom: JSDOM | null = null;
const originalGlobals = new Map<string, unknown>();
for (const key of ["window", "document", "navigator", "Element", "Node", "HTMLElement", "customElements", "fetch"]) {
  originalGlobals.set(key, (globalThis as Record<string, unknown>)[key]);
}

afterEach(async () => {
  if (root) {
    flushSync(() => root?.unmount());
  }
  root = null;
  await new Promise((resolve) => setTimeout(resolve, 0));
  dom?.window.close();
  dom = null;
  for (const [key, value] of originalGlobals) {
    if (value === undefined) {
      delete (globalThis as Record<string, unknown>)[key];
    } else {
      (globalThis as Record<string, unknown>)[key] = value;
    }
  }
});

const label = createDiffViewerLabelResolver(undefined);

function pickerPayload(remoteCount: number): BranchPickerPayload {
  const refs = {
    groups: [
      { id: "suggested", label: "Suggested", rows: [
        { ref: "origin/main", label: "origin/main", reason: "PR base", current: false },
      ] },
      { id: "remotes", label: "Remotes", rows: Array.from({ length: remoteCount }, (_v, index) => ({
        ref: `origin/feature-${index}`,
        label: `origin/feature-${index}`,
      })) },
    ],
  };
  return {
    repoRoot: "/tmp/mock",
    currentRef: "origin/main",
    currentReason: "fork point",
    confidence: "high",
    aheadBehind: { ahead: 1, behind: 1 },
    refsURL: "data:application/json," + encodeURIComponent(JSON.stringify(refs)),
    regenerateURLTemplate: "about:blank#base={ref}",
  };
}

test("base picker caps a huge remotes group and shows a type-to-filter affordance", async () => {
  dom = createDom();
  installDomGlobals(dom);
  renderPicker(pickerPayload(2304));

  // Open the popover; fetch resolves the data: URL.
  document.querySelector<HTMLButtonElement>(".base-picker-button")?.click();
  await waitFor(() => rowCount() > 0);

  // 1 suggested + 8 capped remotes = 9 rendered option rows (not 2305).
  expect(rowCount()).toBe(9);
  const more = document.querySelector(".base-picker-more");
  expect(more).toBeTruthy();
  // 2304 - 8 visible = 2296 hidden.
  expect(more?.textContent).toContain("2296 more, type to filter");
});

test("empty filter caps each group and flags the hidden tail count", () => {
  const groups = [
    { id: "suggested", label: "Suggested", rows: [{ ref: "origin/main", label: "origin/main" }] },
    { id: "remotes", label: "Remotes", rows: Array.from({ length: 2304 }, (_v, index) => ({
      ref: `origin/feature-${index}`,
      label: `origin/feature-${index}`,
    })) },
  ];
  const flat = buildFlatRows(groups, "", pickerPayload(0), label);
  // 1 suggested + 8 capped remotes.
  expect(flat.length).toBe(9);
  // Only the last rendered remote carries the hidden-tail count (2304 - 8).
  expect(flat.filter((row) => row.moreCount > 0).length).toBe(1);
  expect(flat[flat.length - 1].moreCount).toBe(2296);
});

test("filtering scans every group and caps the rendered total at 50", () => {
  const groups = [
    { id: "remotes", label: "Remotes", rows: Array.from({ length: 2304 }, (_v, index) => ({
      ref: `origin/feature-${index}`,
      label: `origin/feature-${index}`,
    })) },
  ];
  const flat = buildFlatRows(groups, "feature-1", pickerPayload(0), label);
  // Hundreds match "feature-1"; rendered set is capped at 50 with no "more" rows.
  expect(flat.length).toBe(50);
  expect(flat.every((row) => row.moreCount === 0)).toBe(true);
  // Filtering reaches past the empty-filter cap of 8 (e.g. origin/feature-100).
  expect(flat.some((row) => row.row.ref === "origin/feature-100")).toBe(true);
});

test("a query matching nothing offers the raw typed ref", () => {
  const groups = [
    { id: "remotes", label: "Remotes", rows: [{ ref: "origin/main", label: "origin/main" }] },
  ];
  const flat = buildFlatRows(groups, "zzz-nope", pickerPayload(0), label);
  expect(flat[0]?.raw).toBe(true);
  expect(flat[0]?.row.ref).toBe("zzz-nope");
});

function createDom(): JSDOM {
  return new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>", {
    url: "http://127.0.0.1/diff",
  });
}

function installDomGlobals(nextDom: JSDOM): void {
  const g = globalThis as Record<string, unknown>;
  g.window = nextDom.window;
  g.document = nextDom.window.document;
  g.navigator = nextDom.window.navigator;
  g.Element = nextDom.window.Element;
  g.Node = nextDom.window.Node;
  g.HTMLElement = nextDom.window.HTMLElement;
  g.customElements = nextDom.window.customElements;
  // The autofocused filter input makes React run its legacy IE onpropertychange
  // polyfill (JSDOM misreports 'input' support), which calls attach/detachEvent
  // on the active element. JSDOM lacks them; stub no-ops on Element.prototype.
  const elementProto = nextDom.window.Element.prototype as unknown as {
    attachEvent: () => void;
    detachEvent: () => void;
  };
  elementProto.attachEvent = () => {};
  elementProto.detachEvent = () => {};
  // Resolve data: URLs the picker fetches (Bun's global Response).
  g.fetch = (input: RequestInfo | URL) => {
    const url = String(input);
    const comma = url.indexOf(",");
    const json = decodeURIComponent(url.slice(comma + 1));
    return Promise.resolve(new Response(json, { status: 200 }));
  };
}

function renderPicker(picker: BranchPickerPayload): void {
  const container = document.getElementById("root");
  expect(container).toBeTruthy();
  root = createRoot(container!);
  flushSync(() => {
    root?.render(<BranchBasePicker label={label} onNavigate={() => {}} picker={picker} />);
  });
}

function rowCount(): number {
  return document.querySelectorAll(".base-picker-row").length;
}

async function waitFor(predicate: () => boolean): Promise<void> {
  const timeoutAt = Date.now() + 1000;
  while (!predicate()) {
    if (Date.now() > timeoutAt) {
      throw new Error("Timed out waiting for picker assertion");
    }
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}
