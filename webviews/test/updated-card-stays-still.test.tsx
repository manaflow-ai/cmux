// l10n-allow-file: test fixtures.
// Lawrence 2026-11-07, on the sidebar's Updated card, whose change list grew up out of the bottom card
// over the sidebar's rows: "i dont like how it expands upwards, also it looks very bad who keeps on
// making this bad ? show me variations that it looks better".
//
// The shipped card stays still: resting on it opens no list in the card and asks the host for no
// room above it (the native host opens the changes beside the sidebar instead, in the hover card
// window). That popover's page reads whole: what the app updated to, the full version, What's New,
// and every change's title, never cut.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { UpdateHighlights } from "../src/pages/changelog/updateHighlights";
import { teardownDom } from "./support/domTeardown";

const longTitle =
  "Chats you have not read yet and chats an agent is running now show in two sections at the top of the sidebar";
const data: UpdateHighlights = {
  version: "1.0.0-nightly.4241815985601",
  build: "4241815985601",
  fromVersion: "1.0.0-nightly.4230000000001",
  fromBuild: "4230000000001",
  source: "whatsNew",
  language: "en",
  items: [
    {
      id: "computer-use",
      title: "Computer Use in agent chats",
      summary: "Agents can drive apps on your Mac.",
      category: "new",
    },
    { id: "unread", title: longTitle, summary: null, category: "new" },
  ],
  rest: [{ id: "tabs", title: "Tabs keep their scroll position", summary: null, category: "fixed" }],
  moreCount: 1,
  changelog: { from: "1.0.0-nightly.4230000000001", to: "1.0.0-nightly.4241815985601" },
};

describe("the Updated card's changes", () => {
  const scope = globalThis as Record<string, unknown>;
  const keys = [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Element",
    "Node",
    "IS_REACT_ACT_ENVIRONMENT",
    "ResizeObserver",
    "requestAnimationFrame",
  ] as const;
  const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
  let dom: JSDOM;
  let root: Root | undefined;

  beforeAll(() => {
    dom = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/#/surface/updated" });
    const { window } = dom;
    Object.defineProperty(window.HTMLElement.prototype, "scrollHeight", {
      configurable: true,
      get(this: HTMLElement) {
        return this.classList.contains("wn-preview-body") ? 120 : 0;
      },
    });
    Object.assign(scope, {
      window,
      document: window.document,
      navigator: window.navigator,
      HTMLElement: window.HTMLElement,
      Element: window.Element,
      Node: window.Node,
      IS_REACT_ACT_ENVIRONMENT: true,
      ResizeObserver: class {
        observe() {}
        disconnect() {}
        unobserve() {}
      },
      requestAnimationFrame: () => 0,
    });
  });

  afterAll(async () => {
    act(() => root?.unmount());
    await teardownDom(saved, { window: dom.window, scope });
  });

  async function mount(node: React.ReactNode) {
    const { createRoot } = await import("react-dom/client");
    act(() => root?.unmount());
    const host = dom.window.document.getElementById("root")!;
    root = createRoot(host);
    await act(async () => root!.render(node));
    return host;
  }

  test("the shipped card stays still: resting on it opens no list in it and asks for no room above it", async () => {
    const { UpdatedCard } = await import("../src/pages/changelog/UpdateSurfaces");
    const { createStrings } = await import("../src/pages/shared/i18n");
    const table = (await import("../src/pages/changelog/generated/strings.json")).default;
    const sizes: number[] = [];
    // Held open, as a full rest on the card would hold it: the shipped look still opens nothing.
    const host = await mount(
      <UpdatedCard
        data={data}
        strings={createStrings(table)}
        actions={{ openChangelog: () => undefined, dismiss: () => undefined }}
        closeButton={false}
        decoration={null}
        hostPointer={true}
        previewOpen={true}
        onPreviewSize={(height: number) => sizes.push(height)}
      />,
    );
    expect(host.querySelector(".wn-card")?.getAttribute("data-preview")).toBe("closed");
    expect(host.querySelector(".wn-preview")).toBeNull();
    expect(sizes.filter((height) => height > 0)).toEqual([]);
  });

  test("the popover beside the sidebar reads whole: the title, the full version, What's New and every change", async () => {
    const { UpdatedNotes } = await import("../src/pages/changelog/UpdatedNotes");
    const { createStrings } = await import("../src/pages/shared/i18n");
    const table = (await import("../src/pages/changelog/generated/strings.json")).default;
    const opened: string[] = [];
    const host = await mount(
      <UpdatedNotes
        data={data}
        strings={createStrings(table)}
        actions={{ openChangelog: () => opened.push("open") }}
        mode="beside"
      />,
    );
    expect(host.querySelector(".wn-notes-title")?.textContent).toBe("Updated to Nightly");
    expect(host.querySelector(".wn-notes-version")?.textContent).toContain(data.version);
    const titles = [...host.querySelectorAll(".wn-notes-row-title")].map((title) => title.textContent);
    expect(titles).toEqual(["Computer Use in agent chats", longTitle, "Tabs keep their scroll position"]);
    expect(host.querySelector(".wn-notes-row-detail")?.textContent).toBe("Agents can drive apps on your Mac.");
    const whatsNew = host.querySelector<HTMLButtonElement>(".wn-notes-whatsnew")!;
    expect(whatsNew.textContent).toBe("What's New ↗");
    await act(async () => whatsNew.click());
    await act(async () => host.querySelector<HTMLButtonElement>(".wn-notes-row")!.click());
    expect(opened).toEqual(["open", "open"]);
  });

  test("the titles-only look lists each change's title alone", async () => {
    const { UpdatedNotes } = await import("../src/pages/changelog/UpdatedNotes");
    const { createStrings } = await import("../src/pages/shared/i18n");
    const table = (await import("../src/pages/changelog/generated/strings.json")).default;
    const host = await mount(
      <UpdatedNotes
        data={data}
        strings={createStrings(table)}
        actions={{ openChangelog: () => undefined }}
        mode="beside-titles"
      />,
    );
    expect(host.querySelectorAll(".wn-notes-row-title")).toHaveLength(3);
    expect(host.querySelector(".wn-notes-row-detail")).toBeNull();
  });
});
