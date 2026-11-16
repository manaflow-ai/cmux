// l10n-allow-file: gallery fixture text, not shipped UI.
// The store app first-party-apps/widget-todo (cmux/todo, a cmux.widget/1) in each size, with a mixed
// list and empty, drawn by the web scene renderer from the ops its render export sends over a sample
// list (preview/scenes.json, written by its preview/build.ts from the packed app). The tile is a
// stand-in for the widget host's frame: Apple's macOS widget sizes (small 170, medium 364 x 170,
// large 364 x 382) and a continuous corner; the widget draws its own 16 pt insets. Light and dark use
// the gallery theme switch. Compare: cmux-design-references apple-widgets/web/hig-reminders-large-checkbox-rows.
import { useState } from "react";
import scenes from "../../../../first-party-apps/widget-todo/preview/scenes.json";
import { componentEntry } from "../../gallery/format";
import { SceneRenderer } from "./SceneRenderer";
import { SceneStore, type SceneOp } from "./store";
import "./TodoWidget.gallery.css";

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
    <div className="gallery-todo-widget-tile" data-size={scene.size} data-variant={variant}>
      <SceneRenderer store={store} dispatch={() => {}} />
    </div>
  );
}

function TodoWidget({ variant = "medium", all = false }: Props) {
  if (!all) return <div className="gallery-todo-widget">{<Tile variant={variant} />}</div>;
  return (
    <div className="gallery-todo-widget" data-all="">
      <div className="gallery-todo-widget-row">
        <Tile variant="small" />
        <Tile variant="small-empty" />
      </div>
      <Tile variant="medium" />
      <Tile variant="large" />
    </div>
  );
}

export default componentEntry<Props>({
  id: "apps.todo-widget",
  title: "To Do widget (store app)",
  area: "Apps",
  pane: true,
  height: 460,
  widths: { narrow: 420, normal: 440 },
  keywords: ["widget", "todo", "to-do", "reminders", "checklist", "cmux.widget"],
  covers: ["apps/scene/SceneRenderer.tsx"],
  load: async () => TodoWidget,
  variants: {
    small: {
      note: "Small: the count of open items, the list's name in the accent color, the first three items with round checkboxes and how many more.",
      props: { variant: "small" },
    },
    medium: {
      note: "Medium: count and name on the left; three items and New item on the right, with Reminders' hairlines inset to the text.",
      props: { variant: "medium" },
    },
    large: {
      note: "Large: seven items, New item, and the three done ones folded into one Completed row.",
      props: { variant: "large" },
    },
    "large-completed-open": {
      note: "Large after a click on Completed: the done items, checked and dimmed, with Clear.",
      props: { variant: "large-completed-open" },
    },
    "medium-few": {
      note: "Medium with two open items and one done: the done one is out of the list.",
      props: { variant: "medium-few" },
    },
    "small-empty": {
      note: "First install, small: 0, Nothing to do, and New item ready to type in.",
      props: { variant: "small-empty" },
    },
    "medium-empty": {
      note: "First install, medium.",
      props: { variant: "medium-empty" },
    },
    "large-empty": {
      note: "First install, large.",
      props: { variant: "large-empty" },
    },
    "all-sizes": {
      note: "Every size side by side, as the widget gallery offers them.",
      props: { all: true },
    },
  },
});
