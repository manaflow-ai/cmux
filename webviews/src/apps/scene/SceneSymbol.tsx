import { Icon } from "../../agent-session/acpmux/icons/Icon";
import { useIcons } from "../../agent-session/acpmux/icons/iconsContextModel";
import { bundledIconPack, MISSING_ICON } from "../../agent-session/acpmux/icons/iconPack";
import { AgentMark } from "../../agent-session/shared/AgentMark";
import type { IconPack } from "../../agent-session/acpmux/icons/types";
import { sceneText } from "./sceneStyle";
import { symbolLayerPaint } from "./sceneSymbolRendering";

/** The common SF symbols emitted by sample apps; pack names also pass through directly. */
const SYMBOLS: Record<string, string> = {
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
  checklist: "view.list",
  xmark: "action.close",
  "xmark.circle": "status.failure",
  "xmark.circle.fill": "status.failure",
  "minus.circle": "action.remove",
  clock: "time.waiting",
  "exclamationmark.triangle": "status.warning",
  "exclamationmark.triangle.fill": "status.warning",
  plus: "action.add",
  "info.circle": "status.info",
  "info.circle.fill": "status.info",
  terminal: "terminal.prompt",
  "terminal.fill": "terminal.prompt",
  app: "app.generic",
  "app.fill": "app.generic",
  "square.stack": "apps.stack",
  link: "link",
  "arrow.up.right": "link.external",
  // The New Tab looks' names: chats, status, search and the composer.
  "bubble.left": "agent.chat",
  "bubble.left.fill": "agent.chat",
  "bubble.left.and.bubble.right": "agent.chat.list",
  "square.and.pencil": "agent.chat.new",
  "circle.fill": "status.dot",
  "smallcircle.filled.circle": "status.running",
  "arrow.clockwise": "action.reload",
  "arrow.counterclockwise": "action.undo",
  "questionmark.circle": "agent.question",
  "hand.raised": "status.needsinput",
  "hand.raised.fill": "status.needsinput",
  magnifyingglass: "search",
  "arrow.up": "composer.send",
  "arrow.up.circle.fill": "composer.send",
  paperclip: "composer.attach",
  "chevron.down": "disclosure.expanded",
  "chevron.right": "disclosure.collapsed",
  "clock.arrow.circlepath": "history.recent",
  laptopcomputer: "machine.mac",
  desktopcomputer: "machine.local",
  "folder.badge.plus": "folder",
  "line.3.horizontal.decrease": "filter",
  "line.3.horizontal.decrease.circle": "filter",
  ellipsis: "action.more",
  "pin.fill": "state.pinned",
  gearshape: "settings",
  "gearshape.fill": "settings",
  // The symbols `cmux ext new`'s templates and its design defaults (templates/common/DESIGN.md) use.
  circle: "task.status.todo",
  sparkles: "task.ai",
  rectangle: "workspace",
  "rectangle.inset.filled": "workspace",
  house: "home",
  timer: "time.waiting",
  bell: "notification",
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
};

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
  const mapped = SYMBOLS[value];
  if (mapped && Object.hasOwn(icons, mapped)) return { name: mapped, paintAs: value };
  const standIn = weatherStandIn(value);
  if (standIn && Object.hasOwn(icons, standIn[0])) return { name: standIn[0], paintAs: standIn[1] };
  return { name: MISSING_ICON, paintAs: value };
}

export function appSceneIcon(value: unknown): string {
  return resolveSceneSymbol(bundledIconPack.icons, sceneText(value)).name;
}

/** The symbol namespace of an agent's own mark: `harness:claude`, `harness:codex`, ... */
export const HARNESS_PREFIX = "harness:";

/** Unknown SF names deliberately draw a neutral fallback without an icon-pack warning. `rendering`
 * (`symbolRendering`) and `palette` (`symbolColors`) color the glyph's layers as SF Symbols' modes
 * do, as far as the pack's layers allow (sceneSymbolRendering.ts). */
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
  // `harness:<id>` (`Icon("harness:claude")`): the agent's own mark, as cmux's chat cards draw it; a
  // harness no mark knows draws the icon acpmux picked for it, else a monogram.
  if (value.startsWith(HARNESS_PREFIX) && value.length > HARNESS_PREFIX.length) {
    return (
      <span className={className ? `cmux-app-scene-harness ${className}` : "cmux-app-scene-harness"}>
        <AgentMark agent={value.slice(HARNESS_PREFIX.length)} size={size} />
      </span>
    );
  }
  const { name, paintAs } = resolveSceneSymbol(pack.icons, value);
  const layerPaint = name === MISSING_ICON ? undefined : symbolLayerPaint(paintAs, rendering, palette);
  return <Icon name={name} size={size} row fit color={color} className={className} layerPaint={layerPaint} />;
}
