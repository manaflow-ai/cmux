import { Icon } from "../../agent-session/acpmux/icons/Icon";
import { useIcons } from "../../agent-session/acpmux/icons/iconsContextModel";
import { bundledIconPack, MISSING_ICON } from "../../agent-session/acpmux/icons/iconPack";
import { AgentMark } from "../../agent-session/shared/AgentMark";
import { sceneText } from "./sceneStyle";
import { symbolGlyphColor } from "./sceneSymbolRendering";

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
  "laptopcomputer": "machine.mac",
  desktopcomputer: "machine.local",
  "folder.badge.plus": "folder",
  "line.3.horizontal.decrease": "filter",
  "line.3.horizontal.decrease.circle": "filter",
  ellipsis: "action.more",
  "pin.fill": "state.pinned",
  gearshape: "settings",
  "gearshape.fill": "settings",
};

export function appSceneIcon(value: unknown): string {
  const name = sceneText(value);
  const mapped = Object.hasOwn(bundledIconPack.icons, name) ? name : SYMBOLS[name];
  return mapped && Object.hasOwn(bundledIconPack.icons, mapped) ? mapped : MISSING_ICON;
}

/** The symbol namespace of an agent's own mark: `harness:claude`, `harness:codex`, ... */
export const HARNESS_PREFIX = "harness:";

/** Unknown SF names deliberately draw a neutral fallback without an icon-pack warning. `rendering`
 * (`symbolRendering`) and `palette` (`symbolColors`) pick the glyph's color as SF Symbols' modes
 * do, for the glyph as a whole (sceneSymbolRendering.ts). */
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
  const mapped = Object.hasOwn(pack.icons, value) ? value : SYMBOLS[value];
  const name = mapped && Object.hasOwn(pack.icons, mapped) ? mapped : MISSING_ICON;
  const modeColor = name === MISSING_ICON ? undefined : symbolGlyphColor(value, rendering, palette);
  return <Icon name={name} size={size} row fit color={modeColor ?? color} className={className} />;
}
