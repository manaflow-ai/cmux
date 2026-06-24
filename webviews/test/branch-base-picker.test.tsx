import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { flushSync } from "react-dom";
import { createRoot, type Root } from "react-dom/client";
import type { BranchPickerPayload } from "../src/BranchBasePicker";

// Behavior coverage for the render cap (huge refs lists must not render every
// row) and the empty-state "type to filter" affordance, plus the filtered total
// cap. The data is fetched once; these assert only how many rows become DOM.

let root: Root | null = null;
let dom: JSDOM | null = null;
const originalGlobals = new Map<string, unknown>();
for (const key of ["window", "document", "navigator", "Element", "Node", "HTMLElement", "customElements", "getComputedStyle", "requestAnimationFrame", "cancelAnimationFrame", "fetch"]) {
  originalGlobals.set(key, (globalThis as Record<string, unknown>)[key]);
}

installBootstrapDom();
const { BranchBasePicker, buildFlatRows, toCurrentOriginRelative } = await import("../src/BranchBasePicker");
const { createDiffViewerLabelResolver } = await import("../src/labels");

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

function installBootstrapDom(): void {
  const bootstrapDom = createDom();
  const g = globalThis as Record<string, unknown>;
  g.window = bootstrapDom.window;
  g.document = bootstrapDom.window.document;
  g.navigator = bootstrapDom.window.navigator;
  g.Element = bootstrapDom.window.Element;
  g.Node = bootstrapDom.window.Node;
  g.HTMLElement = bootstrapDom.window.HTMLElement;
  g.customElements = bootstrapDom.window.customElements;
  g.getComputedStyle = bootstrapDom.window.getComputedStyle.bind(bootstrapDom.window);
  g.requestAnimationFrame = bootstrapDom.window.requestAnimationFrame.bind(bootstrapDom.window);
  g.cancelAnimationFrame = bootstrapDom.window.cancelAnimationFrame.bind(bootstrapDom.window);
}

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
    headRef: "feat-x",
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

test("button renders the head -> base comparison with the base as the bold ref", () => {
  dom = createDom();
  installDomGlobals(dom);
  renderPicker(pickerPayload(0));

  const head = document.querySelector(".base-picker-head");
  const ref = document.querySelector(".base-picker-ref");
  expect(head?.textContent).toBe("feat-x");
  expect(ref?.textContent).toBe("origin/main");
  // The "Base:" prefix is gone; the head ref and an arrow icon are the read-only
  // context, the base ref is the primary token.
  expect(document.querySelector(".base-picker-prefix")).toBeNull();
  expect(document.querySelector(".base-picker-label svg")).toBeTruthy();
});

test("button title is the full untruncated comparison string", () => {
  dom = createDom();
  installDomGlobals(dom);
  renderPicker(pickerPayload(0));

  const button = document.querySelector<HTMLButtonElement>(".base-picker-button");
  // Comparing <head> against <base> (<reason>) +a -b, untruncated for hover.
  expect(button?.getAttribute("title")).toBe(
    "Comparing feat-x against origin/main (fork point) +1 -1",
  );
});

test("empty filter caps each group and flags the hidden tail count", () => {
  const groups = [
    { id: "suggested", label: "Suggested", rows: [{ ref: "origin/main", label: "origin/main" }] },
    { id: "remotes", label: "Remotes", rows: Array.from({ length: 2304 }, (_v, index) => ({
      ref: `origin/feature-${index}`,
      label: `origin/feature-${index}`,
    })) },
  ];
  const flat = buildFlatRows(groups, "", label);
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
  const flat = buildFlatRows(groups, "feature-1", label);
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
  const flat = buildFlatRows(groups, "zzz-nope", label);
  expect(flat[0]?.raw).toBe(true);
  expect(flat[0]?.row.ref).toBe("zzz-nope");
});

test("toCurrentOriginRelative strips an http origin so a restored page re-resolves it", () => {
  // The persisted HTML embeds the HTTP origin live at generation time; after a
  // restart the port changes and the page is served via the custom scheme, so
  // the picker must rebase the embedded absolute URL to a root-relative path.
  expect(
    toCurrentOriginRelative("http://127.0.0.1:51234/__cmux_diff_viewer_refs?repo=%2Ftmp%2Fr&token=abc"),
  ).toBe("/__cmux_diff_viewer_refs?repo=%2Ftmp%2Fr&token=abc");
  expect(
    toCurrentOriginRelative("cmux-diff-viewer://tok/__cmux_diff_viewer_branch?group=g&token=abc&base={ref}"),
  ).toBe("/__cmux_diff_viewer_branch?group=g&token=abc&base={ref}");
});

test("toCurrentOriginRelative preserves a literal {ref} placeholder (no URL parsing)", () => {
  // String strip, not new URL(...): URL parsing would percent-encode the braces.
  expect(toCurrentOriginRelative("http://127.0.0.1:9/x?base={ref}")).toBe("/x?base={ref}");
});

test("toCurrentOriginRelative leaves a data: URL and an already-relative path untouched", () => {
  const dataURL = "data:application/json,%7B%22groups%22%3A%5B%5D%7D";
  expect(toCurrentOriginRelative(dataURL)).toBe(dataURL);
  expect(toCurrentOriginRelative("/__cmux_diff_viewer_refs?token=abc")).toBe("/__cmux_diff_viewer_refs?token=abc");
});

test("selecting a ref navigates to a root-relative regenerate URL", async () => {
  dom = createDom();
  installDomGlobals(dom);
  const navigated: string[] = [];
  const picker: BranchPickerPayload = {
    repoRoot: "/tmp/mock",
    headRef: "feat-x",
    currentRef: "origin/main",
    currentReason: "fork point",
    confidence: "high",
    aheadBehind: { ahead: 1, behind: 1 },
    refsURL: "data:application/json," + encodeURIComponent(JSON.stringify({
      groups: [{ id: "suggested", label: "Suggested", rows: [{ ref: "develop", label: "develop" }] }],
    })),
    // Absolute HTTP origin as embedded in a freshly generated page.
    regenerateURLTemplate: "http://127.0.0.1:51234/__cmux_diff_viewer_branch?group=g&repo=%2Ftmp%2Fmock&token=abc&base={ref}",
  };
  const container = document.getElementById("root");
  root = createRoot(container!);
  flushSync(() => {
    root?.render(<BranchBasePicker label={label} onNavigate={(url) => navigated.push(url)} picker={picker} />);
  });

  document.querySelector<HTMLButtonElement>(".base-picker-button")?.click();
  await waitFor(() => rowCount() > 0);
  flushSync(() => {
    document.querySelector<HTMLElement>(".base-picker-row")?.dispatchEvent(
      new dom!.window.MouseEvent("mousedown", { bubbles: true, cancelable: true }),
    );
  });

  expect(navigated.length).toBe(1);
  // Origin stripped, token/repo/group survive in the query, ref substituted.
  expect(navigated[0]).toBe("/__cmux_diff_viewer_branch?group=g&repo=%2Ftmp%2Fmock&token=abc&base=develop");
});

function createDom(): JSDOM {
  return new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>", {
    pretendToBeVisual: true,
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
  g.getComputedStyle = nextDom.window.getComputedStyle.bind(nextDom.window);
  g.requestAnimationFrame = nextDom.window.requestAnimationFrame.bind(nextDom.window);
  g.cancelAnimationFrame = nextDom.window.cancelAnimationFrame.bind(nextDom.window);
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
