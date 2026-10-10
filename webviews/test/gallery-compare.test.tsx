import { afterAll, beforeAll, expect, mock, test } from "bun:test";
import { act } from "react";
import type { Root } from "react-dom/client";
import { defineExperiment } from "../src/experiments/experiment";
import { DEFAULT_COMPARE } from "../src/gallery/compare";
import { DEFAULT_ENV, type GalleryEnv } from "../src/gallery/env";
import { componentEntry } from "../src/gallery/format";
import { installDom, privateCreateRoot, restoreDom, settle } from "./viewer-empty-dom";

// CompareView reads these generated modules from Vite. Keep the component test focused on the
// shell's frame URL behavior without loading the native metric/theme bundles.
void mock.module("virtual:cmux-gallery/metrics", () => ({ default: {} }));
void mock.module("virtual:cmux-gallery/themes", () => ({ default: [] }));

let CompareView: typeof import("../src/gallery/shell/CompareView").CompareView;
let useRoom: typeof import("../src/gallery/shell/Stage").useRoom;

const experiment = {
  definition: defineExperiment({
    id: "compare-preview",
    title: "Compare preview",
    description: "Two preview arms.",
    arms: {
      first: { label: "First", description: "First arm." },
      second: { label: "Second", description: "Second arm." },
    },
    defaultArm: "first",
  }),
  script: [{ name: "toggle", run: async () => {} }],
};

const entry = componentEntry({
  id: "ui.compare-preview",
  title: "Compare preview",
  area: "Pages",
  covers: ["test:ComparePreview"],
  load: async () => () => null,
  experiment,
  variants: { one: { props: {} } },
});

function RoomProbe() {
  const [ref] = useRoom();
  return <div ref={ref} data-room-probe />;
}

class RecordingResizeObserver {
  static instances: RecordingResizeObserver[] = [];
  observed: Element[] = [];
  disconnectCount = 0;

  constructor(_callback: ResizeObserverCallback) {
    RecordingResizeObserver.instances.push(this);
  }

  observe(node: Element): void {
    this.observed.push(node);
  }

  disconnect(): void {
    this.disconnectCount += 1;
  }
}

let env: GalleryEnv;
let root: Root;
let container: HTMLElement;

beforeAll(async () => {
  installDom();
  ({ CompareView } = await import("../src/gallery/shell/CompareView"));
  ({ useRoom } = await import("../src/gallery/shell/Stage"));
  container = document.createElement("div");
  document.body.append(container);
  root = privateCreateRoot()(container);
  env = { ...DEFAULT_ENV, frame: "component", locale: "fr" };
});

afterAll(() => {
  act(() => root?.unmount());
  container?.remove();
  restoreDom();
});

test("compare cells follow environment changes without requiring replay", async () => {
  await act(async () => {
    root.render(
      <CompareView
        entry={entry}
        experiment={experiment}
        variant="one"
        env={env}
        compare={DEFAULT_COMPARE}
        room={{ width: 1000, height: 700 }}
        onCompare={() => {}}
      />,
    );
  });
  await settle();
  const frame = () => container.querySelector("iframe") as HTMLIFrameElement;
  expect(new URL(frame().src).searchParams.get("locale")).toBe("fr");

  env = { ...env, locale: "ja" };
  await act(async () => {
    root.render(
      <CompareView
        entry={entry}
        experiment={experiment}
        variant="one"
        env={env}
        compare={DEFAULT_COMPARE}
        room={{ width: 1000, height: 700 }}
        onCompare={() => {}}
      />,
    );
  });
  await settle();
  expect(new URL(frame().src).searchParams.get("locale")).toBe("ja");
  expect(container.querySelector<HTMLAnchorElement>(".gallery-compare-cell a")?.href).toContain("locale=ja");
});

test("changing controls cancels a replay waiting on the old frame", async () => {
  const render = async () =>
    act(async () => {
      root.render(
        <CompareView
          entry={entry}
          experiment={experiment}
          variant="one"
          env={env}
          compare={DEFAULT_COMPARE}
          room={{ width: 1000, height: 700 }}
          onCompare={() => {}}
        />,
      );
    });
  await render();
  await settle();
  const status = () => container.querySelector<HTMLElement>(".gallery-controls .gallery-note")?.textContent;
  await act(async () => {
    container.querySelector<HTMLButtonElement>(".gallery-compare-primary")!.click();
  });
  await settle();
  expect(status()).toBe("waiting for cells");

  env = { ...env, locale: env.locale === "fr" ? "ja" : "fr" };
  await render();
  await settle();
  expect(status()).toContain("at the start");
});

test("useRoom cleans up its observer and resize listener", async () => {
  const savedResizeObserver = globalThis.ResizeObserver;
  const savedAddEventListener = globalThis.addEventListener;
  const savedRemoveEventListener = globalThis.removeEventListener;
  const savedInnerHeight = Object.getOwnPropertyDescriptor(globalThis, "innerHeight");
  const added: EventListenerOrEventListenerObject[] = [];
  const removed: EventListenerOrEventListenerObject[] = [];

  globalThis.ResizeObserver = RecordingResizeObserver as unknown as typeof ResizeObserver;
  globalThis.addEventListener = ((type, listener, options) => {
    if (type === "resize" && listener) added.push(listener);
    return savedAddEventListener.call(globalThis, type, listener, options);
  }) as typeof globalThis.addEventListener;
  globalThis.removeEventListener = ((type, listener, options) => {
    if (type === "resize" && listener) removed.push(listener);
    return savedRemoveEventListener.call(globalThis, type, listener, options);
  }) as typeof globalThis.removeEventListener;
  Object.defineProperty(globalThis, "innerHeight", { value: 800, configurable: true, writable: true });

  try {
    RecordingResizeObserver.instances = [];
    await act(async () => root.render(<RoomProbe />));
    await settle();
    expect(RecordingResizeObserver.instances).toHaveLength(1);
    expect(RecordingResizeObserver.instances[0]?.observed).toHaveLength(1);
    expect(added).toHaveLength(1);

    await act(async () => root.render(null));
    await settle();
    expect(RecordingResizeObserver.instances[0]?.disconnectCount).toBe(1);
    expect(removed).toEqual(added);
  } finally {
    globalThis.ResizeObserver = savedResizeObserver;
    globalThis.addEventListener = savedAddEventListener;
    globalThis.removeEventListener = savedRemoveEventListener;
    if (savedInnerHeight) Object.defineProperty(globalThis, "innerHeight", savedInnerHeight);
    else delete (globalThis as Record<string, unknown>).innerHeight;
  }
});
