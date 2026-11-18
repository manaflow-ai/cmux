// l10n-allow-file: gallery fixture text, not shipped UI.
// The design check `cmux ext dev` runs on a view's first scene (cmux-tui/src/cli/ext/design.rs),
// before and after, on the four example widgets of the widgets lane (clock, weather, calendar,
// todo; not in this tree yet). "Before" is each widget at each size as its PR recorded it
// (webviews/src/apps/scene/fixtures/widget-scenes.json on lane/widgets-weather-time-calendar-todo
// at 764a2bd624e, verbatim). "After" is the same widget's main.ts moved onto the SDK's type roles
// (TextIn, BigNumber, Headline, Label, Body, Caption, Footnote) and spacing scale (SPACE),
// recorded the same way. Each state's warnings are `cmux ext design --widget --json` on that
// scene, stored with it. Neither the widgets nor their migrated sources are in this tree, so this
// fixture is the record and is not regenerated from code here.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import scenes from "./fixtures/design-check-scenes.json";
import { SceneRenderer } from "./SceneRenderer";
import { SceneStore, type SceneOp } from "./store";

type Widget = "clock" | "weather" | "calendar" | "todo";
type Size = "small" | "medium" | "large";
type Finding = { check: string; count: number; message: string };
type Recorded = { before: SceneOp[]; after: SceneOp[]; warnings: { before: Finding[]; after: Finding[] } };
type Props = { widget?: Widget; size?: Size };

const recorded = scenes as unknown as Record<string, Recorded>;

/** Apple's widget sizes in points: small is one tile, medium two side by side, large two by two. */
const TILE: Record<Size, { width: number; height: number }> = {
  small: { width: 170, height: 170 },
  medium: { width: 364, height: 170 },
  large: { width: 364, height: 382 },
};

function Tile({ ops, size }: { ops: SceneOp[]; size: Size }) {
  const [store] = useState(() => {
    const s = new SceneStore();
    s.apply(ops, true);
    return s;
  });
  return (
    <div data-design-check-tile style={{ ...TILE[size], overflow: "hidden" }}>
      <SceneRenderer store={store} dispatch={() => {}} />
    </div>
  );
}

function Warnings({ findings }: { findings: Finding[] }) {
  if (findings.length === 0) return <div style={{ color: "var(--agent-muted)" }}>No design warnings</div>;
  return (
    <ul style={{ margin: 0, paddingInlineStart: 16, display: "flex", flexDirection: "column", gap: 4 }}>
      {findings.map((f) => (
        <li key={`${f.check}:${f.message}`}>
          <strong>{f.check}</strong>
          {f.count > 1 ? ` ×${f.count}` : ""}: <span style={{ color: "var(--agent-muted)" }}>{f.message}</span>
        </li>
      ))}
    </ul>
  );
}

function Side({ title, ops, findings, size }: { title: string; ops: SceneOp[]; findings: Finding[]; size: Size }) {
  const count = findings.length === 1 ? "1 warning" : `${findings.length} warnings`;
  return (
    <section style={{ display: "flex", flexDirection: "column", gap: 8, width: TILE[size].width }}>
      <div>
        <strong>{title}</strong> <span style={{ color: "var(--agent-muted)" }}>{count}</span>
      </div>
      <Tile ops={ops} size={size} />
      <Warnings findings={findings} />
    </section>
  );
}

function DesignCheck({ widget = "clock", size = "small" }: Props) {
  const scene = recorded[`${widget}.${size}`];
  if (!scene) return null;
  return (
    <div style={{ display: "flex", gap: 24, alignItems: "flex-start", padding: 12, fontSize: "var(--text-detail)" }}>
      <Side title="Before" ops={scene.before} findings={scene.warnings.before} size={size} />
      <Side title="After" ops={scene.after} findings={scene.warnings.after} size={size} />
    </div>
  );
}

const NOTES: Record<Widget, Record<Size, string>> = {
  clock: {
    small: "The weekday, the time and the date: largeTitle becomes BigNumber, the date a Caption.",
    medium: "Three cities beside the time; the cities' times are Headline, their names Caption.",
    large: "Six cities with their day and distance; title3 (15 pt on macOS) becomes Headline.",
  },
  weather: {
    small: "The place, the temperature, the sky and today's range: four roles, every Text one line.",
    medium: "Now and the next five hours; the hour labels move from caption2 to Caption.",
    large: "The hours and six days; the days' subheadline rows become Body.",
  },
  calendar: {
    small: "The date over the next event; largeTitle becomes BigNumber.",
    medium: "The date beside the next three events.",
    large: "The month grid: weekday letters Footnote, days Caption, today a Label in the accent.",
  },
  todo: {
    small: "How many are left and the first three; the count's title becomes Heading.",
    medium: "Four open items in Body and a field to add one.",
    large: "Up to ten, the field, and the ticked ones under Done.",
  },
};

const variants: Record<string, { note: string; props: Props }> = {};
for (const widget of ["clock", "weather", "calendar", "todo"] as const) {
  for (const size of ["small", "medium", "large"] as const) {
    variants[`${widget}-${size}`] = { note: NOTES[widget][size], props: { widget, size } };
  }
}

export default componentEntry<Props>({
  id: "apps.design-check",
  title: "Design check: example widgets before and after the type roles",
  area: "Apps",
  pane: true,
  height: 720,
  widths: { narrow: 800, normal: 800 },
  keywords: ["design check", "ext dev", "type roles", "spacing", "line limit", "widgets", "bad design proof"],
  covers: ["apps/scene/SceneRenderer.tsx"],
  load: async () => DesignCheck,
  variants,
});
