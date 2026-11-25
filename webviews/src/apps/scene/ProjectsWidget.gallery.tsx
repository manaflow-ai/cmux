// l10n-allow-file: gallery fixture text, not shipped UI.
// The store app first-party-apps/widget-projects (cmux/projects, a cmux.widget/1) in each size and
// state, drawn by the web scene renderer from the ops its render export sends with a fake project
// index (preview/scenes.json, written by its preview/build.ts from the packed app). The tile is a
// stand-in for the widget host's frame: Apple's macOS widget sizes (small 170, medium 364 x 170,
// large 364 x 382) and a continuous corner. Light and dark use the gallery theme switch.
import { useState } from "react";
import scenes from "../../../../first-party-apps/widget-projects/preview/scenes.json";
import { componentEntry } from "../../gallery/format";
import { SceneRenderer } from "./SceneRenderer";
import { SceneStore, type SceneOp } from "./store";
import "./ProjectsWidget.gallery.css";

type Variant = keyof typeof scenes;
type Props = { variant?: Variant; all?: boolean };

function Tile({ variant }: { variant: Variant }) {
  const scene = scenes[variant];
  const [store] = useState(() => {
    const s = new SceneStore();
    s.apply(scene.ops as SceneOp[], true);
    return s;
  });
  return (
    <div className="gallery-projects-widget-tile" data-size={scene.size} data-variant={variant}>
      <SceneRenderer store={store} dispatch={() => {}} />
    </div>
  );
}

function ProjectsWidget({ variant = "medium", all = false }: Props) {
  if (!all) return <div className="gallery-projects-widget">{<Tile variant={variant} />}</div>;
  return (
    <div className="gallery-projects-widget" data-all="">
      <Tile variant="small" />
      <Tile variant="medium" />
      <Tile variant="large" />
    </div>
  );
}

export default componentEntry<Props>({
  id: "apps.projects-widget",
  title: "Projects widget (store app)",
  area: "Apps",
  pane: true,
  height: 460,
  widths: { narrow: 420, normal: 440 },
  keywords: ["widget", "projects", "folders", "recent", "machine", "cmux.widget"],
  covers: ["apps/scene/SceneRenderer.tsx"],
  load: async () => ProjectsWidget,
  variants: {
    medium: {
      note: "Chosen medium: PROJECTS and the machine's name after its colored dot, then eight project tiles, each the project's letter on its own color, pinned first.",
      props: { variant: "medium" },
    },
    small: {
      note: "Small: only the machine's name over four tiles in a 2x2 grid.",
      props: { variant: "small" },
    },
    large: {
      note: "Large: a list of eight with each project's short path and how long ago it was used.",
      props: { variant: "large" },
    },
    "small-sidebar": {
      note: "Small in the sidebar: the tighter 12 pt inset.",
      props: { variant: "small-sidebar" },
    },
    "medium-few": {
      note: "Three projects: the rest of the grid stays empty.",
      props: { variant: "medium-few" },
    },
    "medium-empty": {
      note: "No projects yet: it says how to fill it.",
      props: { variant: "medium-empty" },
    },
    "small-denied": {
      note: "Project access turned off: it says where to turn it on.",
      props: { variant: "small-denied" },
    },
    "large-other-mac": {
      note: "Another machine (Studio): its own dot color, so two machines never look alike.",
      props: { variant: "large-other-mac" },
    },
    "all-sizes": {
      note: "Every size side by side.",
      props: { all: true },
    },
  },
});
