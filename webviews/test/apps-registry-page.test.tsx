// The App Store page's community registry states (custom-panes-DESIGN.md 6.4), rendered from the
// real store and the registry-shaped mock: Community with Get, Submit for Review with the publisher
// prefilled, My Submissions with each status and the reviewer's reason, and the Review tab only for
// a reviewer, whose Reject needs a reason and whose Approve calls decide.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import type { Strings } from "../src/pages/shared/i18n";
import { AppsPage } from "../src/pages/apps/AppsPage";
import { MockAppsProvider, sampleApps, sampleLocalApp, sampleRegistry } from "../src/pages/apps/mockProvider";
import { AppsStore } from "../src/pages/apps/store";
import { pageError } from "../src/pages/shared/pageClient";
import { AppsOps, RegistryOps, type RegistryMe } from "../src/pages/apps/types";
import { UiProvider } from "../src/ui/UiProvider";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "Event", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let host: HTMLElement;
let root: Root | undefined;
let store: AppsStore | undefined;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Event: window.Event,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  store?.stop();
  store = undefined;
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const strings: Strings = {
  language: "en",
  t: (key) => key,
  format: (key, ...args) => [key, ...args].join(" "),
};

const person: RegistryMe = { signedIn: true, user: "user_sample", reviewer: false, publishers: ["sample-studio"] };

/** Lets the store's chained page calls answer (the mock answers on the next microtasks). */
async function settle(): Promise<void> {
  await act(async () => {
    for (let turn = 0; turn < 10; turn += 1) await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

async function mount(hash: string, me?: RegistryMe) {
  const data = { ...sampleApps(), registry: sampleRegistry(me) };
  data.installed["local/notes-pane"] = sampleLocalApp();
  const provider = new MockAppsProvider(data);
  store = new AppsStore(provider, hash);
  const current = store;
  act(() => {
    root = createRoot(host);
    root.render(
      <UiProvider container={host}>
        <AppsPage store={current} strings={strings} />
      </UiProvider>,
    );
  });
  await settle();
  return { provider, page: host };
}

const tabs = (page: HTMLElement) => [...page.querySelectorAll('[role="tab"]')].map((tab) => tab.textContent);

function setValue(element: HTMLInputElement | HTMLTextAreaElement, value: string): void {
  const proto = element instanceof window.HTMLTextAreaElement ? window.HTMLTextAreaElement : window.HTMLInputElement;
  Object.getOwnPropertyDescriptor(proto.prototype, "value")!.set!.call(element, value);
  element.dispatchEvent(new window.Event("input", { bubbles: true }));
}

test("Discover's Community lists approved apps, and Get downloads then installs", async () => {
  const { provider, page } = await mount("#/discover?layout=grid", person);
  const cards = [...page.querySelectorAll<HTMLElement>(".apps-community-card")];
  expect(cards.map((card) => card.dataset.registryApp)).toEqual([
    "sample-studio/workspace-board",
    "pixel-works/focus-timer",
  ]);
  const get = cards[0]!.querySelector<HTMLButtonElement>(".apps-button.primary")!;
  expect(get.textContent).toBe("store.registry.get");
  provider.calls.length = 0;

  await act(async () => get.click());
  await settle();

  const order = provider.calls.map((call) => call.op);
  expect(order.indexOf(RegistryOps.get)).toBeGreaterThanOrEqual(0);
  expect(order.indexOf(AppsOps.install)).toBeGreaterThan(order.indexOf(RegistryOps.get));
  // Now in the catalog and installed: the card shows that state instead of Get.
  const board = page.querySelector<HTMLElement>('[data-registry-app="sample-studio/workspace-board"]')!;
  expect(board.textContent).toContain("store.badge.installed");
  expect(board.textContent).not.toContain("store.registry.get");
});

test("a listing already installed at an older version offers its newer version", async () => {
  const data = { ...sampleApps(), registry: sampleRegistry(person) };
  const bundle = data.registry.bundles["sample-studio/workspace-board"]!;
  data.details[bundle.id] = { ...bundle, latest_version: "0.1.0", installed: true };
  data.installed[bundle.id] = { ...sampleLocalApp(), id: bundle.id, name: bundle.name, source: "user" };
  const provider = new MockAppsProvider(data);
  store = new AppsStore(provider, "#/discover?layout=grid");
  const current = store;
  act(() => {
    root = createRoot(host);
    root.render(
      <UiProvider container={host}>
        <AppsPage store={current} strings={strings} />
      </UiProvider>,
    );
  });
  await settle();
  const board = host.querySelector<HTMLElement>('[data-registry-app="sample-studio/workspace-board"]')!;
  expect(board.textContent).toContain("store.badge.installed");
  expect(board.querySelector(".apps-button.primary")?.textContent).toBe("store.registry.getVersion 0.2.0");
});

test("Submit for Review is on local apps only and prefills the first publisher", async () => {
  const { provider, page } = await mount("#/installed", person);
  const toggles = [...page.querySelectorAll<HTMLButtonElement>(".apps-submit-toggle")];
  expect(toggles).toHaveLength(1);
  expect(toggles[0]!.closest(".apps-installed-row")?.textContent).toContain("local/notes-pane");

  act(() => toggles[0]!.click());
  const publisher = page.querySelector<HTMLInputElement>('.apps-submit input[name="publisher"]')!;
  expect(publisher.value).toBe("sample-studio");
  const notes = page.querySelector<HTMLTextAreaElement>('.apps-submit textarea[name="notes"]')!;
  act(() => setValue(notes, "First version"));

  await act(async () => page.querySelector<HTMLButtonElement>('.apps-submit button[type="submit"]')!.click());
  await settle();

  expect(provider.calls.find((call) => call.op === RegistryOps.submit)?.params).toEqual({
    app: "local/notes-pane",
    publisher: "sample-studio",
    notes: "First version",
  });
  expect(page.querySelector(".apps-submit")).toBeNull();
});

test("a declined submit sheet shows no error banner and keeps the form", async () => {
  const { provider, page } = await mount("#/installed", person);
  act(() => page.querySelector<HTMLButtonElement>(".apps-submit-toggle")!.click());
  provider.failNext(RegistryOps.submit, pageError("cmux.page.cancelled", "Declined"));

  await act(async () => page.querySelector<HTMLButtonElement>('.apps-submit button[type="submit"]')!.click());
  await settle();

  expect(page.querySelector(".apps-error")).toBeNull();
  expect(page.querySelector(".apps-submit")).not.toBeNull();
});

test("signed out, Submit for Review shows the sign-in hint instead of the form", async () => {
  const { page } = await mount("#/installed", { signedIn: false });
  act(() => page.querySelector<HTMLButtonElement>(".apps-submit-toggle")!.click());
  expect(page.querySelector(".apps-submit")).toBeNull();
  expect(page.querySelector(".apps-submit-hint")?.textContent).toBe("store.registry.signedOut");
  expect(page.querySelector(".apps-submissions")).toBeNull();
});

test("My Submissions shows each status and the reviewer's reason", async () => {
  const { page } = await mount("#/installed", person);
  const rows = [...page.querySelectorAll<HTMLElement>(".apps-submission")];
  expect(rows.map((row) => row.dataset.status)).toEqual(["pending", "approved", "rejected"]);
  expect(rows[0]!.textContent).toContain("store.registry.status.pending");
  expect(rows[2]!.textContent).toContain("store.registry.status.rejected");
  expect(rows[2]!.querySelector(".apps-submission-reason")?.textContent).toContain("never explains it in the UI");
  expect(rows[1]!.querySelector(".apps-submission-reason")).toBeNull();
});

test("the Review tab is hidden for a person who is not a reviewer, even at #/review", async () => {
  const { page } = await mount("#/review", person);
  expect(tabs(page)).toEqual(["store.tab.discover", "store.tab.installed"]);
  expect(page.querySelector(".apps-review")).toBeNull();
  expect(page.querySelector('[role="tab"][aria-selected="true"]')?.textContent).toBe("store.tab.discover");
});

test("a reviewer sees the queue, the manifest, files and a file as text", async () => {
  const { page } = await mount("#/review");
  expect(tabs(page)).toEqual(["store.tab.discover", "store.tab.installed", "store.tab.review"]);
  act(() => page.querySelector<HTMLButtonElement>(".apps-review .apps-row-open")!.click());
  const detail = page.querySelector<HTMLElement>('[data-review="sub_9"]')!;
  expect(detail.querySelector(".apps-detail-name")?.textContent).toBe("Clock Pane");
  expect(detail.textContent).toContain("workspace:read");
  expect(detail.textContent).toContain("Shows the clock beside the active workspace name.");
  const files = [...detail.querySelectorAll<HTMLButtonElement>(".apps-review-file")];
  expect(files.map((file) => file.querySelector("code")?.textContent)).toEqual([
    "cmux-app.json",
    "web/index.html",
    "web/clock.js",
    "web/icon.png",
  ]);

  await act(async () => files[2]!.click());
  await settle();
  expect(page.querySelector(".apps-review-code")?.textContent).toContain("toLocaleTimeString");

  await act(async () => page.querySelectorAll<HTMLButtonElement>(".apps-review-file")[3]!.click());
  await settle();
  expect(page.querySelector(".apps-review-code")).toBeNull();
  expect(page.querySelector(".apps-review-viewer")?.textContent).toBe("store.registry.binary 6");
});

test("Reject needs a reason; Approve calls decide", async () => {
  const { provider, page } = await mount("#/review");
  act(() => page.querySelector<HTMLButtonElement>(".apps-review .apps-row-open")!.click());
  const buttons = () => [...page.querySelectorAll<HTMLButtonElement>(".apps-review .apps-submit-actions button")];
  const reject = buttons().find((button) => button.textContent === "store.registry.reject")!;

  await act(async () => reject.click());
  await settle();
  expect(page.querySelector(".apps-review-form-error")?.textContent).toBe("store.registry.reasonLength");
  expect(provider.calls.some((call) => call.op === RegistryOps.reviewDecide)).toBe(false);

  const approve = buttons().find((button) => button.textContent === "store.registry.approve")!;
  await act(async () => approve.click());
  await settle();
  expect(provider.calls.find((call) => call.op === RegistryOps.reviewDecide)?.params).toEqual({
    id: "sub_9",
    decision: "approve",
    reason: "",
  });
  expect(page.querySelector(".apps-review .apps-empty")?.textContent).toBe("store.registry.selectSubmission");
  expect(page.querySelector(".apps-review .apps-review-note")?.textContent).toBe("store.registry.queueEmpty");
});
