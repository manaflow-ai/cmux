// l10n-allow-file: gallery fixture text, not shipped UI.
// The widget extensions (examples/extensions/widget-clock, widget-weather, widget-calendar,
// widget-todo), each cmux.section/1 in its three sizes, drawn by the web scene renderer from the
// ops their render exports emit. fixtures/widget-scenes.json is written by
// cmux-tui/crates/cmux-app-host/js/test/widgets.test.ts (WIDGET_SCENES=write), which fails when the
// file no longer matches what the widgets draw. The look variants compare the card surface the
// widgets could sit on; the widgets ship on `card`.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import scenes from "./fixtures/widget-scenes.json";
import { SceneRenderer } from "./SceneRenderer";
import { SceneStore, type SceneOp } from "./store";

type Widget = "clock" | "weather" | "calendar" | "todo";
type Size = "small" | "medium" | "large";
type Look = "card" | "glass" | "plain";
type Props = { widgets?: Widget[]; size?: Size; look?: Look };

const ALL: Widget[] = ["clock", "weather", "calendar", "todo"];
const recorded = scenes as unknown as Record<string, SceneOp[]>;

/** One widget's ops on a surface: the recorded Panel as is (card), as glass, or as a bare stack. */
function sceneFor(widget: Widget, size: Size, look: Look): SceneOp[] {
  return (recorded[`${widget}.${size}`] ?? []).map((op) => {
    if (op.op !== "create" || op.type !== "Panel" || look === "card") return op;
    if (look === "glass") return { ...op, props: { ...op.props, style: "glass" } };
    return { ...op, type: "VStack", props: { spacing: op.props?.spacing, menu: op.props?.menu } };
  });
}

function WidgetCard({ widget, size, look }: { widget: Widget; size: Size; look: Look }) {
  const [store] = useState(() => {
    const s = new SceneStore();
    s.apply(sceneFor(widget, size, look), true);
    return s;
  });
  return <SceneRenderer store={store} dispatch={() => {}} />;
}

function Widgets({ widgets = ALL, size = "medium", look = "card" }: Props) {
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
      {widgets.map((w) => (
        <WidgetCard key={`${w}.${size}.${look}`} widget={w} size={size} look={look} />
      ))}
    </div>
  );
}

const one = (widget: Widget, size: Size, note: string) => ({
  note,
  props: { widgets: [widget], size, look: "card" as Look },
});

export default componentEntry<Props>({
  id: "apps.widgets",
  title: "Widgets: clock, weather, calendar, to-do (example extensions)",
  area: "Apps",
  pane: true,
  height: 720,
  widths: { narrow: 240, normal: 280 },
  keywords: ["widgets", "clock", "weather", "calendar", "to-do", "todo", "extension", "sidebar section", "sizes"],
  covers: ["apps/scene/SceneRenderer.tsx"],
  load: async () => Widgets,
  variants: {
    "look-card": {
      note: "Chosen look: every widget on the opaque card surface, medium size. The card reads as one tile against the sidebar in light and dark, like a system widget.",
      props: { widgets: ALL, size: "medium", look: "card" },
    },
    "look-glass": {
      note: "Alternative: the sidebar cards' glass. Softer, but the tiles blur into the sidebar's own glass.",
      props: { widgets: ALL, size: "medium", look: "glass" },
    },
    "look-plain": {
      note: "Alternative: no surface, the content straight in the section. Lightest, but no longer reads as a widget.",
      props: { widgets: ALL, size: "medium", look: "plain" },
    },
    "clock-small": one("clock", "small", "The weekday, the time large, the date."),
    "clock-medium": one("clock", "medium", "Three cities beside the time."),
    "clock-large": one("clock", "large", "Six cities with their day and distance."),
    "weather-small": one("weather", "small", "The place, the temperature, the sky and today's range."),
    "weather-medium": one("weather", "medium", "Now and the next five hours."),
    "weather-large": one("weather", "large", "The hours and the next six days."),
    "calendar-small": one("calendar", "small", "The date over the next event; an event in progress says until when."),
    "calendar-medium": one("calendar", "medium", "The date beside the next three events."),
    "calendar-large": one("calendar", "large", "This month with today marked, then five events by day."),
    "todo-small": one("todo", "small", "How many are left and the first three."),
    "todo-medium": one("todo", "medium", "Four open items and a field to add one."),
    "todo-large": one("todo", "large", "Up to ten, the field, and the ticked ones under Done with Clear."),
  },
});
