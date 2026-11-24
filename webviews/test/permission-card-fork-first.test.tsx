// l10n-allow-file: test fixture tool titles and option names, not shipped UI.
// "Fork first" on a risky step (RFD 0163 row 25, acpmux fork_risky.rs): a permission request that
// carries a `forkOffer` (only with `cloud.autoCloud` on, on a Cloud machine, for a force push, a
// hard reset, a migration and the like) shows the reason and a Fork first button; the button sends
// the one-time allow through `onForkFirst`, never the plain answer. An ask with no offer, or a pane
// that cannot carry it out, shows neither.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxPermission } from "../src/agent-session/acpmux/model";
import { settleReact } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const globalKeys = ["window", "document", "navigator", "HTMLElement", "Node", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = globalKeys.map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
});
const domClasses = Object.getOwnPropertyNames(dom.window).filter(
  (key) => /^(HTML|SVG|CSS|Document|Event|KeyboardEvent)/.test(key) && !(key in globals),
);
for (const key of domClasses) globals[key] = (dom.window as unknown as Record<string, unknown>)[key];
afterAll(async () => {
  await settleReact();
  for (const [key, had, value] of saved) {
    if (had) globals[key] = value;
    else delete globals[key];
  }
  for (const key of domClasses) delete globals[key];
  dom.window.close();
});

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { PermissionCard } = await import("../src/agent-session/acpmux/PermissionCard");
const { permissionFromMessage } = await import("../src/agent-session/acpmux/direct/permissions");

const request = (forkOffer?: unknown) => ({
  sessionId: "s1",
  permissionId: "p1",
  ...(forkOffer ? { forkOffer } : {}),
  request: {
    toolCall: {
      kind: "execute",
      title: "git push --force",
      rawInput: { command: "git push --force" },
    },
    options: [
      { optionId: "yes", name: "Yes", kind: "allow_once" },
      { optionId: "no", name: "No", kind: "reject_once" },
    ],
  },
});
const offer = {
  machine: "vm_abc",
  reason: "git push rewrites or deletes a remote branch",
  clientKey: "risky-p1",
};

test("the request's forkOffer reaches the permission, and only a whole one", () => {
  expect(permissionFromMessage(request(offer), "s1")?.forkOffer).toEqual({
    machine: "vm_abc",
    reason: "git push rewrites or deletes a remote branch",
  });
  expect(permissionFromMessage(request(), "s1")?.forkOffer).toBeUndefined();
  expect(permissionFromMessage(request({ machine: "vm_abc" }), "s1")?.forkOffer).toBeUndefined();
});

async function render(permission: AcpmuxPermission, onForkFirst?: (id: string) => unknown) {
  const root = document.getElementById("root")!;
  const answered: string[] = [];
  const reactRoot = createRoot(root);
  await act(async () => {
    reactRoot.render(
      <PermissionCard
        permission={permission}
        onAnswer={(id) => {
          answered.push(id);
          return Promise.resolve();
        }}
        onForkFirst={onForkFirst}
      />,
    );
  });
  return { root, answered, unmount: () => act(() => reactRoot.unmount()) };
}

const forkButton = (root: HTMLElement) => root.querySelector<HTMLButtonElement>(".acpmux-permission-fork-first");

test("Fork first shows the reason and sends the one-time allow through onForkFirst", async () => {
  const forked: string[] = [];
  const { root, answered, unmount } = await render(permissionFromMessage(request(offer), "s1")!, (id) => {
    forked.push(id);
    return Promise.resolve();
  });
  expect(root.querySelector(".acpmux-permission-fork-offer")?.textContent).toContain(
    "git push rewrites or deletes a remote branch",
  );
  const button = forkButton(root);
  expect(button?.textContent).toContain("Fork first");
  await act(async () => button!.click());
  expect(forked).toEqual(["yes"]);
  expect(answered).toEqual([]);
  await unmount();
});

test("no offer, or no way to carry it out, shows no Fork first", async () => {
  for (const [permission, handler] of [
    [permissionFromMessage(request(), "s1")!, () => Promise.resolve()],
    [permissionFromMessage(request(offer), "s1")!, undefined],
  ] as const) {
    const { root, unmount } = await render(permission, handler);
    expect(forkButton(root)).toBeNull();
    expect(root.querySelector(".acpmux-permission-fork-offer")).toBeNull();
    await unmount();
  }
});
