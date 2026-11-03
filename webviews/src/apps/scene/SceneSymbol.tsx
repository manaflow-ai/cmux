import { Icon } from "../../agent-session/acpmux/icons/Icon";
import { useIcons } from "../../agent-session/acpmux/icons/IconsContext";
import { bundledIconPack, MISSING_ICON } from "../../agent-session/acpmux/icons/iconPack";
import { sceneText } from "./sceneStyle";

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
};

export function appSceneIcon(value: unknown): string {
  const name = sceneText(value);
  const mapped = Object.hasOwn(bundledIconPack.icons, name) ? name : SYMBOLS[name];
  return mapped && Object.hasOwn(bundledIconPack.icons, mapped) ? mapped : MISSING_ICON;
}

/** Unknown SF names deliberately draw a neutral fallback without an icon-pack warning. */
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
  const mapped = Object.hasOwn(pack.icons, value) ? value : SYMBOLS[value];
  const name = mapped && Object.hasOwn(pack.icons, mapped) ? mapped : MISSING_ICON;
  return <Icon name={name} size={size} row fit color={color} className={className} />;
}
