// l10n-allow-file: gallery fixture text, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { SceneMount } from "./panels";
import type { MountedPanel } from "./panelsClient";
import { SceneStore, type SceneOp } from "./store";

type Look = "controls" | "glass-panel" | "card-panel" | "failed" | "disconnected";

const controls: SceneOp[] = [
  { op: "create", id: "root", type: "VStack", props: { spacing: 4, padding: { leading: 8, trailing: 8 } } },
  {
    op: "create",
    id: "notify",
    type: "Toggle",
    props: { label: "Notify when CI finishes", value: true, onChange: true },
  },
  { op: "create", id: "drafts", type: "Toggle", props: { label: "Include drafts", value: false, onChange: true } },
  { op: "create", id: "locked", type: "Toggle", props: { label: "Managed by your organization", value: true } },
  {
    op: "create",
    id: "label",
    type: "Text",
    props: { text: "Show PRs from the last", font: "caption", color: "secondary" },
  },
  { op: "create", id: "hours", type: "Slider", props: { min: 1, max: 72, step: 1, value: 24, onChange: true } },
  { op: "children", id: "root", children: ["notify", "drafts", "locked", "label", "hours"] },
  { op: "root", id: "root" },
];

const panel = (style: "glass" | "card"): SceneOp[] => [
  { op: "create", id: "root", type: "VStack", props: { spacing: 8 } },
  { op: "create", id: "panel", type: "Panel", props: { title: "Checks", style } },
  {
    op: "create",
    id: "row-a",
    type: "Row",
    props: { title: "build", subtitle: "Passed in 4m", symbol: "checkmark.circle" },
  },
  { op: "create", id: "row-b", type: "Row", props: { title: "lint", subtitle: "Running", symbol: "clock" } },
  { op: "create", id: "watch", type: "Toggle", props: { label: "Watch this PR", value: true, onChange: true } },
  { op: "children", id: "panel", children: ["row-a", "row-b", "watch"] },
  { op: "children", id: "root", children: ["panel"] },
  { op: "root", id: "root" },
];

function mounted(look: Look): MountedPanel {
  const store = new SceneStore();
  if (look === "controls") store.apply(controls);
  else if (look === "glass-panel" || look === "card-panel")
    store.apply(panel(look === "card-panel" ? "card" : "glass"));
  else if (look === "failed") store.setStatus("failed", "init: main: SyntaxError: expecting ';' at main.js:2:12");
  else store.setStatus("disconnected", "cmux is reconnecting to its daemon");
  return {
    panel: { app: "local/customize", section: "gallery", title: "Gallery" },
    store,
    dispatch: (node, event, payload) => {
      if (event !== "change") return;
      store.apply([
        { op: "update", id: node, props: { value: (payload as { value?: unknown } | undefined)?.value ?? null } },
      ]);
    },
    reload: () => store.apply(controls, true),
    layout: () => undefined,
    resolveAsset: () => undefined,
  };
}

function SceneControls({ look = "controls" }: { look?: Look }) {
  const [mount] = useState(() => mounted(look));
  return (
    <div style={{ width: 300, padding: "12px 0" }}>
      <SceneMount mounted={mount} />
    </div>
  );
}

const ready: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cmux-app-scene-mount") !== null);
};

export default componentEntry<{ look?: Look }>({
  id: "apps.scene-controls",
  title: "App scene controls",
  area: "Apps",
  pane: true,
  height: 320,
  widths: { narrow: 300, normal: 340 },
  covers: ["apps/scene/SceneRenderer.tsx", "apps/scene/SceneFailure.tsx", "apps/scene/panels.tsx"],
  load: async () => SceneControls,
  variants: {
    controls: {
      note: "Toggle rows (live, off, and display-only without onChange) and a Slider, as the native settings rows draw them.",
      props: { look: "controls" },
      play: ready,
    },
    "glass-panel": {
      note: "Panel on the sidebar cards' glass veil (the default style), with a caption title and stacked children.",
      props: { look: "glass-panel" },
      play: ready,
    },
    "card-panel": {
      note: "Panel with style card: the translucent hover fill and a separator hairline.",
      props: { look: "card-panel" },
      play: ready,
    },
    failed: {
      note: "A failed mount: the native failure row's words with Reload, Copy Error and Details.",
      props: { look: "failed" },
      play: ready,
    },
    disconnected: {
      note: "A disconnected mount: one plain line, no buttons.",
      props: { look: "disconnected" },
      play: ready,
    },
  },
});
