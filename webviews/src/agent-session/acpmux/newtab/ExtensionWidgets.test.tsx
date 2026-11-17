import { afterAll, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { JSDOM } from "jsdom";
import { pageSwitch } from "../../../../test/support/pageSwitch";
import { MockAppPanelsClient } from "../../../apps/scene/panelsMock";
import { gridOrder, useNewTabExtensionWidgets } from "./ExtensionWidgets";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const globals = globalThis as Record<string, unknown>;
const replacements = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, replacements);
afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) globals[key] = value;
    else delete globals[key];
  }
});

/** The page host, with every call it gets in order. */
class Host extends MockAppPanelsClient {
  readonly calls: string[] = [];
  override async call<R>(op: string, params: unknown): Promise<R> {
    this.calls.push(op.replace("cmux.apps.panels.", ""));
    return super.call<R>(op, params);
  }
}

function WidgetRow({ host }: { host: Host }) {
  const widgets = useNewTabExtensionWidgets(host);
  return <span>{widgets.mounted.map((entry) => entry.panel.title).join(", ")}</span>;
}

test("the widget row follows the person's layout, then the rest in their default order", () => {
  const clock = "app:manaflow-ai/clock#cmux.newtab.widget/1";
  const prs = "app:samples/github-prs#cmux.newtab.widget/1";
  expect(gridOrder(["warmGreeting", "timer", clock, prs], [])).toEqual(["warmGreeting", "timer", clock, prs]);
  expect(gridOrder(["warmGreeting", "timer", clock, prs], [prs, "timer", clock])).toEqual([
    prs,
    "timer",
    clock,
    "warmGreeting",
  ]);
  // A layout entry nothing draws (an uninstalled app, a widget turned off) holds no place.
  expect(gridOrder(["quote", clock], ["app:gone/app#cmux.newtab.widget/1", clock])).toEqual([clock, "quote"]);
});

test("a switch away and back keeps a placed widget's mount and asks the host nothing", async () => {
  const host = new Host();
  host.layout = ["app:manaflow-ai/clock#cmux.newtab.widget/1"];
  const page = pageSwitch(dom.window);
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  try {
    await act(async () => {
      root.render(<WidgetRow host={host} />);
    });
    expect(container.textContent).toBe("Clock");
    expect(host.mounted).toBe(1);
    const before = host.calls.length;
    const whileHidden: (string | null)[] = [];
    await page.switchAwayAndBack({
      away: () => {
        whileHidden.push(container.textContent);
      },
    });
    // No list, no mount and no unmount: the page that comes back is the page that left.
    expect(host.calls.slice(before)).toEqual([]);
    expect(whileHidden).toEqual(["Clock"]);
    expect(container.textContent).toBe("Clock");
    expect(host.mounted).toBe(1);
  } finally {
    await act(async () => root.unmount());
    container.remove();
    page.dispose();
  }
  // Closing the page still ends the mount (and with it the app's timers).
  expect(host.mounted).toBe(0);
  expect(host.calls.at(-1)).toBe("unmount");
});

test("a page that loads hidden (a prewarmed spare) has its widgets before it shows, and showing it asks nothing", async () => {
  const host = new Host();
  host.layout = ["app:manaflow-ai/clock#cmux.newtab.widget/1"];
  const page = pageSwitch(dom.window);
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  try {
    await page.setVisibility("hidden");
    await act(async () => {
      root.render(<WidgetRow host={host} />);
    });
    expect(container.textContent).toBe("Clock");
    expect(host.mounted).toBe(1);
    const before = host.calls.length;
    await page.setVisibility("visible");
    await act(async () => {
      await Promise.resolve();
    });
    // The first frame the person sees after the page shows already has the widget.
    expect(host.calls.slice(before)).toEqual([]);
    expect(container.textContent).toBe("Clock");
  } finally {
    await act(async () => root.unmount());
    container.remove();
    page.dispose();
  }
  expect(host.mounted).toBe(0);
});
