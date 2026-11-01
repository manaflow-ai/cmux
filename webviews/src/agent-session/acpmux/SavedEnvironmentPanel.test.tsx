import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { UiProvider } from "../../ui/UiProvider";
import { SavedEnvironmentPanel } from "./SavedEnvironmentPanel";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
  });
  const requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  const cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  for (const key of [
    "window",
    "document",
    "navigator",
    "Node",
    "HTMLElement",
    "Element",
    "getComputedStyle",
    "requestAnimationFrame",
    "cancelAnimationFrame",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame,
    cancelAnimationFrame,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

async function renderPanel(
  container: HTMLElement,
  onBrowse: (request?: { deferPick?: boolean }) => Promise<string | undefined>,
) {
  await act(async () => {
    root = createRoot(container);
    root.render(
      <UiProvider container={container}>
        <SavedEnvironmentPanel
          environment={{
            id: "cmux-local",
            name: "cmux local",
            kind: "local",
            folder: "/Users/you/src/cmux",
            updatedAt: 1,
          }}
          folders={[{ id: "/Users/you/src/cmux", label: "cmux" }]}
          onBrowse={onBrowse}
          machines={[]}
          machineFolders={() => []}
          onSave={async () => undefined}
          onClose={() => {}}
        />
      </UiProvider>,
    );
  });
}

test("keeps a saved environment usable when folder browse rejects", async () => {
  const container = installDom();
  let rejectBrowse: ((error: Error) => void) | undefined;
  const browse = () =>
    new Promise<string | undefined>((_resolve, reject) => {
      rejectBrowse = reject;
    });
  await renderPanel(container, browse);

  await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-location-button")!.click());
  await act(async () => document.querySelector<HTMLElement>("[data-choose]")!.click());

  const save = container.querySelector<HTMLButtonElement>(".acpmux-env-submit")!;
  expect(save.disabled).toBe(true);
  expect(rejectBrowse).toBeTypeOf("function");
  await act(async () => rejectBrowse!(new Error("Folder access was denied.")));

  expect(container.querySelector('[role="alert"]')?.textContent).toContain("Folder access was denied.");
  expect([...container.querySelectorAll("button")].some((button) => button.textContent === "Retry")).toBe(true);
  expect(container.querySelector(".acpmux-env-panel")).toBeTruthy();
  expect(container.querySelector<HTMLInputElement>(".acpmux-env-input")?.value).toBe("cmux local");

  await act(async () =>
    document.querySelector<HTMLButtonElement>(".acpmux-env-footer button.acpmux-env-button")!.click(),
  );
  expect(save.disabled).toBe(true);
  await act(async () => rejectBrowse!(new Error("Folder access was denied again.")));
  expect(container.querySelector('[role="alert"]')?.textContent).toContain("Folder access was denied again.");

  await act(async () =>
    [...container.querySelectorAll<HTMLButtonElement>(".acpmux-env-tab")]
      .find((button) => button.textContent === "SSH")
      ?.click(),
  );
  expect([...container.querySelectorAll("button")].some((button) => button.textContent === "Retry")).toBe(false);
});

test("releases the browse guard after switching environment kind", async () => {
  const container = installDom();
  const settleBrowse: ((folder: string | undefined) => void)[] = [];
  const rejectBrowse: ((error: Error) => void)[] = [];
  let calls = 0;
  const browse = () =>
    new Promise<string | undefined>((resolve, reject) => {
      calls += 1;
      settleBrowse.push(resolve);
      rejectBrowse.push(reject);
    });
  await renderPanel(container, browse);

  const chooseFolder = async () => {
    await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-location-button")!.click());
    await act(async () => document.querySelector<HTMLElement>("[data-choose]")!.click());
  };
  await chooseFolder();
  expect(calls).toBe(1);
  await act(async () =>
    [...container.querySelectorAll<HTMLButtonElement>(".acpmux-env-tab")]
      .find((button) => button.textContent === "SSH")
      ?.click(),
  );
  await act(async () =>
    [...container.querySelectorAll<HTMLButtonElement>(".acpmux-env-tab")]
      .find((button) => button.textContent === "Local")
      ?.click(),
  );
  await chooseFolder();
  expect(calls).toBe(1);
  await act(async () => settleBrowse[0]!("/Users/you/src/stale"));
  expect(container.querySelector<HTMLInputElement>(".acpmux-env-input")?.value).toBe("cmux local");
  expect(container.querySelector('[data-placeholder=""]')).toBeTruthy();
  await chooseFolder();
  expect(calls).toBe(2);
  await act(async () => rejectBrowse[1]!(new Error("Folder access was denied.")));
  expect(container.querySelector('[role="alert"]')?.textContent).toContain("Folder access was denied.");
});

test("back from Add Project cannot apply its deferred browse to the environment", async () => {
  const container = installDom();
  let resolveBrowse!: (folder: string) => void;
  await renderPanel(container, (request) => {
    expect(request?.deferPick).toBe(true);
    return new Promise((resolve) => {
      resolveBrowse = resolve;
    });
  });
  await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-location-button")!.click());
  const pick = async (label: string) => {
    const item = [...document.querySelectorAll<HTMLElement>('[role="option"]')].find((node) =>
      node.textContent?.includes(label),
    );
    expect(item).toBeTruthy();
    await act(async () => item!.click());
  };
  await pick("Add project");
  await pick("This Mac");
  await pick("Local folder");
  expect(document.querySelector('[data-add-project-step="source"]')).toBeTruthy();
  await act(async () => document.querySelector<HTMLButtonElement>(".acpmux-add-project-heading button")!.click());
  await pick("This Mac");
  await pick("Local folder");
  // The native chooser is still pending: the second attempt must stay in Add Project,
  // rather than interpreting the busy guard as cancellation and closing the dialog.
  expect(document.querySelector('[data-add-project-step="source"]')).toBeTruthy();
  await act(async () => resolveBrowse("/Users/you/src/stale"));
  expect(container.querySelector('.acpmux-env-select[title="/Users/you/src/cmux"]')).toBeTruthy();
});
