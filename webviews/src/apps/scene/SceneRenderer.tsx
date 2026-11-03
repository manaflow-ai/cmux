import {
  createContext,
  memo,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
  useSyncExternalStore,
  type CSSProperties,
  type ReactNode,
} from "react";
import { Spinner } from "../../agent-session/acpmux/conversation/icons";
import { SceneContextMenu, SceneMenu } from "./sceneMenus";
import { SceneSymbol } from "./SceneSymbol";
import { sceneColor, sceneNumber, sceneStyle, sceneText, textStyle } from "./sceneStyle";
import type { SceneNode, SceneStore } from "./store";
import "./scene.css";

export type SceneDispatch = (node: string, event: string, payload?: unknown) => void;
/** The embedding host resolves an app-relative bundle path to a trusted local resource URL.
 * App-supplied URLs are never passed directly to an image. */
export type SceneAssetResolver = (bundlePath: string) => string | undefined;
type NodeProps = { id: string; store: SceneStore; dispatch: SceneDispatch };
const DisabledContext = createContext(false);
const AssetContext = createContext<SceneAssetResolver | undefined>(undefined);

function SceneImage({ source }: { source: unknown }) {
  const resolveAsset = useContext(AssetContext);
  if (
    !resolveAsset ||
    typeof source !== "string" ||
    !source ||
    source.startsWith("/") ||
    source.includes("\\") ||
    source.includes(":")
  )
    return null;
  // Encoded traversal must not turn into a different path when the resource handler decodes it.
  let path: string;
  try {
    path = decodeURIComponent(source);
  } catch {
    return null;
  }
  if (path.startsWith("/") || path.includes("\\") || path.includes(":") || path.split("/").includes("..")) return null;
  try {
    const url = resolveAsset(source);
    return url ? <img className="cmux-app-scene-image-content" src={url} alt="" /> : null;
  } catch {
    // A missing or inaccessible bundle asset must not take down the rest of the app section.
    return null;
  }
}

function useSceneNode(store: SceneStore, id: string) {
  const subscribe = useCallback((listener: () => void) => store.subscribeNode(id, listener), [store, id]);
  const snapshot = useCallback(() => store.getNode(id), [store, id]);
  return useSyncExternalStore(subscribe, snapshot, snapshot);
}

function SceneBadge({ text, tone }: { text: string; tone: unknown }) {
  return (
    <span className="cmux-app-scene-badge-label" style={{ color: sceneColor(tone) }}>
      {text}
    </span>
  );
}

function SceneRow({ node }: { node: SceneNode }) {
  const props = node.props;
  const subtitle = sceneText(props.subtitle);
  const symbol = sceneText(props.symbol);
  const badge = sceneText(props.badge);
  const accessory = sceneText(props.accessory);
  return (
    <>
      {symbol ? (
        <SceneSymbol
          symbol={symbol}
          color={sceneColor(props.tint) ?? (props.selected === true ? sceneColor("primary") : undefined)}
          className="cmux-app-scene-row-icon"
        />
      ) : null}
      <span className="cmux-app-scene-row-label">
        <span className="cmux-app-scene-row-title" data-unread={props.unread === true ? "" : undefined}>
          {sceneText(props.title)}
        </span>
        {subtitle ? <span className="cmux-app-scene-row-subtitle">{subtitle}</span> : null}
      </span>
      {badge ? (
        <SceneBadge text={badge} tone={props.tint} />
      ) : props.unread === true ? (
        <span className="cmux-app-scene-unread" />
      ) : null}
      {accessory ? <SceneSymbol symbol={accessory} color={sceneColor("tertiary")} size={12} /> : null}
    </>
  );
}

function SceneTextField({ node, dispatch, disabled }: { node: SceneNode; dispatch: SceneDispatch; disabled: boolean }) {
  const external = sceneText(node.props.text);
  const [text, setText] = useState(external);
  const input = useRef<HTMLInputElement>(null);
  const autofocus = node.props.autofocus === true;
  useEffect(() => {
    if (autofocus) input.current?.focus();
  }, [autofocus]);
  useEffect(() => {
    setText(external);
  }, [external]);
  return (
    <input
      ref={input}
      className="cmux-app-scene-field"
      value={text}
      placeholder={sceneText(node.props.placeholder)}
      aria-label={sceneText(node.props.help) || sceneText(node.props.placeholder) || undefined}
      disabled={disabled}
      onChange={(event) => {
        const next = event.currentTarget.value;
        setText(next);
        if (node.props.onEdit === true) dispatch(node.id, "edit", { text: next });
      }}
      onKeyDown={(event) => {
        if (event.key === "Enter") {
          event.preventDefault();
          event.stopPropagation();
          dispatch(node.id, "submit", { text });
        }
        if (event.key === "Escape") {
          event.preventDefault();
          event.stopPropagation();
          dispatch(node.id, "cancel");
        }
      }}
    />
  );
}

function contentOf(node: SceneNode, children: ReactNode, dispatch: SceneDispatch, disabled: boolean): ReactNode {
  const props = node.props;
  switch (node.type) {
    case "VStack":
    case "LazyVStack":
    case "HStack":
    case "ZStack":
    case "Group":
    case "ForEach":
    case "Reorderable":
      return children;
    case "Text":
      return (
        <span className="cmux-app-scene-text" style={textStyle(props)}>
          {sceneText(props.text)}
        </span>
      );
    case "Icon":
      return (
        <SceneSymbol
          symbol={props.symbol}
          size={Math.max(6, sceneNumber(props.size) ?? 14)}
          color={sceneColor(props.color)}
        />
      );
    case "Row":
      return <SceneRow node={node} />;
    case "Button":
      return props.title !== undefined ? sceneText(props.title) : children;
    case "Menu":
      return (
        <SceneMenu
          value={props.menu}
          node={node.id}
          dispatch={dispatch}
          title={sceneText(props.title)}
          disabled={disabled}
        />
      );
    case "Spacer":
    case "Divider":
      return null;
    case "EmptyState":
      return (
        <>
          {sceneText(props.symbol) ? <SceneSymbol symbol={props.symbol} size={16} /> : null}
          <strong>{sceneText(props.title)}</strong>
          {sceneText(props.message) ? <span>{sceneText(props.message)}</span> : null}
        </>
      );
    case "Badge":
      return <SceneBadge text={sceneText(props.text)} tone={props.tone} />;
    case "ProgressView": {
      const value = sceneNumber(props.value);
      return value === undefined ? (
        <Spinner loading size={16} />
      ) : (
        <progress
          className="cmux-app-scene-progress"
          max={1}
          value={Math.max(0, Math.min(1, value))}
          aria-label={sceneText(props.help) || undefined}
        />
      );
    }
    case "TextField":
      return <SceneTextField node={node} dispatch={dispatch} disabled={disabled} />;
    case "Circle":
    case "Capsule":
    case "Rectangle":
    case "RoundedRectangle":
      return null;
    case "Image":
      return <SceneImage source={props.src} />;
    default:
      return undefined;
  }
}

const SceneNodeView = memo(function SceneNodeView({ id, store, dispatch }: NodeProps): ReactNode {
  const node = useSceneNode(store, id);
  const inheritedDisabled = useContext(DisabledContext);
  if (!node) return null;
  const props = node.props;
  const disabled = inheritedDisabled || props.disabled === true;
  const children = node.children.map((child) => (
    <SceneNodeView key={child} id={child} store={store} dispatch={dispatch} />
  ));
  const content = contentOf(node, children, dispatch, disabled);
  if (content === undefined) return null;
  const style: CSSProperties = sceneStyle(props);
  if (node.type === "Button" && props.destructive === true) style.color = sceneColor("danger");
  if (node.type === "VStack" || node.type === "LazyVStack" || node.type === "Reorderable") {
    style.alignItems =
      props.alignment === "center" ? "center" : props.alignment === "trailing" ? "flex-end" : "stretch";
  }
  if (["Circle", "Capsule", "Rectangle", "RoundedRectangle"].includes(node.type)) {
    style.width = style.height = Math.max(0, sceneNumber(props.size) ?? 16);
    style.backgroundColor =
      sceneColor(props.fill) ?? (sceneColor(props.stroke) ? "transparent" : sceneColor("secondary"));
    if (sceneColor(props.stroke)) {
      style.borderColor = sceneColor(props.stroke);
      style.borderStyle = "solid";
      style.borderWidth = Math.max(0, sceneNumber(props.strokeWidth) ?? 1);
    }
  }
  const tappable = props.onTap === true || node.type === "Button";
  const tap = () => {
    if (!disabled) dispatch(node.id, "tap");
  };
  const shared = {
    "data-app-node": node.id,
    "data-app-type": node.type,
    "data-selected": props.selected === true ? "" : undefined,
    "data-disabled": disabled ? "" : undefined,
    "data-hover": sceneColor(props.hoverBackground) ? "" : undefined,
    className: `cmux-app-scene-node cmux-app-scene-${node.type.toLowerCase()}`,
    style,
    title: sceneText(props.help) || undefined,
  };
  let rendered: ReactNode;
  if (tappable && (node.type === "Button" || node.type === "Row")) {
    rendered = (
      <button
        {...shared}
        type="button"
        disabled={disabled}
        onClick={(event) => {
          event.stopPropagation();
          tap();
        }}
      >
        {content}
      </button>
    );
  } else if (tappable) {
    // oxlint-disable jsx-a11y/prefer-tag-over-role -- Composite scene children may contain inputs or controls, which cannot be nested in a button.
    rendered = (
      <div
        {...shared}
        role="button"
        tabIndex={!disabled ? 0 : undefined}
        aria-disabled={disabled || undefined}
        onClick={(event) => {
          event.stopPropagation();
          tap();
        }}
        onKeyDown={(event) => {
          if (event.target !== event.currentTarget || (event.key !== "Enter" && event.key !== " ")) return;
          event.preventDefault();
          event.stopPropagation();
          tap();
        }}
      >
        {content}
      </div>
    );
    // oxlint-enable jsx-a11y/prefer-tag-over-role
  } else {
    rendered = (
      <div {...shared} role={node.type === "Divider" ? "separator" : undefined}>
        {content}
      </div>
    );
  }
  if (Array.isArray(props.menu) && props.menu.length && node.type !== "Menu" && !disabled) {
    rendered = (
      <SceneContextMenu value={props.menu} node={node.id} dispatch={dispatch}>
        {rendered}
      </SceneContextMenu>
    );
  }
  return <DisabledContext.Provider value={disabled}>{rendered}</DisabledContext.Provider>;
});

export function SceneRenderer({
  store,
  dispatch,
  resolveAsset,
}: {
  store: SceneStore;
  dispatch: SceneDispatch;
  resolveAsset?: SceneAssetResolver;
}) {
  const root = useSyncExternalStore(store.subscribeRoot, store.getRoot, store.getRoot);
  return (
    <AssetContext.Provider value={resolveAsset}>
      {root ? (
        <div className="cmux-app-scene-root">
          <SceneNodeView id={root} store={store} dispatch={dispatch} />
        </div>
      ) : null}
    </AssetContext.Provider>
  );
}
