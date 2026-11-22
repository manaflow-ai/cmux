// The ui wrapper's contract in jsdom (plans/cmux-next/a11y-foundation.md): widgets leave Cmd and
// Ctrl chords (the app's shortcuts) alone; the listbox's keys and typeahead; a virtualized list
// keeps its active row in the DOM. Overlays (portals into the page container), keyboard paths and
// axe run in real engines: test/ui-a11y.test.ts.
import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { installDom, press, restoreDom, settle } from "./viewer-empty-dom";
import { ChoiceGroup } from "../src/ui/ChoiceGroup";
import { Combobox } from "../src/ui/Combobox";
import { DrillList } from "../src/ui/DrillList";
import { Listbox } from "../src/ui/Listbox";
import { UiProvider } from "../src/ui/UiProvider";
import { VirtualList } from "../src/ui/VirtualList";

// Base UI renders overlays with the shared react-dom (createPortal, flushSync), so these tests
// mount with the shared client too, not viewer-empty-dom's private copy.
let createRoot: typeof import("react-dom/client").createRoot;
let mounted: { unmount(): void; container: HTMLElement } | null = null;
beforeAll(async () => {
  installDom();
  ({ createRoot } = await import("react-dom/client"));
});
// React's passive effects run on the next tick; the DOM globals must outlive them, or the shared
// scheduler throws and stalls React for the files that run after this one.
afterAll(async () => {
  unmount();
  await new Promise((resolve) => setTimeout(resolve, 20));
  restoreDom();
});
afterEach(() => unmount());

function unmount(): void {
  if (!mounted) return;
  const current = mounted;
  mounted = null;
  act(() => current.unmount());
  current.container.remove();
}

async function render(node: ReactNode): Promise<HTMLElement> {
  unmount();
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  await act(async () => root.render(node));
  mounted = { unmount: () => root.unmount(), container };
  await settle();
  return container;
}

/** Whether a Cmd/Ctrl chord pressed on `target` reached the document unhandled. */
async function chordsPass(target: Element): Promise<string[]> {
  const reached: string[] = [];
  const listener = (event: KeyboardEvent) => {
    if (!event.defaultPrevented) reached.push(`${event.metaKey ? "Cmd" : "Ctrl"}-${event.key}`);
  };
  document.addEventListener("keydown", listener);
  await press(target, "s", { metaKey: true });
  await press(target, "k", { metaKey: true });
  await press(target, "w", { metaKey: true });
  await press(target, "Tab", { ctrlKey: true });
  await press(target, "Enter", { metaKey: true });
  document.removeEventListener("keydown", listener);
  return reached;
}

const ALL_CHORDS = ["Cmd-s", "Cmd-k", "Cmd-w", "Ctrl-Tab", "Cmd-Enter"];

describe("ui wrapper", () => {
  test("widgets leave Cmd and Ctrl chords to the app", async () => {
    const root = await render(
      <UiProvider container={null}>
        <DrillList<string>
          sections={[{ id: "level", items: ["a", "b"] }]}
          getKey={(item) => item}
          renderItem={(item) => item}
          highlight={0}
          onHighlight={() => {}}
          query=""
          onQueryChange={() => {}}
          onEnter={() => {}}
          onUp={() => {}}
          onChoose={() => {}}
          onCancel={() => {}}
          onActivate={() => {}}
          label="Path"
          listLabel="Folder"
          autoFocus={false}
        />
        <Listbox
          items={["x", "y"]}
          getKey={(item) => item}
          textValue={(item) => item}
          renderItem={(item) => item}
          label="Recent"
          onOpen={() => {}}
          autoFocus={false}
        />
        <Combobox suggestions={["#a"]} onQuery={() => {}} onSubmit={() => {}} onCancel={() => {}} label="URL" inline />
        <ChoiceGroup label="Source" onSubmit={() => {}} onCancel={() => {}}>
          <input type="radio" name="r" aria-label="one" defaultChecked />
        </ChoiceGroup>
      </UiProvider>,
    );
    expect(await chordsPass(root.querySelector('[role="combobox"][aria-label="Path"]')!)).toEqual(ALL_CHORDS);
    expect(await chordsPass(root.querySelector('[role="listbox"][aria-label="Recent"]')!)).toEqual(ALL_CHORDS);
    expect(await chordsPass(root.querySelector('input[aria-label="URL"]')!)).toEqual(ALL_CHORDS);
    expect(await chordsPass(root.querySelector('input[type="radio"]')!)).toEqual(ALL_CHORDS);
  });

  test("combobox rows show the suggestion text unless the caller renders them", async () => {
    // Every existing caller passes no renderItem: each row is the suggestion text, as before.
    const plain = await render(
      <Combobox
        suggestions={["#a", "#b"]}
        onQuery={() => {}}
        onSubmit={() => {}}
        onCancel={() => {}}
        label="URL"
        inline
      />,
    );
    expect([...plain.querySelectorAll('[role="option"]')].map((row) => row.innerHTML)).toEqual(["#a", "#b"]);
    // A caller that renders rows (a project name over its path) keeps the value it submits.
    const submitted: string[] = [];
    const rich = await render(
      <Combobox
        suggestions={["/src/cmux"]}
        renderItem={(value) => (
          <>
            <b>cmux</b>
            <i>{value}</i>
          </>
        )}
        onQuery={() => {}}
        onSubmit={(value) => submitted.push(value)}
        onCancel={() => {}}
        label="Folder"
        inline
      />,
    );
    const row = rich.querySelector<HTMLElement>('[role="option"]')!;
    expect(row.querySelector("b")?.textContent).toBe("cmux");
    expect(row.querySelector("i")?.textContent).toBe("/src/cmux");
    await act(async () => row.click());
    expect(submitted).toEqual(["/src/cmux"]);
  });

  test("the listbox moves with arrows, Home and End, and jumps by typed letters", async () => {
    const opened: string[] = [];
    const root = await render(
      <Listbox
        items={["alpha", "beta", "bravo", "charlie"]}
        getKey={(item) => item}
        textValue={(item) => item}
        renderItem={(item) => item}
        label="Recent"
        onOpen={(item) => opened.push(item)}
      />,
    );
    const list = root.querySelector('[role="listbox"]')!;
    const active = () => document.getElementById(list.getAttribute("aria-activedescendant")!)?.textContent;
    expect(document.activeElement).toBe(list);
    expect(active()).toBe("alpha");
    await press(list, "End");
    expect(active()).toBe("charlie");
    await press(list, "Home");
    await press(list, "b");
    expect(active()).toBe("beta");
    await press(list, "b");
    expect(active()).toBe("bravo");
    await press(list, "Enter");
    expect(opened).toEqual(["bravo"]);
  });

  test("a virtualized list renders its active row even far outside the viewport", async () => {
    const root = await render(
      <VirtualList
        count={5000}
        estimateSize={() => 28}
        activeIndex={4200}
        label="Rows"
        renderRow={(index, style) => (
          <div
            key={index}
            // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a listbox row, as VirtualList's callers render.
            role="option"
            aria-selected={index === 4200}
            aria-posinset={index + 1}
            aria-setsize={5000}
            style={style}
            data-index={index}
          >
            row {index}
          </div>
        )}
      />,
    );
    const rows = [...root.querySelectorAll('[role="option"]')];
    expect(rows.length).toBeLessThan(100);
    const active = root.querySelector('[data-index="4200"]');
    expect(active?.getAttribute("aria-posinset")).toBe("4201");
    expect(active?.getAttribute("aria-setsize")).toBe("5000");
  });
});
