import { Icon } from "../../agent-session/acpmux/icons/Icon";
import { useIcons } from "../../agent-session/acpmux/icons/iconsContextModel";
import { bundledIconPack } from "../../agent-session/acpmux/icons/iconPack";
import type { IconPack } from "../../agent-session/acpmux/icons/types";
import { sceneText } from "./sceneStyle";

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
  "checkmark.circle": "status.success",
  "checkmark.circle.fill": "status.success",
  "checkmark.square": "checkbox.on",
  "checkmark.square.fill": "checkbox.on",
  square: "checkbox.off",
  checklist: "tunable.tasks",
  circle: "radio.off",
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
  "chevron.right": "disclosure.collapsed",
  "chevron.down": "disclosure.expanded",
  "chevron.left": "nav.previous",
  "chevron.up": "nav.previous.match",
  "list.bullet": "view.list",
  star: "bookmark",
  "star.fill": "bookmark",
  heart: "heart",
  "heart.fill": "heart",
  bell: "notification",
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
};

/** Drawn for a name neither the pack nor SCENE_SF_SYMBOLS knows: a small dot, so an app that names a
 *  symbol this table lacks shows a quiet bullet rather than the pack's "?" box. */
export const SCENE_FALLBACK_ICON = "status.dot";

function resolve(pack: IconPack, value: string): string {
  const mapped = Object.hasOwn(pack.icons, value) ? value : SCENE_SF_SYMBOLS[value];
  return mapped && Object.hasOwn(pack.icons, mapped) ? mapped : SCENE_FALLBACK_ICON;
}

/** The pack name a scene symbol draws (the neutral fallback when unknown). */
export function appSceneIcon(value: unknown): string {
  return resolve(bundledIconPack, sceneText(value));
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
 *  stays a small dot rather than being scaled up to the shared glyph box. */
export function SceneSymbol({
  symbol,
  size = 14,
  color,
  className,
}: {
  symbol: unknown;
  size?: number;
  color?: string;
  className?: string;
}) {
  const { pack } = useIcons();
  const value = sceneText(symbol);
  const name = resolve(pack, value);
  return (
    <Icon
      name={name}
      selected={drawsSolid(value, name)}
      size={size}
      row
      fit={name !== SCENE_FALLBACK_ICON}
      color={color}
      className={className}
    />
  );
}
