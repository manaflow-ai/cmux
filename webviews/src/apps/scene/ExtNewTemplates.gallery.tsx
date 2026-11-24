// l10n-allow-file: gallery fixture text, not shipped UI.
// What `cmux ext new NAME --kind K` draws the first time it loads, for each view kind: the scene the
// kind's template renders (cmux-tui/crates/cmux-tui/src/cli/ext/templates/KIND), drawn by the web
// scene renderer from the ops the runtime emits. `before` is the template these replaced ("Hello"
// and a counter); a, b and c are the candidates; `shipped` is what the scaffold writes now, and
// cmux-tui's `ext::kinds_tests` fails when the template's scene and this fixture differ.
// The point (Leo, 2026-11-17): "make defaults for the customization so that the model can build
// prettier stuff". A model starts from these files, so the starting scene is the house style.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import scenes from "./extTemplateScenes.json";
import { SceneMount } from "./panels";
import type { MountedPanel } from "./panelsClient";
import { SceneStore, type SceneOp } from "./store";

type Kind = "sidebar" | "session-info" | "pane" | "newtab";
type Design = "before" | "a" | "b" | "c" | "shipped";
type Props = { kind?: Kind; design?: Design };

/** The width each kind is drawn at: the sidebar, the Session Info panel, a pane, a whole tab. */
const WIDTH: Record<Kind, number> = { sidebar: 260, "session-info": 300, pane: 420, newtab: 640 };

function mounted(kind: Kind, design: Design): MountedPanel {
  const store = new SceneStore();
  const ops = (scenes as Record<string, SceneOp[]>)[`${kind}-${design}`];
  if (ops) store.apply(ops);
  else store.setStatus("failed", `no scene for ${kind}-${design}`);
  return {
    panel: { app: "local/my-view", section: kind, title: "My view" },
    store,
    dispatch: () => {},
    reload: () => undefined,
    layout: () => undefined,
    resolveAsset: () => undefined,
  };
}

function ExtNewTemplate({ kind = "sidebar", design = "shipped" }: Props) {
  const [mount] = useState(() => mounted(kind, design));
  return (
    <div style={{ width: WIDTH[kind], padding: "12px 0" }}>
      <SceneMount mounted={mount} />
    </div>
  );
}

const ready: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cmux-app-scene-mount") !== null);
};

const NOTES: Record<Design, string> = {
  before: "Before: the template this replaced.",
  a: "Candidate A.",
  b: "Candidate B.",
  c: "Candidate C.",
  shipped: "Shipped: what cmux ext new writes now.",
};
const KIND_NOTES: Record<Kind, Record<Design, string>> = {
  sidebar: {
    before: "A Hello card with a click counter and two bare buttons.",
    a: "One card: the count leads with a badge, a progress bar, the list, then two buttons.",
    b: "No card: subtitled rows straight in the sidebar like the workspace list, and a count row.",
    c: "A card with a lead line and a caption, a More menu, progress, then subtitled rows that toggle.",
    shipped: "C, chosen: the lead line answers the glance, the rows carry one fact each, and the rest sits in More.",
  },
  "session-info": {
    before: "A card titled Hello from the extension around three bare rows; the section header already names it.",
    a: "Rows only: the folder's name over its path, the branch, the agent with a Live badge.",
    b: "A card with the folder as a heading and two quiet rows.",
    c: "Rows with what each value is as a badge.",
    shipped: "A without its made-up Live badge: the section header names it, so rows only, the value over what it is.",
  },
  pane: {
    before: "Hello text and bare rows.",
    a: "A title with the count, then a card of subtitled rows, the focused one selected.",
    b: "A heading and caption over plain rows, a Here badge on the focused one.",
    c: "Two stat cards over a card of rows.",
    shipped:
      "A in one card with no hand-set padding: the title and count lead, the rows have no chevron since a tap opens nothing.",
  },
  newtab: {
    before: "A Hello card with the folder and one button.",
    a: "A greeting over the folder's name, a card of three starts, a card that says how to change it.",
    b: "Centered: a symbol, the title, the folder and a row of buttons.",
    c: "Two columns of cards: starts and recent folders.",
    shipped: "A with the greeting in a card (no hand-set padding) and the how-to card left to the README.",
  },
};

const variants: Record<string, { note: string; props: Props; play: Play }> = {};
for (const kind of Object.keys(WIDTH) as Kind[])
  for (const design of ["shipped", "before", "a", "b", "c"] as Design[])
    variants[`${kind}-${design}`] = {
      note: `${NOTES[design]} ${KIND_NOTES[kind][design]}`.trim(),
      props: { kind, design },
      play: ready,
    };

export default componentEntry<Props>({
  id: "apps.ext-new-templates",
  title: "cmux ext new templates",
  area: "Apps",
  pane: true,
  height: 420,
  widths: { narrow: 300, normal: 660 },
  keywords: ["extension", "scaffold", "template", "cmux ext new", "design defaults", "sidebar section", "pane"],
  covers: ["apps/scene/SceneRenderer.tsx", "apps/scene/panels.tsx"],
  load: async () => ExtNewTemplate,
  variants,
});
