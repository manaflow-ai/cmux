import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { teardownDom } from "../../../test/support/domTeardown";
import { cloudPickerReason, cloudPickerState, readCloudServed, useCloudServed, type CloudServed } from "./cloudServed";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, readonly [key: string, had: boolean, value: unknown]>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
    pretendToBeVisual: true,
  });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, [key, key in scope, scope[key]]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  const window = dom?.window;
  dom = undefined;
  await teardownDom(saved.values(), { ...(window ? { window } : {}), scope });
  saved.clear();
});

const runnableFamilies = ["claude", "codex"];
const reply = <T extends Record<string, unknown>>(families: T) => ({ runnableFamilies, families });

test("the host distinguishes launch support from missing or unknown credentials", () => {
  const served = readCloudServed(reply({ claude: false, gemini: true, codex: "yes" }));
  expect(served).toEqual(reply({ claude: false }));
  expect(cloudPickerState(served, "claude-profile")).toBe("disconnected");
  expect(cloudPickerState(served, "codex")).toBeUndefined();
  expect(cloudPickerState(served, "gemini")).toBe("unsupported");
  expect(cloudPickerState(readCloudServed(reply({ codex: true })), "codex:work")).toBe("ready");
  expect(readCloudServed(reply({}))).toBeUndefined();
  expect(readCloudServed({ families: { claude: true } })).toBeUndefined();
  expect(readCloudServed(undefined)).toBeUndefined();
  expect(readCloudServed({ other: 1 })).toBeUndefined();
});

test("only recognized reasons for locked families are read", () => {
  const families = { claude: false, codex: true };
  const served = readCloudServed({
    ...reply(families),
    reasons: { claude: "off", codex: "signedOut", gemini: "none" },
  });
  expect(served).toEqual({ ...reply(families), reasons: { claude: "off" } });
  expect(cloudPickerReason(served, "claude:work")).toBe("picker.cloud.connectionOff");
  const cloudOff = readCloudServed({ ...reply(families), reasons: { claude: "cloudOff" } });
  expect(cloudOff?.reasons?.claude).toBe("cloudOff");
  expect(cloudPickerReason(cloudOff, "claude")).toBe("picker.cloud.connectionOff");
  expect(readCloudServed({ ...reply(families), reasons: { claude: "unknown" } })).toEqual(reply(families));
  expect(cloudPickerReason(readCloudServed(reply(families)), "claude")).toBe("composer.envNotConnected");
});

test("the read runs while Cloud is picked, again on refresh (the picker opens), and drops a stale answer", async () => {
  const container = installDom();
  const calls: string[] = [];
  const answers: ((value: unknown) => void)[] = [];
  const call = (method: string) => {
    calls.push(method);
    return new Promise<unknown>((resolve) => answers.push(resolve));
  };
  let seen: { served?: CloudServed; refresh(): void } | undefined;
  function Probe({ active }: { active: boolean }) {
    seen = useCloudServed(call, active);
    return null;
  }
  root = createRoot(container);
  // Not picked: no read, no state.
  await act(async () => root!.render(<Probe active={false} />));
  expect(calls).toEqual([]);
  expect(seen?.served).toBeUndefined();
  await act(async () => root!.render(<Probe active />));
  expect(calls).toEqual(["cloud.setup.state"]);
  await act(async () => answers[0]!(reply({ claude: false, codex: true })));
  expect(seen?.served).toEqual(reply({ claude: false, codex: true }));
  // The picker opens (a connection may have been added in Settings): read again. A tab switch reads nothing.
  await act(async () => void dom!.window.dispatchEvent(new dom!.window.Event("focus")));
  expect(calls.length).toBe(1);
  await act(async () => seen!.refresh());
  expect(calls.length).toBe(2);
  // A newer read wins over an older answer that arrives late.
  await act(async () => seen!.refresh());
  await act(async () => answers[2]!(reply({ claude: true, codex: true })));
  await act(async () => answers[1]!(reply({ claude: false, codex: false })));
  expect(seen?.served).toEqual(reply({ claude: true, codex: true }));
  // Cloud no longer picked: the state goes, and a late answer is dropped, and refresh reads nothing.
  await act(async () => seen!.refresh());
  await act(async () => root!.render(<Probe active={false} />));
  await act(async () => answers[3]!(reply({ claude: false })));
  expect(seen?.served).toBeUndefined();
  const before = calls.length;
  await act(async () => seen!.refresh());
  expect(calls.length).toBe(before);
});

test("a refused read shows no state", async () => {
  const container = installDom();
  let seen: { served?: CloudServed } | undefined;
  function Probe() {
    seen = useCloudServed(() => Promise.reject(new Error("unsupported")), true);
    return null;
  }
  root = createRoot(container);
  await act(async () => root!.render(<Probe />));
  expect(seen?.served).toBeUndefined();
});

test("Connect targets the selected machine and drops a superseded return", async () => {
  const container = installDom();
  let watcher: (() => void) | undefined;
  let key = true;
  let machine = "vm_b";
  const readMachine = () => machine;
  const watchKey = (run: () => void) => {
    watcher = run;
    return () => {
      watcher = undefined;
    };
  };
  const isKey = () => key;
  const reads: ReturnType<typeof Promise.withResolvers<unknown>>[] = [];
  const connected: unknown[] = [];
  const call = (method: string, params?: Record<string, unknown>) => {
    if (method === "cloud.connect") {
      connected.push(params);
      return Promise.resolve({});
    }
    const read = Promise.withResolvers<unknown>();
    reads.push(read);
    return read.promise;
  };
  let seen!: ReturnType<typeof useCloudServed>;
  function Probe() {
    seen = useCloudServed(call, true, { watchKey, isKey, readMachine });
    return null;
  }
  root = createRoot(container);
  await act(async () => root!.render(<Probe />));
  expect(watcher).toBeUndefined();
  expect(reads).toHaveLength(1);
  let selected = "";
  await act(async () =>
    seen.openSettings("claude", () => {
      selected = "claude";
    }),
  );
  expect(connected).toEqual([{ family: "claude", machine: "vm_b" }]);
  key = false;
  watcher?.();
  expect(reads).toHaveLength(1);
  key = true;
  watcher?.();
  expect(watcher).toBeUndefined();
  expect(reads).toHaveLength(2);
  machine = "vm_c";
  await act(async () =>
    seen.openSettings("codex", () => {
      selected = "codex";
    }),
  );
  expect(connected[1]).toEqual({ family: "codex", machine: "vm_c" });
  await act(async () => reads[1]!.resolve(reply({ claude: true })));
  expect(selected).toBe("");
  watcher?.();
  await act(async () => reads[2]!.resolve(reply({ codex: true })));
  expect(selected).toBe("codex");
  expect(watcher).toBeUndefined();
  expect(reads).toHaveLength(3);
});

test("reopening the picker keeps the pending return selection on the latest read", async () => {
  const container = installDom();
  let watcher: (() => void) | undefined;
  const watchKey = (run: () => void) => {
    watcher = run;
    return () => {
      watcher = undefined;
    };
  };
  const isKey = () => true;
  const reads: ReturnType<typeof Promise.withResolvers<unknown>>[] = [];
  const call = (method: string) => {
    if (method === "cloud.connect") return Promise.resolve({});
    const read = Promise.withResolvers<unknown>();
    reads.push(read);
    return read.promise;
  };
  let seen!: ReturnType<typeof useCloudServed>;
  function Probe() {
    seen = useCloudServed(call, true, { watchKey, isKey });
    return null;
  }
  root = createRoot(container);
  await act(async () => root!.render(<Probe />));
  let selected = 0;
  await act(async () => seen.openSettings("claude", () => selected++));
  await act(async () => watcher?.());
  await act(async () => seen.refresh());
  await act(async () => reads[1]!.resolve(reply({ claude: false })));
  expect(selected).toBe(0);
  await act(async () => reads[2]!.resolve(reply({ claude: true })));
  expect(selected).toBe(1);
  await act(async () => seen.refresh());
  await act(async () => reads[3]!.resolve(reply({ claude: true })));
  expect(selected).toBe(1);
});

test("the host's endpoint support is exact and overrides family prefixes", () => {
  const served = readCloudServed({
    runnableFamilies: ["claude"],
    families: { claude: true },
    servedHarnesses: ["deepseek"],
    pendingHarnesses: ["other"],
    unavailableEndpointHarnesses: ["claude-local"],
  });
  expect(cloudPickerState(served, "deepseek")).toBe("ready");
  expect(cloudPickerState(served, "other")).toBe("pending");
  expect(cloudPickerState(served, "deepseek-copy")).toBe("unsupported");
  expect(cloudPickerState(served, "claude-local")).toBe("unsupported");
  expect(cloudPickerState(served, "claude")).toBe("ready");
});
