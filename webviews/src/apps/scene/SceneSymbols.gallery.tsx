// l10n-allow-file: gallery fixture text, not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { SceneSymbol, appSceneIcon } from "./SceneSymbol";

type SymbolSet = "weather" | "time-calendar" | "todo" | "unmapped";

// The SF Symbols widgets name (weather, clock, calendar, todo); the native sidebar draws the system symbol.
const SETS: Record<SymbolSet, string[]> = {
  weather: [
    "sun.max",
    "sun.max.fill",
    "moon.stars",
    "moon.stars.fill",
    "cloud",
    "cloud.fill",
    "cloud.sun",
    "cloud.sun.fill",
    "cloud.moon",
    "cloud.moon.fill",
    "cloud.drizzle",
    "cloud.rain",
    "cloud.heavyrain",
    "cloud.heavyrain.fill",
    "cloud.snow",
    "cloud.sleet",
    "cloud.bolt",
    "cloud.bolt.rain",
    "cloud.bolt.rain.fill",
    "cloud.fog",
    "wind",
    "snowflake",
    "thermometer.medium",
    "humidity",
    "humidity.fill",
    "umbrella",
    "umbrella.fill",
    "sunrise",
    "sunset",
    "sunset.fill",
  ],
  "time-calendar": [
    "clock",
    "clock.fill",
    "alarm",
    "alarm.fill",
    "calendar",
    "calendar.badge.clock",
    "location",
    "location.fill",
    "moon",
    "moon.fill",
  ],
  todo: [
    "circle",
    "checkmark.circle",
    "checkmark.circle.fill",
    "largecircle.fill.circle",
    "plus.circle",
    "plus.circle.fill",
    "checklist",
    "list.bullet",
    "square",
    "checkmark.square.fill",
    "star",
    "star.fill",
    "heart",
    "heart.fill",
    "flag",
    "flag.fill",
    "bell",
    "bell.fill",
    "plus",
    "minus",
    "xmark",
    "chevron.right",
    "chevron.down",
  ],
  // Names no table maps: each draws the quiet dot, never the "?" box (the class's detector).
  unmapped: ["not.a.real.symbol", "cloud.hail", "tornado", "figure.walk", "sparkles.rectangle.stack", "airpods"],
};

function SceneSymbols({ set = "weather" }: { set?: SymbolSet }) {
  return (
    <div
      style={{
        display: "grid",
        gridTemplateColumns: "repeat(auto-fill, minmax(116px, 1fr))",
        gap: 12,
        padding: 12,
      }}
    >
      {SETS[set].map((name) => (
        <div
          key={name}
          data-symbol={name}
          data-icon-name={appSceneIcon(name)}
          style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 4 }}
        >
          <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
            <SceneSymbol symbol={name} size={16} />
            <SceneSymbol symbol={name} size={28} />
          </div>
          <span style={{ fontSize: "var(--text-caption)", opacity: 0.7, textAlign: "center", wordBreak: "break-all" }}>
            {name}
          </span>
        </div>
      ))}
    </div>
  );
}

const ready: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector("[data-symbol] svg") !== null);
};

export default componentEntry<{ set?: SymbolSet }>({
  id: "apps.scene-symbols",
  title: "App scene SF symbols",
  area: "Apps",
  pane: true,
  height: 560,
  widths: { narrow: 320, normal: 640 },
  covers: ["apps/scene/SceneSymbol.tsx"],
  load: async () => SceneSymbols,
  variants: {
    weather: {
      note: "Weather conditions as widgets name them, at 16 and 28 px; .fill names draw the Solid form.",
      props: { set: "weather" },
      play: ready,
    },
    "time-calendar": {
      note: "Clock, alarm, calendar and location glyphs for time and calendar widgets.",
      props: { set: "time-calendar" },
      play: ready,
    },
    todo: {
      note: "Todo and list controls: check circles, radio, plus, list, star, heart, flag, bell, chevrons.",
      props: { set: "todo" },
      play: ready,
    },
    unmapped: {
      note: "SF names the table lacks: each draws a small neutral dot, never the pack's question-mark box.",
      props: { set: "unmapped" },
      play: ready,
    },
  },
});
