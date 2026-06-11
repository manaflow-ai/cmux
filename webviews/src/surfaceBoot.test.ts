import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { bootSurface } from "./surfaceBoot";

let dom: JSDOM;
function makeRoot(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>");
  return dom.window.document.getElementById("root")!;
}
function fakeStorage() {
  const map = new Map<string, string>();
  return {
    getItem: (k: string) => map.get(k) ?? null,
    setItem: (k: string, v: string) => void map.set(k, v),
    removeItem: (k: string) => void map.delete(k),
  };
}

test("a failed import auto-reloads exactly once, then renders a visible error (never blank)", async () => {
  const root = makeRoot();
  const storage = fakeStorage();
  let reloads = 0;
  // First attempt: import fails -> should reload once, not render error yet.
  await bootSurface({
    root,
    kind: "editor",
    load: () => Promise.reject(new Error("chunk 404")),
    reload: () => { reloads += 1; },
    storage,
  });
  expect(reloads).toBe(1);
  expect(root.querySelector("[data-cmux-surface-boot-error]")).toBeNull();

  // Second attempt (post-reload, flag already set): still fails -> visible error, no further reload.
  await bootSurface({
    root,
    kind: "editor",
    load: () => Promise.reject(new Error("chunk 404")),
    reload: () => { reloads += 1; },
    storage,
  });
  expect(reloads).toBe(1);
  const err = root.querySelector("[data-cmux-surface-boot-error]");
  expect(err).not.toBeNull();
  expect(root.textContent).toContain("editor view failed to load");
  expect(root.querySelector("button")).not.toBeNull();
});

test("a mount throw is treated the same as an import failure", async () => {
  const root = makeRoot();
  const storage = fakeStorage();
  storage.setItem("cmuxSurfaceBootReloaded", "1"); // simulate post-reload attempt
  let reloads = 0;
  await bootSurface({
    root,
    kind: "diff",
    load: () => Promise.resolve(() => { throw new Error("mount boom"); }),
    reload: () => { reloads += 1; },
    storage,
  });
  expect(reloads).toBe(0);
  expect(root.querySelector("[data-cmux-surface-boot-error]")).not.toBeNull();
});

test("a clean mount renders nothing extra and clears the reload guard", async () => {
  const root = makeRoot();
  const storage = fakeStorage();
  storage.setItem("cmuxSurfaceBootReloaded", "1");
  let mounted = false;
  await bootSurface({
    root,
    kind: "editor",
    load: () => Promise.resolve((r) => { r.append(r.ownerDocument.createElement("span")); mounted = true; }),
    reload: () => { throw new Error("should not reload on success"); },
    storage,
  });
  expect(mounted).toBe(true);
  expect(root.querySelector("[data-cmux-surface-boot-error]")).toBeNull();
  expect(storage.getItem("cmuxSurfaceBootReloaded")).toBeNull();
});

afterEach(() => { dom?.window?.close?.(); });
