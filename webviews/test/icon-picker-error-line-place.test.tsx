// The Image and SVG sheets of the icon picker hold the place of their error line before an error
// shows (icon-picker/AssetTab.tsx, styles.css `.icon-asset-error`). The drop area over it fills the
// rest of the sheet: a line that came in only with the error made that area shorter, and the URL
// field and the hint moved up (gallery health, pages.icon-picker#error: layout shift 0.0060 on the
// click of Add). This file holds the rule for the line's element; the move itself is measured by
// the gallery's shift baseline for that state, in a browser.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { settleReact } from "./support/domTeardown";
import { JSDOM } from "jsdom";
import { act } from "react";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "customElements", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
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
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  await settleReact();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

test("the error line is in the sheet before an error, and an error and a new try keep the same line", async () => {
  const { createRoot } = await import("react-dom/client");
  const { AssetTab } = await import("../src/icon-picker/AssetTab");
  // Each download waits for the test to refuse it.
  const refusals: Array<(cause: Error) => void> = [];
  const sink = {
    put: () => new Promise<never>(() => {}),
    fromURL: () => new Promise<never>((_, refuse) => refusals.push(refuse)),
  };
  const root = createRoot(host);
  await act(async () =>
    root.render(<AssetTab kind="svg" sink={sink} strings={{ t: (key: string) => key } as never} onPicked={() => {}} />),
  );
  const line = host.querySelector(".icon-asset-error");
  expect(line?.getAttribute("role")).toBe("alert");
  expect(line?.textContent).toBe("");
  // The line is the sheet's last row, under the hint.
  expect(host.querySelector(".icon-asset")?.lastElementChild).toBe(line);

  const view = host.ownerDocument.defaultView!;
  const add = async () => {
    const url = host.querySelector<HTMLInputElement>('input[type="url"]')!;
    await act(async () => {
      Object.getOwnPropertyDescriptor(view.HTMLInputElement.prototype, "value")!.set!.call(
        url,
        "https://example.org/a.svg",
      );
      url.dispatchEvent(new view.Event("input", { bubbles: true }));
    });
    await act(async () => {
      host
        .querySelector("form.icon-asset-url")!
        .dispatchEvent(new view.Event("submit", { bubbles: true, cancelable: true }));
    });
  };
  await add();
  await act(async () => refusals.shift()!(new Error("refused")));
  expect(host.querySelector(".icon-asset-error")).toBe(line);
  expect(line?.textContent).toBe("iconPicker.error.failed");

  // A new try takes the text away while it runs; the line stays.
  await add();
  expect(host.querySelector(".icon-asset-error")).toBe(line);
  expect(line?.textContent).toBe("");
  await act(async () => root.unmount());
});
