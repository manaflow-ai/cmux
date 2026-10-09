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

let CompareView: typeof import("../src/gallery/shell/CompareView").CompareView;

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

let env: GalleryEnv;
let root: Root;
let container: HTMLElement;

beforeAll(async () => {
  installDom();
  ({ CompareView } = await import("../src/gallery/shell/CompareView"));
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
