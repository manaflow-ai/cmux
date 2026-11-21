import { Icon } from "../../agent-session/acpmux/icons/Icon";
import { useIcons } from "../../agent-session/acpmux/icons/iconsContextModel";
import { bundledIconPack, MISSING_ICON } from "../../agent-session/acpmux/icons/iconPack";
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

export function appSceneIcon(value: unknown): string {
  const name = sceneText(value);
  const mapped = Object.hasOwn(bundledIconPack.icons, name) ? name : SYMBOLS[name];
  return mapped && Object.hasOwn(bundledIconPack.icons, mapped) ? mapped : MISSING_ICON;
}

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
  const mapped = Object.hasOwn(pack.icons, value) ? value : SYMBOLS[value];
  const name = mapped && Object.hasOwn(pack.icons, mapped) ? mapped : MISSING_ICON;
  const layerPaint = name === MISSING_ICON ? undefined : symbolLayerPaint(value, rendering, palette);
  return <Icon name={name} size={size} row fit color={color} className={className} layerPaint={layerPaint} />;
}
