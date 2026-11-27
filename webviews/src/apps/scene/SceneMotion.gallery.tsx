// l10n-allow-file: gallery fixture text, not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { SceneMount } from "./panels";
import type { MountedPanel } from "./panelsClient";
import { SceneStore, type SceneOp } from "./store";

type Look = "reminders" | "checked" | "number" | "rolled" | "added" | "removed" | "layout";

const TASKS = [
  { id: "milk", title: "Buy milk", detail: "Today" },
  { id: "pr", title: "Review the widgets PR", detail: "10:30" },
  { id: "plants", title: "Water the plants", detail: "Evening" },
];

/** A Reminders-style list (Apple's large Reminders widget): a circle, a title that strikes through when done. */
function reminderOps(done: ReadonlySet<string>, ids: readonly string[]): SceneOp[] {
  const ops: SceneOp[] = [
    { op: "create", id: "root", type: "VStack", props: { spacing: 10, padding: 16, alignment: "leading" } },
    {
      op: "create",
      id: "heading",
      type: "Text",
      props: { text: "Reminders", font: 13, weight: "semibold", color: "accent" },
    },
    { op: "create", id: "list", type: "VStack", props: { spacing: 8, alignment: "leading" } },
  ];
  for (const task of TASKS) {
    const checked = done.has(task.id);
    ops.push(
      { op: "create", id: `row-${task.id}`, type: "HStack", props: { spacing: 8, transition: "slide", onTap: true } },
      {
        op: "create",
        id: `mark-${task.id}`,
        type: "Icon",
        props: {
          symbol: checked ? "checkmark.circle.fill" : "circle",
          size: 16,
          color: checked ? "accent" : "secondary",
        },
      },
      { op: "create", id: `col-${task.id}`, type: "VStack", props: { spacing: 1, alignment: "leading" } },
      {
        op: "create",
        id: `title-${task.id}`,
        type: "Text",
        props: {
          text: task.title,
          font: 13,
          weight: "semibold",
          strikethrough: checked,
          color: checked ? "secondary" : "primary",
          animation: "smooth",
        },
      },
      {
        op: "create",
        id: `detail-${task.id}`,
        type: "Text",
        props: { text: task.detail, font: 12, color: "secondary" },
      },
      { op: "children", id: `col-${task.id}`, children: [`title-${task.id}`, `detail-${task.id}`] },
      { op: "children", id: `row-${task.id}`, children: [`mark-${task.id}`, `col-${task.id}`] },
    );
  }
  ops.push(
    { op: "children", id: "list", children: ids.map((id) => `row-${id}`) },
    { op: "children", id: "root", children: ["heading", "list"] },
    { op: "root", id: "root" },
  );
  return ops;
}

/** A big glanceable number whose digits roll when it changes (Apple's numeric content transition). */
const numberOps: SceneOp[] = [
  { op: "create", id: "root", type: "VStack", props: { spacing: 2, padding: 16, alignment: "leading" } },
  { op: "create", id: "label", type: "Text", props: { text: "Steps", font: 13, weight: "semibold", color: "accent" } },
  {
    op: "create",
    id: "value",
    type: "Text",
    props: { text: "8,941", font: 34, weight: "semibold", contentTransition: "numericText" },
  },
  {
    op: "create",
    id: "bump",
    type: "Button",
    props: { title: "Add 12 steps" },
  },
  { op: "children", id: "root", children: ["label", "value", "bump"] },
  { op: "root", id: "root" },
];

/** The layout fixes widgets found: HStack top and bottom alignment, a centered ZStack (a ring with
 * its value inside), shapes sized by `frame` (bars), and the theme's accent tone. */
const layoutOps: SceneOp[] = [
  { op: "create", id: "root", type: "VStack", props: { spacing: 10, padding: 16, alignment: "leading" } },
  { op: "create", id: "rows", type: "HStack", props: { spacing: 12 } },
  ...(["top", "center", "bottom"] as const).flatMap((alignment): SceneOp[] => [
    {
      op: "create",
      id: `h-${alignment}`,
      type: "HStack",
      props: { alignment, spacing: 4, frame: { height: 44 }, background: "hover", cornerRadius: 6, padding: 4 },
    },
    {
      op: "create",
      id: `tall-${alignment}`,
      type: "RoundedRectangle",
      props: { frame: { width: 6, height: 36 }, fill: "accent" },
    },
    { op: "create", id: `label-${alignment}`, type: "Text", props: { text: alignment, font: 12, color: "secondary" } },
    { op: "children", id: `h-${alignment}`, children: [`tall-${alignment}`, `label-${alignment}`] },
  ]),
  { op: "children", id: "rows", children: ["h-top", "h-center", "h-bottom"] },
  { op: "create", id: "ring", type: "ZStack", props: { frame: { width: 64, height: 64 } } },
  { op: "create", id: "ring-shape", type: "Circle", props: { size: 64, stroke: "accent", strokeWidth: 5 } },
  { op: "create", id: "ring-value", type: "Text", props: { text: "72%", font: 15, weight: "semibold" } },
  { op: "children", id: "ring", children: ["ring-shape", "ring-value"] },
  { op: "create", id: "bars", type: "VStack", props: { spacing: 4, alignment: "leading" } },
  { op: "create", id: "bar-a", type: "Capsule", props: { frame: { width: 180, height: 6 }, fill: "accent" } },
  { op: "create", id: "bar-b", type: "Capsule", props: { frame: { width: 110, height: 6 }, fill: "secondary" } },
  { op: "children", id: "bars", children: ["bar-a", "bar-b"] },
  { op: "children", id: "root", children: ["rows", "ring", "bars"] },
  { op: "root", id: "root" },
];
function mounted(look: Look): { panel: MountedPanel; step?: () => void } {
  const store = new SceneStore();
  const done = new Set<string>(look === "checked" ? ["pr"] : []);
  let ids = TASKS.map((task) => task.id);
  let steps = 8941;
  if (look === "layout") store.apply(layoutOps);
  else if (look === "number" || look === "rolled") store.apply(numberOps);
  else store.apply(reminderOps(done, look === "added" ? ids.slice(0, 2) : ids));
  if (look === "added") ids = ids.slice(0, 2);
  const draw = () => store.apply(reminderOps(done, ids), true);
  const panel: MountedPanel = {
    panel: { app: "local/gallery", section: "gallery", title: "Gallery" },
    store,
    dispatch: (node, event) => {
      if (event !== "tap") return;
      if (node === "bump") {
        steps += 12;
        store.apply([{ op: "update", id: "value", props: { text: steps.toLocaleString("en-US") } }]);
        return;
      }
      const id = node.replace(/^row-/, "");
      if (done.has(id)) done.delete(id);
      else done.add(id);
      const checked = done.has(id);
      store.apply([
        {
          op: "update",
          id: `title-${id}`,
          props: { strikethrough: checked, color: checked ? "secondary" : "primary" },
        },
        {
          op: "update",
          id: `mark-${id}`,
          props: { symbol: checked ? "checkmark.circle.fill" : "circle", color: checked ? "accent" : "secondary" },
        },
      ]);
    },
    reload: draw,
    layout: () => undefined,
    resolveAsset: () => undefined,
  };
  // The gallery's own step: add the third row back, or remove the first.
  const step =
    look === "added" || look === "removed"
      ? () => {
          ids = look === "added" ? TASKS.map((task) => task.id) : ids.slice(1);
          store.apply([{ op: "children", id: "list", children: ids.map((id) => `row-${id}`) }]);
        }
      : undefined;
  return { panel, step };
}

function SceneMotion({ look = "reminders" }: { look?: Look }) {
  const [{ panel, step }] = useState(() => mounted(look));
  return (
    <div style={{ width: 300, padding: "12px 0" }}>
      <SceneMount mounted={panel} />
      {step ? (
        <button type="button" className="ui-btn" data-gallery-step onClick={step}>
          Step
        </button>
      ) : null}
    </div>
  );
}

const ready: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cmux-app-scene-mount") !== null);
};

export default componentEntry<{ look?: Look }>({
  id: "apps.scene-motion",
  title: "App scene motion, strikethrough and layout",
  area: "Apps",
  pane: true,
  height: 260,
  widths: { narrow: 300, normal: 340 },
  covers: ["apps/scene/sceneMotion.tsx", "apps/scene/SceneRenderer.tsx", "apps/scene/sceneStyle.ts"],
  load: async () => SceneMotion,
  variants: {
    reminders: {
      note: "Apple's Reminders widget rows (ref ios17-standby-clock-alarm-activity, hig-reminders-large-checkbox-rows): click a row to check it; its title strikes through and dims with a smooth animation.",
      props: { look: "reminders" },
      play: ready,
    },
    checked: {
      note: "A checked row: strikethrough plus the secondary tone, the done state Apple draws.",
      props: { look: "checked" },
      play: ready,
    },
    number: {
      note: "A big number with contentTransition numericText, before a change.",
      props: { look: "number" },
      play: ready,
    },
    rolled: {
      note: "After Add 12 steps: only the changed digits roll up (a crossfade under Reduce Motion or calm motion).",
      props: { look: "rolled" },
      play: async (ctx) => {
        await ready(ctx);
        await ctx.click({ text: "Add 12 steps" });
      },
    },
    added: {
      note: "A row added after the first frame slides in from below (transition slide).",
      props: { look: "added" },
      play: async (ctx) => {
        await ready(ctx);
        await ctx.click({ text: "Step" });
      },
    },
    layout: {
      note: "HStack alignment top, center and bottom; a ZStack ring with its value centered; Capsule bars sized by frame; the accent tone is the theme's accent (text by default, the no-blue rule; the theme's hue with appearance.accent).",
      props: { look: "layout" },
      play: ready,
    },
    removed: {
      note: "A removed row slides out upward and is drawn from its last props until it has left.",
      props: { look: "removed" },
      play: async (ctx) => {
        await ready(ctx);
        await ctx.click({ text: "Step" });
      },
    },
  },
});
