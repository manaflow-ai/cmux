import { useCallback, type CSSProperties, type ReactNode } from "react";
import "./scene.css";
import { Icon } from "../../agent-session/acpmux/icons/Icon";
import { useSceneVersion, type SceneNode, type SceneProps, type SceneStore } from "./store";
export type SceneDispatch = (node: string, event: string, payload?: unknown) => void;
const appIcon = (value: unknown): string => {
  if (typeof value !== "string" || !value) return "icon.missing";
  const aliases: Record<string, string> = { folder: "folder", clock: "time.clock", checkmark: "action.confirm", xmark: "action.close", plus: "action.add", terminal: "terminal.prompt", pullRequest: "git.pullrequest" };
  return aliases[value] ?? (value.includes(".") ? value : "icon.missing");
};
const text = (value: unknown): string => typeof value === "string" || typeof value === "number" ? String(value) : "";
function styleOf(props: SceneProps): CSSProperties {
  const style: CSSProperties = {};
  if (typeof props.opacity === "number") style.opacity = props.opacity;
  if (typeof props.rotation === "number") style.transform = `rotate(${props.rotation}deg)`;
  if (typeof props.background === "string") style.background = props.background;
  if (typeof props.color === "string") style.color = props.color;
  if (typeof props.padding === "number") style.padding = props.padding;
  if (typeof props.spacing === "number") style.gap = props.spacing;
  return style;
}
function childrenOf(store: SceneStore, node: SceneNode, dispatch: SceneDispatch): ReactNode[] {
  return node.children.map((id) => <SceneNodeView key={id} id={id} store={store} dispatch={dispatch} />);
}
function SceneNodeView({ id, store, dispatch }: { id: string; store: SceneStore; dispatch: SceneDispatch }): ReactNode {
  const node = store.getNode(id); if (!node) return null;
  const props = node.props;
  const onTap = useCallback(() => dispatch(node.id, "tap"), [dispatch, node.id]);
  const common = { "data-app-node": node.id, style: styleOf(props) };
  const children = childrenOf(store, node, dispatch);
  switch (node.type) {
    case "Text": return <span {...common} className="cmux-app-scene-text">{text(props.text)}</span>;
    case "Icon": return <span {...common}><Icon name={appIcon(props.name ?? props.symbol)} size={Number(props.size) || 14} color={text(props.tint || props.color) || undefined} /></span>;
    case "Button": return <button {...common} type="button" disabled={props.disabled === true} onClick={onTap} className="cmux-app-scene-button">{children.length ? children : text(props.title)}</button>;
    case "Row": return <div {...common} className="acpmux-session-info-row cmux-app-scene-row" onClick={props.onTap ? onTap : undefined} role={props.onTap ? "button" : undefined}>
      {props.symbol && <Icon name={appIcon(props.symbol)} size={14} row fit className="acpmux-row-glyph" color={text(props.tint) || undefined} />}
      <span className="acpmux-session-info-row__name">{text(props.title)}</span>{props.subtitle && <span className="acpmux-session-info-row__detail">{text(props.subtitle)}</span>}
      {props.badge !== undefined && <span className="acpmux-session-info-row__end">{text(props.badge)}</span>}{props.accessory !== undefined && <span className="acpmux-session-info-row__end">{text(props.accessory)}</span>}{children}
    </div>;
    case "VStack": case "LazyVStack": case "HStack": case "ZStack": case "Group": case "ForEach": case "Reorderable":
      return <div {...common} className={`cmux-app-scene-${node.type.toLowerCase()}`}>{children}</div>;
    case "Spacer": return <span {...common} className="cmux-app-scene-spacer" />;
    case "Divider": return <hr {...common} className="cmux-app-scene-divider" />;
    case "EmptyState": return <div {...common} className="cmux-app-scene-empty"><Icon name={appIcon(props.symbol)} size={16} /><strong>{text(props.title)}</strong>{props.message && <span>{text(props.message)}</span>}</div>;
    case "Badge": return <span {...common} className="cmux-app-scene-badge">{text(props.text)}</span>;
    case "ProgressView": return <progress {...common} max={1} value={typeof props.value === "number" ? Math.max(0, Math.min(1, props.value)) : undefined} />;
    case "TextField": return <input {...common} value={text(props.text)} placeholder={text(props.placeholder)} onChange={(event) => dispatch(node.id, "edit", { text: event.currentTarget.value })} onKeyDown={(event) => { if (event.key === "Enter") dispatch(node.id, "submit", { text: event.currentTarget.value }); if (event.key === "Escape") dispatch(node.id, "cancel"); }} />;
    case "Menu": return <button {...common} type="button" onClick={onTap} className="cmux-app-scene-button">{text(props.title) || "Menu"}</button>;
    case "Image": return null;
    case "Circle": case "Capsule": case "Rectangle": case "RoundedRectangle": return <span {...common} className={`cmux-app-scene-shape cmux-app-scene-${node.type.toLowerCase()}`} />;
    default: return null;
  }
}
export function SceneRenderer({ store, dispatch }: { store: SceneStore; dispatch: SceneDispatch }) {
  useSceneVersion(store); const root = store.getRoot();
  return root ? <div className="cmux-app-scene-root"><SceneNodeView id={root} store={store} dispatch={dispatch} /></div> : null;
}
