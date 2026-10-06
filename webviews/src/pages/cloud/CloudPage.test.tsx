import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { createStrings } from "../shared/i18n";
import { CloudPage } from "./CloudPage";
import table from "./generated/strings.json";
import { MockCloudProvider, sampleMachines } from "./mockProvider";
import { machineTitle } from "./model";
import { AccountOps, ACTION_RUN, CloudOps } from "./ops";
import { CloudStore } from "./store";
import type { MachineLayout } from "./model";

const saved: Record<string, unknown> = {};
let dom: JSDOM;
let root: Root;

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>", {
    url: "http://localhost/cloud/",
  });
  for (const name of ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"])
    saved[name] = (globalThis as any)[name];
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).HTMLElement = dom.window.HTMLElement;
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  dom.window.HTMLElement.prototype.scrollIntoView = () => undefined;
  Object.assign(dom.window.HTMLElement.prototype, { attachEvent: () => undefined, detachEvent: () => undefined });
  root = createRoot(dom.window.document.getElementById("root")!);
});

afterEach(() => {
  act(() => root.unmount());
  for (const [name, value] of Object.entries(saved)) (globalThis as any)[name] = value;
});

async function render(provider: MockCloudProvider | null, { language = "en", layout = "rows" as MachineLayout } = {}) {
  let keys = 0;
  const store = new CloudStore(provider, { newKey: () => `k${++keys}`, layout });
  await act(async () => {
    root.render(<CloudPage store={store} strings={createStrings(table, [language])} />);
  });
  await act(async () => {
    await store.start();
  });
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  return store;
}

const $ = (selector: string) => dom.window.document.querySelector(selector) as HTMLElement | null;
const $$ = (selector: string) => [...dom.window.document.querySelectorAll(selector)] as HTMLElement[];

function key(target: HTMLElement, keyName: string, init: KeyboardEventInit = {}) {
  target.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: keyName, bubbles: true, ...init }));
}

/**
 * Sets a field's value and calls its React `onChange`. A dispatched `input` event does not reach
 * React's change plugin in this jsdom setup (the acpmux page tests use the same helper).
 */
function typeInto(input: HTMLInputElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
  setter.call(input, value);
  const key = Object.keys(input).find((name) => name.startsWith("__reactProps$"));
  const props = key ? (input as unknown as Record<string, { onChange?: (event: unknown) => void }>)[key] : undefined;
  props?.onChange?.({ target: input, currentTarget: input });
}

describe("CloudPage", () => {
  test("the machine list renders from the mock provider (rows layout)", async () => {
    await render(new MockCloudProvider());
    expect($(".cloud-title")?.textContent).toBe("Cloud");
    const rows = $$(".cloud-machine.layout-rows");
    expect(rows.length).toBe(sampleMachines().length);
    expect($$(".cloud-machine-title").map((title) => title.textContent)).toEqual(sampleMachines().map(machineTitle));
    expect($$(".cloud-status-dot").length).toBe(sampleMachines().length);
  });

  test("the cards layout renders the same machines", async () => {
    await render(new MockCloudProvider(), { layout: "cards" });
    expect($$(".cloud-machine.layout-cards").length).toBe(sampleMachines().length);
    expect($$(".cloud-machine.layout-rows").length).toBe(0);
  });

  test("Japanese strings", async () => {
    await render(new MockCloudProvider(), { language: "ja" });
    expect($(".cloud-title")?.textContent).toBe("クラウド");
  });

  test("signed out: shows sign in and calls no machine op", async () => {
    const provider = new MockCloudProvider({ signedIn: false });
    await render(provider);
    expect($(".cloud-signin-button")).not.toBeNull();
    expect($$(".cloud-machine").length).toBe(0);
    expect(provider.calls.filter((call) => call.op.startsWith("cmux.cloud.machine."))).toEqual([]);
    await act(async () => $(".cloud-signin-button")!.click());
    expect(provider.calls.some((call) => call.op === AccountOps.signIn)).toBe(false);
    expect(provider.calls.find((call) => call.op === ACTION_RUN)?.params).toMatchObject({
      action: AccountOps.signIn,
    });
    // The server does not serve sign-in yet: the page says so instead of failing.
    expect($(".cloud-signed-out .cloud-unavailable")?.textContent).toBe("Not available yet");
    expect($(".cloud-error")).toBeNull();
  });

  test("no host: the disconnected state", async () => {
    await render(null);
    expect($(".cloud-disconnected")).not.toBeNull();
  });

  test("the create sheet shows plan limits and double submit sends one create", async () => {
    const provider = new MockCloudProvider();
    await render(provider);
    await act(async () => $(".cloud-create-button")!.click());
    expect($(".cloud-create-sheet")).not.toBeNull();
    expect($(".cloud-plan-limit")?.textContent).toBe("3 of 5 machines on the go plan");
    await act(async () => typeInto($(".cloud-create-name") as HTMLInputElement, "sheet-box"));
    const submit = $(".cloud-create-submit")!;
    await act(async () => {
      submit.click();
      submit.click();
    });
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect(provider.calls.filter((call) => call.op === CloudOps.machineCreate)).toEqual([]);
    expect(
      provider.calls.filter(
        (call) => call.op === ACTION_RUN && (call.params as { action: string }).action === CloudOps.machineCreate,
      ).length,
    ).toBe(1);
  });

  test("the row delete button asks the native confirmation", async () => {
    const provider = new MockCloudProvider();
    await render(provider);
    await act(async () => $$(".cloud-machine")[0].click());
    await act(async () => $(".cloud-machine-delete")!.click());
    expect(provider.calls.some((call) => call.op === CloudOps.machineDelete)).toBe(false);
    expect(provider.calls.filter((call) => call.op === ACTION_RUN).at(-1)?.params).toMatchObject({
      action: CloudOps.machineDelete,
    });
  });

  test("plain Down and Return move the selection and open the detail", async () => {
    await render(new MockCloudProvider());
    const list = $(".cloud-machine-list")!;
    await act(async () => key(list, "ArrowDown"));
    expect($(".cloud-machine.selected .cloud-machine-title")?.textContent).toBe(machineTitle(sampleMachines()[0]));
    expect($(".cloud-detail")).not.toBeNull();
  });

  test("no keydown handler acts on Cmd or Ctrl chords", async () => {
    const provider = new MockCloudProvider();
    const store = await render(provider);
    const before = provider.calls.length;
    const snapshot = store.getSnapshot();
    const chords: KeyboardEventInit[] = [{ metaKey: true }, { ctrlKey: true }];
    const keysToTry = ["ArrowDown", "ArrowUp", "Enter", "Escape", "n", "Backspace", "Delete", " "];
    const targets = () => [
      $(".cloud-machine-list")!,
      ...$$(".cloud-machine"),
      ...$$("button"),
      dom.window.document.body,
    ];
    for (const chord of chords)
      for (const name of keysToTry) for (const target of targets()) await act(async () => key(target, name, chord));
    expect(provider.calls.length).toBe(before);
    expect(store.getSnapshot().selection).toBe(snapshot.selection);
    expect(store.getSnapshot().create).toBeUndefined();
    // The create sheet's fields ignore chords too.
    await act(async () => $(".cloud-create-button")!.click());
    for (const chord of chords)
      for (const name of ["Enter", "Escape"]) await act(async () => key($(".cloud-create-name")!, name, chord));
    expect(provider.calls.filter((call) => call.op === CloudOps.machineCreate)).toEqual([]);
    expect(store.getSnapshot().create).toBeDefined();
  });

  test("plain Return on an inline Pause button pauses and does not connect", async () => {
    const provider = new MockCloudProvider();
    await render(provider);
    const toggle = $(".cloud-machine-toggle")!;
    await act(async () => key(toggle, "Enter"));
    expect(provider.calls.some((call) => call.op === ACTION_RUN)).toBe(false);
  });

  test("Escape closes the create sheet", async () => {
    const store = await render(new MockCloudProvider());
    await act(async () => $(".cloud-create-button")!.click());
    await act(async () => key($(".cloud-create-name")!, "Escape"));
    expect(store.getSnapshot().create).toBeUndefined();
  });

  test("a watch event updates the visible list", async () => {
    const provider = new MockCloudProvider();
    await render(provider);
    await act(async () => {
      provider.emitUpsert({ id: "vm_live", status: "running", name: "live-box", revision: "1" });
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect($$(".cloud-machine-title").map((title) => title.textContent)).toContain("live-box");
  });

  test("the detail shows the record's size and the snapshots", async () => {
    const provider = new MockCloudProvider();
    await render(provider);
    await act(async () => $$(".cloud-machine")[0].click());
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect($(".cloud-detail")).not.toBeNull();
    expect($(".cloud-size-spec")?.textContent).toBe("4 CPU · 8 GB memory · 64 GB disk");
    expect($$(".cloud-detail .cloud-unavailable").length).toBe(0);
    expect($(".cloud-error")).toBeNull();
    expect($$(".cloud-snapshot").length).toBeGreaterThan(0);
    // Removed with the classic network model (contract C1): no network, firewall or publication UI.
    for (const gone of [".cloud-publication-access", ".cloud-domain-hostname", ".cloud-machine-fork", ".cloud-meter"])
      expect($(`.cloud-detail ${gone}`)).toBeNull();
  });

  test("restore on a snapshot creates a machine through the native action", async () => {
    const provider = new MockCloudProvider();
    await render(provider);
    await act(async () => $$(".cloud-machine")[0].click());
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    const before = $$(".cloud-machine").length;
    await act(async () => $(".cloud-snapshot-restore")!.click());
    expect(provider.calls.filter((call) => call.op === CloudOps.snapshotRestore)).toEqual([]);
    expect(provider.calls.filter((call) => call.op === ACTION_RUN).at(-1)?.params).toMatchObject({
      action: CloudOps.snapshotRestore,
    });
    expect($$(".cloud-machine").length).toBe(before + 1);
  });

  test("a port forward shows its 127.0.0.1 local port", async () => {
    const provider = new MockCloudProvider();
    await render(provider);
    await act(async () => $$(".cloud-machine")[0].click());
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    await act(async () => typeInto($(".cloud-forward-port") as HTMLInputElement, "3000"));
    await act(async () => $(".cloud-forward-add")!.click());
    const forward = provider.forwards[0];
    expect($(".cloud-forward-local")?.textContent).toBe(`127.0.0.1:${forward.localPort}`);
  });

  test("files: browse a folder and preview a small text file", async () => {
    const provider = new MockCloudProvider();
    await render(provider);
    await act(async () => $$(".cloud-machine")[0].click());
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    await act(async () => $(".cloud-files-browse")!.click());
    const names = $$(".cloud-file-name").map((node) => node.textContent);
    expect(names).toEqual(["notes.txt", "src", "big.bin", "latest"]);
    await act(async () => $$(".cloud-file-name")[0].click());
    expect($(".cloud-file-preview")?.textContent).toBe("hello cloud\n");
    expect(provider.calls.some((call) => call.op === CloudOps.fsRemove)).toBe(false);
  });

  test("files: a daemon without fs-v1 shows Not available yet and no rows", async () => {
    const provider = new MockCloudProvider();
    provider.fsMachines.delete(sampleMachines()[0].id);
    await render(provider);
    await act(async () => $$(".cloud-machine")[0].click());
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    await act(async () => $(".cloud-files-browse")!.click());
    expect($$(".cloud-file-name").length).toBe(0);
    expect($$(".cloud-detail .cloud-unavailable").map((node) => node.textContent)).toEqual(["Not available yet"]);
    expect($(".cloud-error")).toBeNull();
  });

  test("files: an upload shows running then done; a busy refusal shows Retry", async () => {
    const provider = new MockCloudProvider({ holdTransfers: true });
    await render(provider);
    await act(async () => $$(".cloud-machine")[0].click());
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    await act(async () => $(".cloud-files-browse")!.click());
    await act(async () => $(".cloud-files-upload")!.click());
    expect($$(".cloud-transfer-state").map((node) => node.textContent)).toEqual(["Copying…"]);
    await act(async () => {
      provider.finishTransfers();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect($$(".cloud-transfer-state").map((node) => node.textContent)).toEqual(["Copied"]);
    for (let i = 0; i < 4; i += 1) await act(async () => $(".cloud-file-download")!.click());
    await act(async () => $(".cloud-files-upload")!.click());
    expect($(".cloud-transfer-busy")?.textContent).toContain("Too many file transfers are running.");
    expect($(".cloud-error")).toBeNull();
    await act(async () => {
      provider.finishTransfers();
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    await act(async () => $(".cloud-transfer-retry")!.click());
    expect($(".cloud-transfer-busy")).toBeNull();
    expect($$(".cloud-transfer-state").filter((node) => node.textContent === "Copying…").length).toBe(1);
  });

  test("a typed refusal of the proxied browser tab shows the localized message once", async () => {
    const provider = new MockCloudProvider({ unsupported: [] });
    provider.tabError = "cmux.browser.engine_unavailable";
    await render(provider);
    await act(async () => $$(".cloud-machine")[0].click());
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    await act(async () => typeInto($(".cloud-forward-port") as HTMLInputElement, "3000"));
    await act(async () => $(".cloud-forward-add")!.click());
    await act(async () => $(".cloud-forward-browser")!.click());
    expect($(".cloud-browser-refused")?.textContent).toBe(
      "The browser cannot open this machine's page: it needs the Chromium engine with the machine's proxy. Nothing was opened.",
    );
    const tabCalls = provider.calls.filter(
      (call) => call.op === ACTION_RUN && (call.params as { action: string }).action === "browser.tab.open",
    );
    expect(tabCalls.length).toBe(1);
    expect((tabCalls[0].params as { args: { engine: string } }).args.engine).toBe("cef");
    expect($(".cloud-error")).toBeNull();
  });

  test("the classic migration banner shows once; Later hides it; Move them runs the native action", async () => {
    const provider = new MockCloudProvider();
    await render(provider);
    expect($$(".cloud-migration").length).toBe(1);
    expect($(".cloud-migration-title")?.textContent).toBe("Machines from cmux Cloud classic: 1");
    await act(async () => $(".cloud-migration-later")!.click());
    expect($(".cloud-migration")).toBeNull();
    expect(provider.calls.some((call) => call.op === ACTION_RUN)).toBe(false);

    act(() => root.unmount());
    root = createRoot(dom.window.document.getElementById("root")!);
    const second = new MockCloudProvider();
    await render(second);
    await act(async () => $(".cloud-migration-move")!.click());
    expect(second.calls.filter((call) => call.op === ACTION_RUN).at(-1)?.params).toMatchObject({
      action: CloudOps.migrationStart,
    });
    expect($(".cloud-migration")).toBeNull();
  });

  test("a classic machine shows the Classic badge and no change actions until upgraded", async () => {
    const provider = new MockCloudProvider();
    await render(provider);
    const classic = sampleMachines().find((machine) => machine.classic)!;
    const row = $$(".cloud-machine").find((node) => node.textContent?.includes(machineTitle(classic)))!;
    expect(row.querySelector(".cloud-classic-badge")?.textContent).toBe("Classic");
    expect(row.querySelector(".cloud-machine-toggle")).toBeNull();
    expect($$(".cloud-classic-badge").length).toBe(1);
    await act(async () => row.click());
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect($(".cloud-classic-note")?.textContent).toBe("Read-only until this machine is upgraded.");
    for (const action of [
      ".cloud-machine-delete",
      ".cloud-machine-connect",
      ".cloud-resize",
      ".cloud-idle",
      ".cloud-snapshot-restore",
      ".cloud-snapshot-create",
      ".cloud-files-browse",
      ".cloud-forward-port",
    ])
      expect($(`.cloud-detail ${action}`)).toBeNull();
    // Before the move there is no Upgrade either; plain Return on the row does not connect.
    expect($(".cloud-machine-upgrade")).toBeNull();
    await act(async () => key(row, "Enter"));
    expect(provider.calls.some((call) => call.op === ACTION_RUN)).toBe(false);
  });

  test("after the move, Upgrade runs cloud.machine.upgrade natively", async () => {
    const provider = new MockCloudProvider();
    const classic = sampleMachines().find((machine) => machine.classic)!;
    provider.account.migration = { state: "moved", classic_count: 1, imported: [classic.id] };
    await render(provider);
    const row = $$(".cloud-machine").find((node) => node.textContent?.includes(machineTitle(classic)))!;
    await act(async () => row.click());
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    await act(async () => $(".cloud-machine-upgrade")!.click());
    expect(provider.calls.filter((call) => call.op === ACTION_RUN).at(-1)?.params).toEqual({
      action: CloudOps.machineUpgrade,
      args: { machine: classic.id, idempotency_key: "k1" },
    });
    expect($$(".cloud-classic-badge").length).toBe(0);
  });

  test("the create sheet disables locked sizes with the reason", async () => {
    await render(new MockCloudProvider());
    await act(async () => $(".cloud-create-button")!.click());
    const sizes = $$(".cloud-size-choice input") as HTMLInputElement[];
    expect(sizes.map((input) => [input.value, input.disabled])).toEqual([
      ["4096", false],
      ["8192", false],
      ["16384", true],
      ["32768", true],
    ]);
    expect($$(".cloud-size-locked").map((node) => node.textContent)).toEqual(["Not in your plan", "Not in your plan"]);
  });

  test("a typed plan refusal shows a localized sentence, and See plans links the public plans page", async () => {
    const provider = new MockCloudProvider();
    provider.planRequired = true;
    await render(provider);
    await act(async () => $(".cloud-create-button")!.click());
    await act(async () => $(".cloud-create-submit")!.click());
    expect($(".cloud-create-sheet .cloud-plan-notice-text")?.textContent).toBe("Cloud machines need a paid plan.");
    expect($(".cloud-error")).toBeNull();
    // Billing is not built (checkout answers owner.unreachable): "See plans" is a link to the public
    // plans page, which the host opens outside the page on the person's click (PageNavigation).
    const link = $(".cloud-see-plans") as HTMLAnchorElement | null;
    expect(link?.tagName).toBe("A");
    expect(link?.getAttribute("href")).toBe("https://cmux.com/pricing");
    const runs = provider.calls.filter((call) => call.op === ACTION_RUN).length;
    await act(async () => link!.click());
    expect(provider.calls.filter((call) => call.op === ACTION_RUN).length).toBe(runs);
    expect(
      provider.calls.some((call) => (call.params as { action?: string })?.action === CloudOps.billingCheckout),
    ).toBe(false);
  });

  test("a quota refusal outside the sheet shows its numbers in Japanese too", async () => {
    const provider = new MockCloudProvider();
    provider.account.plan.max_active = 3;
    await render(provider, { language: "ja" });
    const paused = sampleMachines().find((machine) => machine.status === "paused")!;
    const row = $$(".cloud-machine").find((node) => node.textContent?.includes(machineTitle(paused)))!;
    await act(async () => (row.querySelector(".cloud-machine-toggle") as HTMLElement).click());
    expect($(".cloud-plan-notice-text")?.textContent).toBe("プランの上限に達しました（3 中 3 を使用中）。");
    // No plan id is known for a quota refusal: no See plans.
    expect($(".cloud-see-plans")).toBeNull();
  });

  test("no machine image configured: the create sheet and a restore say so in words", async () => {
    const provider = new MockCloudProvider();
    provider.noSnapshotConfigured = true;
    await render(provider);
    await act(async () => $(".cloud-create-button")!.click());
    await act(async () => $(".cloud-create-submit")!.click());
    const expected = "New machines are not available yet: no machine image is configured for this Cloud.";
    expect($(".cloud-create-blocked")?.textContent).toBe(expected);
    expect($(".cloud-error")).toBeNull();
    expect($(".cloud-see-plans")).toBeNull();
  });

  test("the backend's machine and size refusals show localized sentences, not the backend text", async () => {
    const english: Record<string, string> = {
      "cmux.cloud.not_running": "The machine is not running. Start it first.",
      "cmux.cloud.not_paused": "The machine is not paused, so it cannot start.",
      "cmux.cloud.machine_busy": "The machine is busy with another change. Try again in a moment.",
      "cmux.cloud.size_grow_only": "A machine can only grow. Choose a larger size.",
      "cmux.cloud.link_install_refused": "This app cannot open a link to a Cloud machine.",
    };
    const target = sampleMachines().find((machine) => machine.status === "running" && !machine.classic)!;
    for (const [code, sentence] of Object.entries(english)) {
      const provider = new MockCloudProvider();
      const store = await render(provider);
      provider.failNext = CloudOps.machinePause;
      provider.failCode = code;
      await act(async () => store.pause(target.id));
      expect($(".cloud-error-detail")?.textContent).toBe(sentence);
      expect(document.body.textContent).not.toContain("raw backend text");
    }
    const provider = new MockCloudProvider();
    const store = await render(provider, { language: "ja" });
    provider.failNext = CloudOps.machinePause;
    provider.failCode = "cmux.cloud.machine_busy";
    await act(async () => store.pause(target.id));
    expect($(".cloud-error-detail")?.textContent).toBe(
      "マシンは別の変更を処理中です。少し待ってからもう一度お試しください。",
    );
  });
});
