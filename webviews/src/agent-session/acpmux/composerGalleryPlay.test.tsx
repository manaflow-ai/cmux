import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { resolveTarget, type PlayContext, type PlayTarget } from "../../gallery/play";
import { installTooltips } from "../../ui/titleTooltips";
import composerGallery from "./composer.gallery";

const dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
const doc = dom.window.document;
const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "getComputedStyle",
  "localStorage",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
];
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, {
  window: dom.window,
  document: doc,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  localStorage: { getItem: () => null, setItem: () => {} },
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => {
  dom.window.close();
  for (const [key, existed, value] of saved) {
    if (existed) scope[key] = value;
    else delete scope[key];
  }
});

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { ComposerPickers } = await import("./ComposerPickers");
const { currentLanguage, setPaneLanguage } = await import("./i18n");

// Run the actual fixture against the shipped picker and tooltip behavior. Real pointer input
// resolves a target again after hovering it; title tooltips may have changed its attributes.
const find = (target: PlayTarget) => {
  const element = resolveTarget(doc, target);
  if (!element) throw new Error(`Missing play target: ${JSON.stringify(target)}`);
  return element as HTMLElement;
};
const unused = async () => {
  throw new Error("Unexpected play action");
};
const ctx: PlayContext = {
  document: doc,
  find,
  click: async (target) => {
    const element = find(target);
    await act(async () => {
      element.dispatchEvent(new dom.window.MouseEvent("pointerover", { bubbles: true }));
    });
    await act(async () => find(target).click());
  },
  press: async (key) => {
    await act(async () => {
      doc.activeElement?.dispatchEvent(
        new dom.window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }),
      );
    });
  },
  waitFor: async (condition) => {
    await act(async () => {});
    expect(Boolean(condition())).toBe(true);
  },
  hover: async (target) => {
    await act(async () => {
      find(target).dispatchEvent(new dom.window.MouseEvent("pointerover", { bubbles: true }));
    });
  },
  focus: unused,
  scroll: unused,
  selectText: unused,
  type: async (text, target) => {
    const input = (target ? find(target) : doc.activeElement) as HTMLInputElement;
    await act(async () => {
      input.focus();
      Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(input, text);
      input.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
    });
  },
  pointer: { down: unused, move: unused, up: unused },
};

for (const language of ["en", "ja"]) {
  test(`Starred gallery play survives tooltips and replay in ${language}`, async () => {
    const priorLanguage = currentLanguage();
    const variant = composerGallery.variants["model-menu-starred"]!;
    const root = createRoot(doc.getElementById("root")!);
    const uninstall = installTooltips(doc);
    try {
      setPaneLanguage(language);
      await act(async () => {
        root.render(
          createElement(ComposerPickers, {
            snapshot: variant.snapshot,
            onModel: () => {},
            onMode: () => {},
            onEffort: () => {},
            onHarness: () => {},
          }),
        );
      });
      for (let replay = 0; replay < 2; replay += 1) {
        await variant.play!(ctx);
        const rows = [...doc.querySelectorAll(".acpmux-mp-models .acpmux-mp-row")];
        expect(rows.map((row) => row.querySelector(".acpmux-menu-label")?.textContent)).toEqual(["Sonnet 5.5"]);
        expect(doc.querySelector('.acpmux-mp-favorite[aria-pressed="true"]')).not.toBeNull();
        await ctx.press("Escape");
        expect(doc.querySelector(".acpmux-mp")).toBeNull();
      }
    } finally {
      uninstall();
      await act(async () => root.unmount());
      setPaneLanguage(priorLanguage);
    }
  });
}

test("keyboard gallery play checks that the highlighted model actually changes", async () => {
  const variant = composerGallery.variants["model-menu-keyboard"]!;
  const root = createRoot(doc.getElementById("root")!);
  const focus = dom.window.HTMLInputElement.prototype.focus;
  // JSDOM focuses visibility:hidden inputs; browsers reject them. Match that browser rule
  // so opening an anchored menu must wait for it to become visible before focusing search.
  dom.window.HTMLInputElement.prototype.focus = function (options) {
    if (dom.window.getComputedStyle(this).visibility === "hidden") return;
    focus.call(this, options);
  };
  try {
    await act(async () => {
      root.render(
        createElement(ComposerPickers, {
          snapshot: variant.snapshot,
          onModel: () => {},
          onMode: () => {},
          onEffort: () => {},
          onHarness: () => {},
        }),
      );
    });
    // A dropped key must fail the fixture, even though opening already highlights a model.
    await expect(variant.play!({ ...ctx, press: async () => {} })).rejects.toThrow();
    await ctx.press("Escape");
    await variant.play!(ctx);
  } finally {
    dom.window.HTMLInputElement.prototype.focus = focus;
    await act(async () => root.unmount());
  }
});

test("Codex reasoning gallery play selects a service tier and closes the menu", async () => {
  const variant = composerGallery.variants["reasoning-codex"]!;
  const root = createRoot(doc.getElementById("root")!);
  try {
    await act(async () => {
      root.render(
        createElement(ComposerPickers, {
          snapshot: variant.snapshot,
          onModel: () => {},
          onMode: () => {},
          onEffort: () => {},
          onHarness: () => {},
        }),
      );
    });
    await variant.play!(ctx);
    expect(doc.querySelector(".acpmux-effort-menu")).toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
});
