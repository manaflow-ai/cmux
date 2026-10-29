import { afterEach, expect, test } from "bun:test";
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { Combobox } from "../src/ui/Combobox";
import { UiProvider } from "../src/ui/UiProvider";
import { Menu, MenuButton, MenuPopup } from "../src/ui/Menu";
import { Popover } from "../src/ui/Popover";
import { Select } from "../src/ui/Select";
import { comboboxDescription, selectDescription } from "../src/ui/popupDescriptors";
import type { PopupHost } from "../src/ui/popupHost";
import type { NativePopupEvent, NativePopupModel } from "../src/ui/nativePopup";

const menuModel = {
  side: "bottom" as const,
  align: "start" as const,
  width: 220,
  rows: [
    { id: "hold", kind: "action" as const, label: "Keep open", keepOpen: true },
    { id: "done", kind: "action" as const, label: "Done" },
  ],
};

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  const globals: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    HTMLInputElement: dom.window.HTMLInputElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const [key, value] of Object.entries(globals)) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
  return dom.window.document.getElementById("root")!;
}

afterEach(() => {
  if (root) act(() => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

function nativeHost() {
  const shown: NativePopupModel[] = [];
  const listeners = new Set<(event: NativePopupEvent) => void>();
  const host: PopupHost = {
    show: async () => ({ shown: false }),
    update() {},
    hide() {},
    owner: () => null,
    listen: () => () => {},
    native: {
      show: async (model) => {
        shown.push(model);
        return { shown: true };
      },
      update() {},
      hide() {},
      listen(listener) {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
    },
  };
  return { host, shown, listeners };
}

test("native combobox submits a picked action ID without a value payload", async () => {
  const container = installDom();
  const { host, shown, listeners } = nativeHost();
  const submitted: string[] = [];
  const highlighted: (string | undefined)[] = [];
  await act(async () => {
    root = createRoot(container);
    root.render(
      <UiProvider container={container} popupHost={host}>
        <Combobox
          inline
          label="Projects"
          suggestions={["alpha"]}
          onQuery={() => {}}
          onSubmit={(value) => submitted.push(value)}
          onHighlight={(value) => highlighted.push(value)}
          onCancel={() => {}}
          native={{ model: comboboxDescription({ suggestions: ["alpha"] }), anchor: () => container }}
        />
      </UiProvider>,
    );
  });
  expect(shown).toHaveLength(1);
  expect(container.querySelector('[role="option"]')).toBeNull();
  const model = shown[0]!;
  await act(async () => {
    for (const listener of listeners) {
      listener({ type: "highlight", popupId: model.id, revision: model.revision, id: model.rows[0]!.id });
      listener({ type: "pick", popupId: model.id, revision: model.revision, id: model.rows[0]!.id });
    }
  });
  expect(highlighted.at(-1)).toBe("alpha");
  expect(submitted).toEqual(["alpha"]);
});

test("native combobox presents once its own input anchor mounts", async () => {
  const container = installDom();
  const { host, shown } = nativeHost();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <UiProvider container={container} popupHost={host}>
        <Combobox
          inline
          label="Projects"
          suggestions={["alpha"]}
          onQuery={() => {}}
          onSubmit={() => {}}
          onCancel={() => {}}
          native={{ model: comboboxDescription({ suggestions: ["alpha"] }) }}
        />
      </UiProvider>,
    );
  });
  expect(shown).toHaveLength(1);
  expect(container.querySelector('[role="option"]')).toBeNull();
});

test.each([false, true])(
  "mounted native combobox preserves keepOpen=%s across picks and later interaction",
  async (keepOpen) => {
    const container = installDom();
    const { host, shown, listeners } = nativeHost();
    const submitted: string[] = [];
    const model = comboboxDescription({ suggestions: ["alpha"] });
    model.rows[0]!.keepOpen = keepOpen;
    await act(async () => {
      root = createRoot(container);
      root.render(
        <UiProvider container={container} popupHost={host}>
          <Combobox
            inline
            label="Projects"
            suggestions={["alpha"]}
            onQuery={() => {}}
            onSubmit={(value) => submitted.push(value)}
            onCancel={() => {}}
            native={{ model }}
          />
        </UiProvider>,
      );
    });
    const pick = async () => {
      const sent = shown.at(-1)!;
      await act(async () => {
        for (const listener of listeners)
          listener({ type: "pick", popupId: sent.id, revision: sent.revision, id: sent.rows[0]!.id });
      });
    };
    await pick();
    expect(submitted).toEqual(["alpha"]);
    expect(listeners.size).toBe(keepOpen ? 1 : 0);
    const field = container.querySelector<HTMLInputElement>("input")!;
    await act(async () => field.dispatchEvent(new dom!.window.MouseEvent("pointerdown", { bubbles: true })));
    expect(shown).toHaveLength(keepOpen ? 1 : 2);
    await pick();
    await act(async () =>
      field.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true })),
    );
    expect(shown).toHaveLength(keepOpen ? 1 : 3);
    expect(submitted).toEqual(["alpha", "alpha"]);
    expect(container.querySelector('[role="option"]')).toBeNull();
  },
);

test.each(["footer", "actions"] as const)(
  "native combobox reopens after a terminal auxiliary %s action",
  async (location) => {
    const container = installDom();
    const { host, shown, listeners } = nativeHost();
    const submitted: string[] = [];
    const picked: string[] = [];
    const model = comboboxDescription({ suggestions: ["alpha"] });
    const action = { id: "add-project", label: "Add project" };
    if (location === "footer") model.footer = [{ ...action, kind: "action", value: "add" }];
    else model.rows[0]!.actions = [action];
    await act(async () => {
      root = createRoot(container);
      root.render(
        <UiProvider container={container} popupHost={host}>
          <Combobox
            inline
            label="Projects"
            suggestions={["alpha"]}
            onQuery={() => {}}
            onSubmit={(value) => submitted.push(value)}
            onCancel={() => {}}
            native={{
              model,
              onEvent: (event) => {
                if (event.type === "pick") picked.push(event.id!);
              },
            }}
          />
        </UiProvider>,
      );
    });
    const first = shown[0]!;
    await act(async () => {
      for (const listener of listeners)
        listener({ type: "pick", popupId: first.id, revision: first.revision, id: action.id });
    });
    expect(picked).toEqual([action.id]);
    expect(submitted).toEqual([]);
    expect(listeners.size).toBe(0);
    const field = container.querySelector<HTMLInputElement>("input")!;
    await act(async () => field.dispatchEvent(new dom!.window.MouseEvent("pointerdown", { bubbles: true })));
    expect(shown).toHaveLength(2);
    const reopened = shown[1]!;
    await act(async () => {
      for (const listener of listeners)
        listener({ type: "pick", popupId: reopened.id, revision: reopened.revision, id: reopened.rows[0]!.id });
    });
    expect(submitted).toEqual(["alpha"]);
  },
);

test.each(["toggle", "slider", "textField"] as const)(
  "native combobox delegates secondary %s changes without replacing its query",
  async (kind) => {
    const container = installDom();
    const { host, shown, listeners } = nativeHost();
    const queries: string[] = [];
    const delegated: NativePopupEvent[] = [];
    const model = comboboxDescription({ suggestions: ["alpha"], query: "alpha" });
    model.rows.push({
      id: "secondary",
      kind,
      label: "Secondary control",
      checked: false,
      value: "0",
      minimum: 0,
      maximum: 100,
      step: 1,
    });
    await act(async () => {
      root = createRoot(container);
      root.render(
        <UiProvider container={container} popupHost={host}>
          <Combobox
            inline
            defaultValue="alpha"
            label="Projects"
            suggestions={["alpha"]}
            onQuery={(value) => queries.push(value)}
            onSubmit={() => {}}
            onCancel={() => {}}
            native={{ model, onEvent: (event) => delegated.push(event) }}
          />
        </UiProvider>,
      );
    });
    const sent = shown[0]!;
    const event: NativePopupEvent = {
      type: "change",
      popupId: sent.id,
      revision: sent.revision,
      id: "secondary",
      value: kind === "toggle" ? "true" : kind === "slider" ? "42" : "other text",
    };
    await act(async () => {
      for (const listener of listeners) listener(event);
    });
    expect(delegated).toEqual([event]);
    expect(queries).toEqual([]);
    expect(container.querySelector<HTMLInputElement>("input")!.value).toBe("alpha");
    expect(listeners.size).toBe(1);
  },
);

test.each(["search", "change"] as const)("native combobox accepts %s from its designated query field", async (type) => {
  const container = installDom();
  const { host, shown, listeners } = nativeHost();
  const queries: string[] = [];
  const model = comboboxDescription({ suggestions: ["alpha"], query: "alpha" });
  model.search!.id = "project-search";
  await act(async () => {
    root = createRoot(container);
    root.render(
      <UiProvider container={container} popupHost={host}>
        <Combobox
          inline
          defaultValue="alpha"
          label="Projects"
          suggestions={["alpha"]}
          onQuery={(value) => queries.push(value)}
          onSubmit={() => {}}
          onCancel={() => {}}
          native={{ model }}
        />
      </UiProvider>,
    );
  });
  const sent = shown[0]!;
  await act(async () => {
    for (const listener of listeners)
      listener({ type, popupId: sent.id, revision: sent.revision, id: "project-search", value: "beta" });
  });
  expect(queries).toEqual(["beta"]);
  expect(container.querySelector<HTMLInputElement>("input")!.value).toBe("beta");
});

test("native combobox search keeps the invoking field query in sync", async () => {
  const container = installDom();
  const { host, shown, listeners } = nativeHost();
  const queries: string[] = [];
  function Fixture() {
    const [query, setQuery] = useState("alpha");
    const suggestions = ["alpha", "beta"].filter((value) => value.includes(query));
    return (
      <Combobox
        label="Projects"
        defaultValue="alpha"
        suggestions={suggestions}
        onQuery={(value) => {
          queries.push(value);
          setQuery(value);
        }}
        onSubmit={() => {}}
        onCancel={() => {}}
        native={{ model: comboboxDescription({ suggestions, query }) }}
      />
    );
  }
  await act(async () => {
    root = createRoot(container);
    root.render(
      <UiProvider container={container} popupHost={host}>
        <Fixture />
      </UiProvider>,
    );
  });
  const model = shown[0]!;
  await act(async () => {
    for (const listener of listeners)
      listener({ type: "search", popupId: model.id, revision: model.revision, id: "query", value: "missing" });
  });
  expect(queries).toEqual(["missing"]);
  expect(listeners.size).toBe(0);
  expect(container.querySelector<HTMLInputElement>("input")!.value).toBe("missing");
});

test("native combobox ignores picks absent from its enabled suggestions", async () => {
  const container = installDom();
  const { host, shown, listeners } = nativeHost();
  const submitted: string[] = [];
  await act(async () => {
    root = createRoot(container);
    root.render(
      <UiProvider container={container} popupHost={host}>
        <Combobox
          inline
          label="Projects"
          suggestions={["alpha", "beta"]}
          isItemDisabled={(value) => value === "beta"}
          onQuery={() => {}}
          onSubmit={(value) => submitted.push(value)}
          onCancel={() => {}}
          native={{
            model: comboboxDescription({ suggestions: ["alpha", "beta"], disabled: (value) => value === "beta" }),
            anchor: () => container,
          }}
        />
      </UiProvider>,
    );
  });
  const model = shown[0]!;
  await act(async () => {
    for (const id of [
      "missing",
      ...model.rows
        .slice()
        .reverse()
        .map((row) => row.id),
    ])
      for (const listener of listeners) listener({ type: "pick", popupId: model.id, revision: model.revision, id });
  });
  expect(submitted).toEqual(["alpha"]);
});

test("controlled native menu closes on terminal picks and reopens without a dismiss event", async () => {
  const container = installDom();
  const { host, shown, listeners } = nativeHost();
  const changes: boolean[] = [];
  function Fixture() {
    const [open, setOpen] = useState(true);
    return (
      <>
        <button type="button" data-reopen onClick={() => setOpen(true)}>
          Reopen
        </button>
        <Menu
          open={open}
          onOpenChange={(next) => {
            changes.push(next);
            setOpen(next);
          }}
          native={{ model: menuModel }}
        >
          <MenuButton label="Actions">Actions</MenuButton>
          <MenuPopup>Page rows must not mount</MenuPopup>
        </Menu>
      </>
    );
  }
  await act(async () => {
    root = createRoot(container);
    root.render(
      <UiProvider container={container} popupHost={host}>
        <Fixture />
      </UiProvider>,
    );
  });
  expect(shown).toHaveLength(1);
  const model = shown[0]!;
  await act(async () => {
    for (const listener of listeners)
      listener({ type: "pick", popupId: model.id, revision: model.revision, id: "hold" });
  });
  expect(changes).toEqual([]);
  expect(listeners.size).toBe(1);
  await act(async () => {
    for (const listener of listeners)
      listener({ type: "pick", popupId: model.id, revision: model.revision, id: "done" });
  });
  expect(changes).toEqual([false]);
  expect(listeners.size).toBe(0);
  await act(async () => container.querySelector<HTMLButtonElement>("[data-reopen]")!.click());
  expect(shown).toHaveLength(2);
});

test.each(["escape", "outside"])("native popover preserves %s cancellation details", async (reason) => {
  const container = installDom();
  const { host, shown, listeners } = nativeHost();
  const changes: { open: boolean; escape: boolean | undefined }[] = [];
  await act(async () => {
    root = createRoot(container);
    root.render(
      <UiProvider container={container} popupHost={host}>
        <Popover
          open
          label="Details"
          anchor={container}
          native={{ model: menuModel, anchor: () => container }}
          onOpenChange={(open, details) => changes.push({ open, escape: details?.escape })}
        >
          Page rows must not mount
        </Popover>
      </UiProvider>,
    );
  });
  const model = shown[0]!;
  await act(async () => {
    for (const listener of listeners)
      listener({ type: "dismiss", popupId: model.id, revision: model.revision, reason });
  });
  expect(changes).toEqual([{ open: false, escape: reason === "escape" }]);
});

test("uncontrolled native menu closes on a pick and opens on the next trigger click", async () => {
  const container = installDom();
  const { host, shown, listeners } = nativeHost();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <UiProvider container={container} popupHost={host}>
        <Menu native={{ model: menuModel }}>
          <MenuButton label="Actions">Actions</MenuButton>
          <MenuPopup>Page rows must not mount</MenuPopup>
        </Menu>
      </UiProvider>,
    );
  });
  const button = container.querySelector<HTMLButtonElement>("button")!;
  await act(async () => button.click());
  expect(shown).toHaveLength(1);
  const model = shown[0]!;
  await act(async () => {
    for (const listener of listeners)
      listener({ type: "pick", popupId: model.id, revision: model.revision, id: "done" });
  });
  expect(button.getAttribute("aria-expanded")).toBe("false");
  await act(async () => button.click());
  expect(shown).toHaveLength(2);
});

test.each([false, true])("native select preserves closeOnPick=%s and enabled option dispatch", async (closeOnPick) => {
  const container = installDom();
  const { host, shown, listeners } = nativeHost();
  const changed: string[] = [];
  const options = [
    { value: "system", label: "System" },
    { value: "dark", label: "Dark" },
    { value: "disabled", label: "Disabled", disabled: true },
  ];
  await act(async () => {
    root = createRoot(container);
    root.render(
      <UiProvider container={container} popupHost={host}>
        <Select
          value="system"
          options={options}
          label="Theme"
          onChange={(value) => changed.push(value)}
          closeOnPick={closeOnPick}
          native={{ model: selectDescription({ options, value: "system" }) }}
        />
      </UiProvider>,
    );
  });
  const button = container.querySelector<HTMLButtonElement>("button")!;
  await act(async () => button.click());
  const model = shown[0]!;
  expect(model.rows.find((row) => row.value === "dark")?.keepOpen).toBe(!closeOnPick);
  await act(async () => {
    for (const id of ["disabled", "dark"].map((value) => model.rows.find((row) => row.value === value)!.id))
      for (const listener of listeners) listener({ type: "pick", popupId: model.id, revision: model.revision, id });
  });
  expect(changed).toEqual(["dark"]);
  expect(button.getAttribute("aria-expanded")).toBe(String(!closeOnPick));
});

test.each(["dark", ""])("native select resolves a distinct action ID to domain value %j", async (value) => {
  const container = installDom();
  const { host, shown, listeners } = nativeHost();
  const changed: string[] = [];
  await act(async () => {
    root = createRoot(container);
    root.render(
      <UiProvider container={container} popupHost={host}>
        <Select
          value="system"
          label="Theme"
          closeOnPick
          options={[{ value, label: value || "None" }]}
          onChange={(picked) => changed.push(picked)}
          native={{ model: { ...menuModel, rows: [{ id: "theme:choice", kind: "action", label: "Choice", value }] } }}
        />
      </UiProvider>,
    );
  });
  const button = container.querySelector<HTMLButtonElement>("button")!;
  await act(async () => button.click());
  const sent = shown[0]!;
  await act(async () => {
    for (const listener of listeners)
      listener({ type: "pick", popupId: sent.id, revision: sent.revision, id: "theme:choice" });
  });
  expect(changed).toEqual([value]);
  expect(button.getAttribute("aria-expanded")).toBe("false");
});

test.each(["children", "rail", "footer", "actions"] as const)(
  "native select preserves keep-open in %s",
  async (location) => {
    const container = installDom();
    const { host, shown, listeners } = nativeHost();
    const changed: string[] = [];
    const action = { id: "dark", kind: "action" as const, label: "Dark" };
    const model = {
      side: "bottom" as const,
      align: "start" as const,
      width: 220,
      rows:
        location === "children"
          ? [{ id: "themes", kind: "submenu" as const, label: "Themes", children: [action] }]
          : location === "actions"
            ? [{ id: "themes", kind: "text" as const, label: "Themes", actions: [action] }]
            : [],
      ...(location === "rail" || location === "footer" ? { [location]: [action] } : {}),
    };
    await act(async () => {
      root = createRoot(container);
      root.render(
        <UiProvider container={container} popupHost={host}>
          <Select
            value="system"
            label="Theme"
            options={[{ value: "dark", label: "Dark" }]}
            onChange={(value) => changed.push(value)}
            closeOnPick={false}
            native={{ model }}
          />
        </UiProvider>,
      );
    });
    const button = container.querySelector<HTMLButtonElement>("button")!;
    await act(async () => button.click());
    const sent = shown[0]!;
    const sentAction =
      location === "children"
        ? sent.rows[0]!.children![0]!
        : location === "actions"
          ? sent.rows[0]!.actions![0]!
          : sent[location]![0]!;
    expect(sentAction.keepOpen).toBe(true);
    await act(async () => {
      for (const listener of listeners)
        listener({ type: "pick", popupId: sent.id, revision: sent.revision, id: "dark" });
    });
    expect(changed).toEqual(["dark"]);
    expect(button.getAttribute("aria-expanded")).toBe("true");
  },
);
