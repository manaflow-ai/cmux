import { expect, test } from "bun:test";
import { openFork } from "./openFork";

function host(opens = true) {
  let selected: string | undefined = "parent";
  const opened: [string, string][] = [];
  const focused: string[] = [];
  const persisted: (string | undefined)[] = [];
  return {
    opened,
    focused,
    persisted,
    selected: () => selected,
    open: async (id: string, placement: string) => {
      opened.push([id, placement]);
      return opens;
    },
    select: async (id: string) => {
      selected = id;
      return id;
    },
    persist: async (id?: string) => {
      persisted.push(id);
    },
    focus: () => {
      focused.push(selected!);
    },
  };
}

test("an unspecified destination delegates to the native default and keeps the parent selected", async () => {
  const h = host();
  expect(await openFork("fork", "parent", undefined, h)).toBe("fork");
  expect(h.opened).toEqual([["fork", "default"]]);
  expect(h.selected()).toBe("parent");
});

for (const placement of ["right", "left", "up", "down", "tab", "workspace", "window"]) {
  test(`explicit ${placement} is preserved`, async () => {
    const h = host();
    await openFork("fork", "parent", placement, h);
    expect(h.opened).toEqual([["fork", placement]]);
  });
}

test("refused host opening selects, persists and focuses the fork", async () => {
  const h = host(false);
  await openFork("fork", "parent", undefined, h);
  expect(h.persisted).toEqual(["fork"]);
  expect(h.focused).toEqual(["fork"]);
});

test("a refused host opening never replaces a chat selected while forking", async () => {
  const h = host(false);
  await h.select("other");
  await openFork("fork", "parent", undefined, h);
  expect(h.selected()).toBe("other");
  expect(h.focused).toEqual([]);
});

test("a later navigation while persistence finishes keeps its focus", async () => {
  const h = host(false);
  h.persist = async () => {
    await h.select("other");
  };
  await openFork("fork", "parent", undefined, h);
  expect(h.focused).toEqual([]);
});

test("a failed fork opens and focuses nothing", async () => {
  const h = host();
  expect(await openFork(undefined, "parent", undefined, h)).toBeUndefined();
  expect(h.opened).toEqual([]);
  expect(h.focused).toEqual([]);
});
