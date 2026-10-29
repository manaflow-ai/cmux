import { afterEach, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  currentPopupEvent,
  inspectNativePopups,
  nativePresentationProblem,
  type NativePresentation,
  type PopupGuardOptions,
  type PopupIdentity,
  type SurfaceSemantics,
} from "./helpers/nativePopupGuard";

const windows: JSDOM[] = [];
afterEach(() => {
  for (const dom of windows.splice(0)) dom.window.close();
});

function fixture(html: string) {
  const dom = new JSDOM(`<!doctype html><body>${html}</body>`, { pretendToBeVisual: true });
  windows.push(dom);
  const document = dom.window.document;
  const element = (id: string) => {
    const found = document.getElementById(id);
    if (!found) throw new Error(`Fixture missing ${id}`);
    return found;
  };
  const inspect = (options: Partial<PopupGuardOptions> = {}) =>
    inspectNativePopups(document, { adapter: "native", ...options });
  return { document, element, inspect };
}

describe("native popup DOM observations", () => {
  test.each([
    ["roomy ordinary menu", '<div id="popup" role="menu" style="position:absolute;top:20px">Choose</div>'],
    ["custom raised surface", '<div id="popup" class="invented-frame" style="position:fixed;z-index:9">Choose</div>'],
    ["floating listbox", '<ul id="popup" role="listbox" style="position:absolute"><li>One</li></ul>'],
    [
      "anchored nonmodal dialog",
      '<button aria-expanded="true" aria-controls="popup">Open</button><dialog id="popup" open>Choose</dialog>',
    ],
    ["Summary floating frame", '<aside id="popup" data-placement="popover">Summary contents</aside>'],
    ["HTML popover", '<div id="popup" popover>Choose</div>'],
  ])("rejects %s without relying on shared CSS names", (_name, html) => {
    const f = fixture(html);
    expect(f.inspect().map((violation) => violation.element?.id)).toEqual(["popup"]);
  });

  test("rejects an unlabelled custom portal", () => {
    const f = fixture('<div id="portal">Custom picker</div>');
    expect(f.inspect({ portalRoots: new Set([f.element("portal")]) })[0]?.element).toBe(f.element("portal"));
  });

  test("rejects hidden scraping DOM even when WebPopupHost acknowledged the same popup", () => {
    const f = fixture(
      '<div style="opacity:0;pointer-events:none" data-escaped><div id="popup" role="menu">Model</div></div>',
    );
    const expected = identity();
    const result = f.inspect({ presentations: [{ expected, actual: shown(expected) }] });
    expect(result.map((violation) => violation.kind)).toEqual(["dom-popup"]);
  });

  test("native failure cannot silently fall back to web or disappear", () => {
    const f = fixture('<div id="popup" role="menu">Fallback</div>');
    const expected = identity();
    expect(
      f
        .inspect({
          presentations: [{ expected, actual: { ...shown(expected), state: "rejected" } }],
        })
        .map((violation) => violation.kind),
    ).toEqual(["native-presentation", "dom-popup"]);
    f.element("popup").remove();
    expect(f.inspect({ presentations: [{ expected, actual: null }] })[0]?.kind).toBe("native-presentation");
  });

  test("finds popup DOM in an open shadow root", () => {
    const f = fixture('<div id="host"></div>');
    const shadow = f.element("host").attachShadow({ mode: "open" });
    shadow.innerHTML = '<div role="menu">Shadow menu</div>';
    expect(f.inspect()[0]?.element).toBe(shadow.firstElementChild ?? undefined);
  });

  test("compatibility policy observes pending, shown and rejected escape mirrors", () => {
    const f = fixture(
      '<div id="shell" data-escaped style="position:fixed;z-index:9;opacity:0;pointer-events:none"><div id="popup" role="menu">Model</div></div>',
    );
    const expected = identity();
    const semantics = new Map<Element, SurfaceSemantics>();
    const observe = (state: "pending" | "shown" | "rejected") => {
      semantics.set(f.element("popup"), {
        kind: "escape-mirror",
        shell: f.element("shell"),
        expected,
        presentation: { ...shown(expected), state },
      });
      return f.inspect({ lifecycle: "escape-compatible", semantics });
    };
    expect(observe("pending")).toEqual([]);
    expect(observe("shown")).toEqual([]);
    // A declaration is not a blanket exemption under the migration's native-only policy.
    expect(f.inspect({ semantics }).some((item) => item.kind === "dom-popup")).toBe(true);
    f.element("shell").removeAttribute("data-escaped");
    f.element("shell").setAttribute("style", "position:fixed;z-index:9");
    expect(observe("rejected")).toEqual([]);
    expect(observe("shown").some((item) => item.kind === "dom-popup")).toBe(true);
    semantics.set(f.element("popup"), {
      kind: "escape-mirror",
      shell: f.element("shell"),
      expected,
      presentation: { ...shown(expected), state: "rejected", owner: {} },
    });
    expect(
      f.inspect({ lifecycle: "escape-compatible", semantics }).some((item) => item.kind === "native-presentation"),
    ).toBe(true);
  });

  test("inspects supplied closed roots, including nested roots, once and within scope", () => {
    const f = fixture('<div id="host"></div><div id="unrelated"></div>');
    const closed = f.element("host").attachShadow({ mode: "closed" });
    closed.innerHTML = '<div id="nested"></div>';
    const nestedHost = closed.querySelector<HTMLElement>("#nested");
    if (!nestedHost) throw new Error("Fixture missing nested closed-shadow host");
    const inner = nestedHost.attachShadow({ mode: "closed" });
    inner.innerHTML = '<div role="menu">Closed menu</div>';
    const unrelated = f.element("unrelated").attachShadow({ mode: "closed" });
    unrelated.innerHTML = '<div role="menu">Unrelated</div>';
    expect(f.element("host").shadowRoot).toBeNull();
    const scoped = f.inspect({ shadowRoots: new Set([inner, closed]) });
    expect(scoped).toHaveLength(1);
    expect(scoped[0]?.element === inner.firstElementChild).toBe(true);
    const hostScoped = inspectNativePopups(f.element("host"), {
      adapter: "native",
      shadowRoots: new Set([unrelated, inner, closed]),
    });
    expect(hostScoped).toHaveLength(1);
    expect(hostScoped[0]?.element === inner.firstElementChild).toBe(true);
    const open = f.element("unrelated").ownerDocument.createElement("span");
    closed.append(open);
    const openRoot = open.attachShadow({ mode: "open" });
    openRoot.innerHTML = '<div role="menu">Open nested</div>';
    expect(f.inspect({ shadowRoots: new Set([closed, inner, openRoot]) })).toHaveLength(2);
  });

  test("reports one frame for a popup with raised internal decoration", () => {
    const f = fixture('<div id="popup" role="menu"><span style="position:absolute;z-index:1">Decoration</span></div>');
    expect(f.inspect()).toHaveLength(1);
  });

  test("persistent Summary and Session Info roots remain web; their menus are still checked", () => {
    const f = fixture(
      '<aside id="summary" style="position:absolute;z-index:4">Summary</aside><aside id="info" style="position:fixed;z-index:5"><div id="nested" role="menu">More</div></aside><ul role="listbox"><li>Inline list</li></ul>',
    );
    const semantics = new Map<Element, SurfaceSemantics>();
    semantics.set(f.element("summary"), { kind: "persistent" });
    semantics.set(f.element("info"), { kind: "persistent" });
    expect(f.inspect({ semantics }).map((violation) => violation.element?.id)).toEqual(["nested"]);
  });

  test("true modal membership exempts the modal frame, never nested popup menus", () => {
    const f = fixture(
      '<dialog id="modal" open aria-modal="true" style="position:fixed"><div id="nested" role="menu">More</div></dialog>',
    );
    // JSDOM has no window top layer. This injects the platform observation, not an aria flag.
    const isModal = (element: Element) => element === f.element("modal");
    const semantics = new Map<Element, SurfaceSemantics>([[f.element("modal"), { kind: "modal" }]]);
    expect(f.inspect({ semantics, isModal }).map((violation) => violation.element?.id)).toEqual(["nested"]);
  });

  test("aria-modal or a declaration alone cannot excuse a floating nonmodal dialog", () => {
    const f = fixture('<div id="popup" role="dialog" aria-modal="true" style="position:fixed">Form</div>');
    const semantics = new Map<Element, SurfaceSemantics>([[f.element("popup"), { kind: "modal" }]]);
    expect(f.inspect({ semantics, isModal: () => false }).map((violation) => violation.kind)).toEqual([
      "invalid-modal",
      "dom-popup",
    ]);
  });

  test("native web content needs a matching presentation and does not exempt child popovers", () => {
    const f = fixture(
      '<div id="content" style="position:fixed;z-index:1"><div id="nested" role="menu">More</div></div>',
    );
    const expected = identity();
    const semantics = new Map<Element, SurfaceSemantics>();
    semantics.set(f.element("content"), {
      kind: "native-content",
      expected,
      presentation: shown(expected),
    });
    expect(f.inspect({ semantics }).map((violation) => violation.element?.id)).toEqual(["nested"]);
    semantics.set(f.element("content"), { kind: "native-content", expected, presentation: null });
    expect(f.inspect({ semantics }).map((violation) => violation.kind)).toEqual(["native-presentation", "dom-popup"]);
  });

  test("gallery/test DOM adapter is explicit and requires a reason", () => {
    const f = fixture('<div id="popup" role="menu" data-gallery="true">Choose</div>');
    expect(f.inspect()).toHaveLength(1);
    expect(f.inspect({ adapter: { kind: "test-dom", reason: "Gallery renders a reference menu" } })).toEqual([]);
    expect(() => f.inspect({ adapter: { kind: "test-dom", reason: " " } })).toThrow("requires a reason");
  });
});

function identity(): PopupIdentity {
  return { popupId: "model-picker", revision: 3, owner: {} };
}

function shown(expected: PopupIdentity): NativePresentation {
  return { ...expected, host: "WebPopupHost", state: "shown" };
}

describe("native popup receipt and event identity", () => {
  test("accepts only the current popup revision and mounted consumer", () => {
    const current = identity();
    expect(currentPopupEvent(current, current, current.owner)).toBe(true);
    expect(currentPopupEvent({ ...current, revision: 2 }, current, current.owner)).toBe(false);
    expect(currentPopupEvent({ ...current, popupId: "mode-picker" }, current, current.owner)).toBe(false);
    expect(currentPopupEvent(current, current, {})).toBe(false);
    expect(currentPopupEvent(current, null, current.owner)).toBe(false);
  });

  test("a closed/reopened popup does not accept the previous opening's event", () => {
    const previous = identity();
    const reopened = { ...previous, revision: previous.revision + 1 };
    expect(currentPopupEvent(previous, reopened, reopened.owner)).toBe(false);
    expect(currentPopupEvent(reopened, reopened, reopened.owner)).toBe(true);
    const remounted = { ...reopened, owner: {} };
    expect(currentPopupEvent(reopened, remounted, previous.owner)).toBe(false);
  });

  test("rejects invalid revision identities", () => {
    for (const revision of [-1, 1.5, Number.NaN, Number.POSITIVE_INFINITY]) {
      const current = { ...identity(), revision };
      expect(currentPopupEvent(current, current, current.owner)).toBe(false);
    }
    const empty = { ...identity(), popupId: "" };
    expect(currentPopupEvent(empty, empty, empty.owner)).toBe(false);
  });

  test("native-first WebContextMenu is still a different host, and stale acknowledgements fail", () => {
    const expected = identity();
    expect(nativePresentationProblem(expected, shown(expected))).toBeNull();
    expect(nativePresentationProblem(expected, { ...shown(expected), host: "WebContextMenu" })).toContain("different");
    expect(nativePresentationProblem(expected, { ...shown(expected), owner: {} })).toContain("stale");
    expect(nativePresentationProblem(expected, { ...shown(expected), revision: 2 })).toContain("stale");
    expect(nativePresentationProblem(expected, { ...shown(expected), state: "dismissed" })).toContain("dismissed");
  });
});
