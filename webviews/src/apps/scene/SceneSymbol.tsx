import { Icon } from "../../kit";
import { useIcons } from "../../agent-session/acpmux/icons/iconsContextModel";
import { bundledIconPack } from "../../agent-session/acpmux/icons/iconPack";
import type { IconPack } from "../../agent-session/acpmux/icons/types";
import { sceneText } from "./sceneStyle";
import { symbolLayerPaint } from "./sceneSymbolRendering";

/** SF Symbols apps and widgets emit, drawn with the pack glyph that means the same thing. A `.fill`
 *  name draws the glyph's Solid form (SceneSymbol), as the native sidebar draws the filled SF Symbol.
 *  Pack names also pass through directly. */
export const SCENE_SF_SYMBOLS: Readonly<Record<string, string>> = {
  "arrow.triangle.pull": "git.pullrequest",
  "arrow.triangle.pull.fill": "git.pullrequest",
  "point.3.connected.trianglepath.dotted": "git.branch",
  "arrow.triangle.branch": "git.branch",
  "folder.fill": "folder",
  doc: "file",
  "doc.text": "file.text",
  "doc.text.fill": "file.text",
  checkmark: "action.confirm",
  "checkmark.circle": "action.confirm",
  "checkmark.circle.fill": "action.confirm",
  "checkmark.square": "checkbox.on",
  "checkmark.square.fill": "checkbox.on",
  square: "checkbox.off",
  checklist: "view.list",
  "circle.fill": "color.swatch",
  "largecircle.fill.circle": "radio.on",
  xmark: "action.close",
  "xmark.circle": "status.failure",
  "xmark.circle.fill": "status.failure",
  minus: "action.remove.line",
  "minus.circle": "action.remove",
  "minus.circle.fill": "action.remove",
  plus: "action.add",
  "plus.circle": "action.add.circle",
  "plus.circle.fill": "action.add.circle",
  "chevron.down": "disclosure.expanded",
  "chevron.left": "nav.previous",
  "chevron.up": "nav.previous.match",
  heart: "heart",
  "heart.fill": "heart",
  "bell.fill": "notification",
  flag: "flag",
  "flag.fill": "flag",
  clock: "history",
  "clock.fill": "history",
  alarm: "alarm",
  "alarm.fill": "alarm",
  calendar: "calendar",
  "calendar.badge.clock": "calendar.clock",
  location: "location",
  "location.fill": "location",
  "sun.max": "appearance.light",
  "sun.max.fill": "appearance.light",
  moon: "appearance.dark",
  "moon.fill": "appearance.dark",
  "moon.stars": "weather.moon.stars",
  "moon.stars.fill": "weather.moon.stars",
  cloud: "cloud",
  "cloud.fill": "cloud",
  "cloud.sun": "weather.cloud.sun",
  "cloud.sun.fill": "weather.cloud.sun",
  "cloud.moon": "weather.cloud.moon",
  "cloud.moon.fill": "weather.cloud.moon",
  "cloud.rain": "weather.cloud.rain",
  "cloud.rain.fill": "weather.cloud.rain",
  // Rain with sun or moon: the rain glyph, the closest the pack draws.
  "cloud.sun.rain": "weather.cloud.rain",
  "cloud.sun.rain.fill": "weather.cloud.rain",
  "cloud.moon.rain": "weather.cloud.rain",
  "cloud.moon.rain.fill": "weather.cloud.rain",
  "cloud.heavyrain": "weather.cloud.heavyrain",
  "cloud.heavyrain.fill": "weather.cloud.heavyrain",
  "cloud.drizzle": "weather.cloud.drizzle",
  "cloud.drizzle.fill": "weather.cloud.drizzle",
  "cloud.snow": "weather.cloud.snow",
  "cloud.snow.fill": "weather.cloud.snow",
  "cloud.sleet": "weather.cloud.sleet",
  "cloud.sleet.fill": "weather.cloud.sleet",
  "cloud.bolt": "weather.cloud.bolt",
  "cloud.bolt.fill": "weather.cloud.bolt",
  "cloud.bolt.rain": "weather.cloud.bolt.rain",
  "cloud.bolt.rain.fill": "weather.cloud.bolt.rain",
  "cloud.fog": "weather.cloud.fog",
  "cloud.fog.fill": "weather.cloud.fog",
  wind: "weather.wind",
  snowflake: "weather.snowflake",
  thermometer: "weather.thermometer",
  "thermometer.medium": "weather.thermometer",
  humidity: "weather.humidity",
  "humidity.fill": "weather.humidity",
  umbrella: "weather.umbrella",
  "umbrella.fill": "weather.umbrella",
  sunrise: "weather.sunrise",
  "sunrise.fill": "weather.sunrise",
  sunset: "weather.sunset",
  "sunset.fill": "weather.sunset",
  "exclamationmark.triangle": "status.warning",
  "exclamationmark.triangle.fill": "status.warning",
  "info.circle": "status.info",
  "info.circle.fill": "status.info",
  terminal: "terminal.prompt",
  "terminal.fill": "terminal.prompt",
  app: "app.generic",
  "app.fill": "app.generic",
  "square.stack": "apps.stack",
  link: "link",
  "arrow.up.right": "link.external",
  "arrow.triangle.2.circlepath": "action.sync",
  gauge: "context.usage",
  "gauge.with.needle": "context.usage",
  "gauge.with.needle.fill": "context.usage",
  // The symbols `cmux ext new`'s templates and its design defaults (templates/common/DESIGN.md) use.
  circle: "task.status.todo",
  sparkles: "task.ai",
  rectangle: "workspace",
  "rectangle.inset.filled": "workspace",
  "chevron.right": "disclosure.collapsed",
  house: "home",
  timer: "time.waiting",
  bell: "notification",
  gearshape: "settings",
  magnifyingglass: "search",
  "chart.bar": "agent.activity",
  star: "bookmark",
  "star.fill": "bookmark.active",
  tray: "inbox",
  person: "account",
  globe: "link.web",
  "play.fill": "media.play",
  "pause.fill": "media.pause",
  "list.bullet": "view.list",
  "square.grid.2x2": "view.grid",
  "bubble.left": "agent.chat",
  "arrow.clockwise": "action.reload",
};

/** Drawn for a name neither the pack nor SCENE_SF_SYMBOLS knows: a small dot, so an app that names a
 *  symbol this table lacks shows a quiet bullet rather than the pack's "?" box. */
export const SCENE_FALLBACK_ICON = "status.dot";

/** The pack has a sun, a crescent and a cloud but no compound weather glyphs, so a weather SF name
 * draws its nearest one: the stand-in's pack name and the SF name its layers paint as (a sun is
 * yellow in multicolor; a cloud standing in for `cloud.sun.rain.fill` keeps the tint, since the rain
 * and sun layers it would color are not drawn). */
const SUN = ["appearance.light", "sun.max"] as const;
const MOON = ["appearance.dark", "moon"] as const;
const CLOUD = ["cloud", "cloud"] as const;
const WEATHER_CLOUD =
  /^cloud(\.(sun|moon))?(\.(rain|drizzle|heavyrain|bolt|bolt\.rain|hail|sleet|snow|fog))?(\.fill)?$/;

function weatherStandIn(name: string): readonly [string, string] | undefined {
  if (/^(sun\.(max|min)|sunrise|sunset)(\.fill)?$/.test(name)) return SUN;
  if (/^moon(\.stars)?(\.fill)?$/.test(name)) return MOON;
  if (WEATHER_CLOUD.test(name)) return CLOUD;
  return undefined;
}

/** `value`'s glyph in `icons` and the SF name its layer paint keys on (sceneSymbolRendering.ts). */
export function resolveSceneSymbol(icons: IconPack["icons"], value: string): { name: string; paintAs: string } {
  if (Object.hasOwn(icons, value)) return { name: value, paintAs: value };
  const mapped = SCENE_SF_SYMBOLS[value];
  if (mapped && Object.hasOwn(icons, mapped)) return { name: mapped, paintAs: value };
  const standIn = weatherStandIn(value);
  if (standIn && Object.hasOwn(icons, standIn[0])) return { name: standIn[0], paintAs: standIn[1] };
  return { name: SCENE_FALLBACK_ICON, paintAs: value };
}

export function appSceneIcon(value: unknown): string {
  return resolveSceneSymbol(bundledIconPack.icons, sceneText(value)).name;
}

/** `.fill` names whose glyph is already filled in Line; their Solid form means something else (a
 *  selected swatch's ring). */
const LINE_FILLED = new Set(["circle.fill"]);

function drawsSolid(value: string, icon: string): boolean {
  if (icon === SCENE_FALLBACK_ICON || LINE_FILLED.has(value)) return false;
  return value.endsWith(".fill") || value.includes(".fill.");
}

/** Whether a scene symbol draws Solid: an SF `.fill` name the pack draws as a known glyph. */
export function appSceneIconFilled(value: unknown): boolean {
  const name = sceneText(value);
  return drawsSolid(name, appSceneIcon(name));
}

/** Unknown SF names deliberately draw the neutral fallback without an icon-pack warning, unfitted so it
 *  stays a small dot rather than being scaled up to the shared glyph box. `rendering`
 *  (`symbolRendering`) and `palette` (`symbolColors`) color the glyph's layers as SF Symbols' modes
 *  do, as far as the pack's layers allow (sceneSymbolRendering.ts). */
export function SceneSymbol({
  symbol,
  size = 14,
  color,
  className,
  rendering,
  palette,
}: {
  symbol: unknown;
  size?: number;
  color?: string;
  className?: string;
  rendering?: unknown;
  palette?: unknown;
}) {
  const { pack } = useIcons();
  const value = sceneText(symbol);
  const { name, paintAs } = resolveSceneSymbol(pack.icons, value);
  const layerPaint = name === SCENE_FALLBACK_ICON ? undefined : symbolLayerPaint(paintAs, rendering, palette);
  return (
    <Icon
      name={name}
      selected={drawsSolid(value, name)}
      size={size}
      row
      fit={name !== SCENE_FALLBACK_ICON}
      color={color}
      className={className}
      layerPaint={layerPaint}
    />
  );
}
