// l10n-allow-file: gallery fixture text, not shipped UI.
// An app's pane (cmux-page://cmux.app-scene/): the page AppScenePage.tsx draws, on the panels mock
// host through the same mount the page makes, at a pane's size instead of a sidebar's.
import { useEffect, useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { AppSceneMount } from "../../apps/scene/panelsClient";
import { MockAppPanelsClient } from "../../apps/scene/panelsMock";
import type { SceneOp } from "../../apps/scene/store";
import { AppScenePage } from "./AppScenePage";

type Look = "list" | "settings" | "colors" | "not-reloaded" | "failed" | "disconnected" | "empty-route";

const settings: SceneOp[] = [
  { op: "create", id: "root", type: "VStack", props: { spacing: 8, padding: 12 } },
  { op: "create", id: "title", type: "Text", props: { text: "Pull requests", font: "headline" } },
  { op: "create", id: "panel", type: "Panel", props: { title: "Notifications", style: "card" } },
  { op: "create", id: "ci", type: "Toggle", props: { label: "Notify when CI finishes", value: true, onChange: true } },
  { op: "create", id: "drafts", type: "Toggle", props: { label: "Include drafts", value: false, onChange: true } },
  {
    op: "create",
    id: "hours-label",
    type: "Text",
    props: { text: "Show PRs from the last", font: "caption", color: "secondary" },
  },
  { op: "create", id: "hours", type: "Slider", props: { min: 1, max: 72, step: 1, value: 24, onChange: true } },
  { op: "children", id: "panel", children: ["ci", "drafts", "hours-label", "hours"] },
  { op: "children", id: "root", children: ["title", "panel"] },
  { op: "root", id: "root" },
];

/** The scene's status inks and badge fill (sceneStyle.ts `success`, `warning`, `badge`) on the page theme. */
const colors: SceneOp[] = [
  { op: "create", id: "root", type: "VStack", props: { spacing: 8, padding: 12 } },
  { op: "create", id: "title", type: "Text", props: { text: "Checks", font: "headline" } },
  {
    op: "create",
    id: "passed",
    type: "Row",
    props: { title: "Build and test", symbol: "checkmark.circle.fill", tint: "success", badge: "Passed" },
  },
  {
    op: "create",
    id: "pending",
    type: "Row",
    props: { title: "Release notes", symbol: "exclamationmark.triangle.fill", tint: "warning", badge: "Pending" },
  },
  { op: "create", id: "chips", type: "HStack", props: { spacing: 6 } },
  {
    op: "create",
    id: "chip-ok",
    type: "Text",
    props: { text: "3 passing", color: "success", background: "badge", cornerRadius: 4, paddingHorizontal: 6 },
  },
  {
    op: "create",
    id: "chip-warn",
    type: "Text",
    props: { text: "1 waiting", color: "warning", background: "badge", cornerRadius: 4, paddingHorizontal: 6 },
  },
  { op: "children", id: "chips", children: ["chip-ok", "chip-warn"] },
  { op: "children", id: "root", children: ["title", "passed", "pending", "chips"] },
  { op: "root", id: "root" },
];

function AppSceneGallery({ look }: { look: Look }) {
  const [mount] = useState(() => {
    if (look === "empty-route") return undefined;
    const host = new MockAppPanelsClient();
    const mount = new AppSceneMount(host, {
      surface: "pane",
      app: look === "settings" ? "samples/session" : "samples/github-prs",
      context: {},
    });
    void mount.start().then(() => {
      if (look === "settings") host.reload(host.panels[1]!, settings);
      if (look === "colors") host.reload(host.panels[0]!, colors);
      if (look === "not-reloaded")
        host.reloadFailure("mock-panel-1", "init: SyntaxError: expecting ';' at main.js:2:12");
      if (look === "failed")
        host.status("mock-panel-1", "failed", "init: main: SyntaxError: expecting ';' at main.js:2:12");
      if (look === "disconnected") host.status("mock-panel-1", "disconnected", "cmux is reconnecting to its daemon");
    });
    return mount;
  });
  useEffect(() => () => mount?.release(), [mount]);
  return <AppScenePage mounted={mount} />;
}

const drawn: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".app-scene-page") !== null);
};

export default componentEntry<{ look: Look }>({
  id: "pages.app-scene",
  title: "App pane",
  area: "Pages",
  height: 420,
  widths: { narrow: 360, normal: 640, wide: 960 },
  covers: ["page:cmux.app-scene", "pages/app-scene/AppScenePage.tsx"],
  load: async () => AppSceneGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./styles.css");
  },
  variants: {
    list: { note: "An app's pane drawing rows (a PR list), across the pane.", props: { look: "list" }, play: drawn },
    settings: {
      note: "A pane with a heading and a card Panel of Toggles and a Slider.",
      props: { look: "settings" },
      play: drawn,
    },
    colors: {
      note: "Success and warning inks on rows and text, and the badge fill behind two chips, in the page theme.",
      props: { look: "colors" },
      play: drawn,
    },
    "not-reloaded": {
      note: "A save whose script did not load: the last good rows stay, with the Not reloaded line and main.js:2:12 under them.",
      props: { look: "not-reloaded" },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".cmux-app-scene-reload-marker") !== null);
      },
    },
    failed: {
      note: "The app's script failed: the failure row with Reload, Copy Error and Details fills the pane's top.",
      props: { look: "failed" },
      play: drawn,
    },
    disconnected: {
      note: "The supervisor is unreachable: one plain line.",
      props: { look: "disconnected" },
      play: drawn,
    },
    "empty-route": { note: "A route that names no app: an empty pane.", props: { look: "empty-route" }, play: drawn },
  },
});
