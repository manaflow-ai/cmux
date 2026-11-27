import {
  createContext,
  memo,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
  type ReactNode,
  type RefObject,
} from "react";
import { Spinner } from "../../agent-session/acpmux/conversation/icons";
import { Switch } from "../../ui/Switch";
import { SceneContextMenu, SceneMenu } from "./sceneMenus";
import { SceneReorderable } from "./SceneReorderable";
import { SceneSymbol } from "./SceneSymbol";
import { SceneChoreography, nodeChoreography } from "./SceneChoreography";
import { SceneParticles } from "./SceneParticles";
import { loopStyle, sceneTransitionKind, sceneTransitionVars, trimRange } from "./motionProps";
import {
  SceneAppeared,
  SceneLeavingContext,
  SceneTextContent,
  useSceneChildren,
  useSceneEntering,
} from "./sceneMotion";
import { formatSceneDate, sceneDateStyle, useSceneNow, type SceneDateStyle } from "./sceneDate";
import {
  sceneColor,
  sceneNumber,
  sceneRecord,
  sceneStyle,
  sceneText,
  textStyle,
  sceneGradient,
  type SceneStyle,
  sceneGlass,
} from "./sceneStyle";
import type { SceneNode, SceneStore } from "./store";
import { currentMotionEnv, useSceneMotion, type MotionPart } from "./useSceneMotion";
import "./scene.css";

export type SceneDispatch = (node: string, event: string, payload?: unknown) => void;
/** The embedding host resolves an app-relative bundle path to a trusted local resource URL.
 * App-supplied URLs are never passed directly to an image. */
export type SceneAssetResolver = (bundlePath: string) => string | undefined;
type NodeProps = { id: string; store: SceneStore; dispatch: SceneDispatch };
const DisabledContext = createContext(false);
const AssetContext = createContext<SceneAssetResolver | undefined>(undefined);
/** False where a scene shares the page with a field of cmux's own (the New Tab slot): its `autofocus` is ignored. */
const AutofocusContext = createContext(true);

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

/** `TextField`: the text is the person's while they type. Each change goes into the scene mirror
 * (`SceneStore.reflectText`), as the host takes it from each edit, submit and cancel, so the app's
 * `text` replaces what the field shows only when it differs from it: an app that clears its draft
 * after a submit clears the field, and the host never echoes an edit back over newer typing. */
function SceneTextField({
  node,
  store,
  dispatch,
  disabled,
}: {
  node: SceneNode;
  store: SceneStore;
  dispatch: SceneDispatch;
  disabled: boolean;
}) {
  const external = sceneText(node.props.text);
  const [text, setText] = useState(external);
  const input = useRef<HTMLInputElement>(null);
  const autofocusAllowed = useContext(AutofocusContext);
  const autofocus = autofocusAllowed && node.props.autofocus === true;
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
        store.reflectText(node.id, next);
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
          dispatch(node.id, "cancel", { text });
        }
      }}
    />
  );
}

/** `Toggle`: a settings row, its `label` leading and a small switch trailing (the native
 * `AppSceneToggleNSView`). `value` is the state. With `onChange` a flip shows at once and sends
 * `change {value}` from the click itself, and the next `value` the app sends wins; without it the
 * switch only shows the app's value, disabled. */
function SceneToggle({ node, dispatch, disabled }: { node: SceneNode; dispatch: SceneDispatch; disabled: boolean }) {
  const external = node.props.value === true;
  const [shown, setShown] = useState(external);
  useEffect(() => {
    setShown(external);
  }, [external]);
  const label = typeof node.props.label === "string" ? node.props.label : undefined;
  const live = node.props.onChange === true && !disabled;
  return (
    <span className="cmux-app-scene-toggle-row">
      {label !== undefined ? <span className="cmux-app-scene-toggle-label">{label}</span> : null}
      <Switch
        size="sm"
        className="cmux-app-scene-switch"
        checked={shown}
        disabled={!live}
        aria-label={label}
        onCheckedChange={(next) => {
          if (!live) return;
          setShown(next);
          // Synchronously, inside the click: the page host refuses input that is not a gesture.
          dispatch(node.id, "change", { value: next });
        }}
      />
    </span>
  );
}

/** `min...max`; an empty, reversed or non-finite range is the default 0...1 (`AppSceneSlider.range`). */
export function sliderRange(props: SceneNode["props"]): [number, number] {
  const low = sceneNumber(props.min) ?? 0;
  const high = sceneNumber(props.max) ?? 1;
  return low < high ? [low, high] : [0, 1];
}

/** `step`, else a hundredth of the range, so a drag sends at most about a hundred values. */
export function sliderStep(props: SceneNode["props"], [low, high]: [number, number]): number {
  const step = sceneNumber(props.step);
  return step !== undefined && step > 0 ? step : (high - low) / 100;
}

/** `value` clamped to the range and snapped to the nearest step from its lower bound, rounded to the
 * step's own decimals (a 0.1 step sends 0.3, never 0.30000000000000004): `AppSceneSlider.snap`. */
export function sliderSnap(value: number, [low, high]: [number, number], step: number): number {
  const clamped = Math.min(Math.max(value, low), high);
  const snapped = low + Math.round((clamped - low) / step) * step;
  const decimals = Math.min(Math.max(Math.ceil(-Math.log10(step)) + 6, 0), 12);
  const scale = 10 ** decimals;
  return Math.min(Math.max(Math.round(snapped * scale) / scale, low), high);
}

/** `Slider`: a small slider over `min...max` snapped to `step` (the native `AppSceneSliderNSView`).
 * Each input event sends `change {value}` synchronously when its snapped value differs from the
 * last one sent, so values between two snaps are dropped, never delayed. While a drag runs the
 * app's echoes of earlier values do not move the thumb; the app's value shows when the drag ends.
 * Without `onChange` it only shows the app's value, disabled. */
function SceneSlider({ node, dispatch, disabled }: { node: SceneNode; dispatch: SceneDispatch; disabled: boolean }) {
  const range = sliderRange(node.props);
  const step = sliderStep(node.props, range);
  const appValue = sliderSnap(sceneNumber(node.props.value) ?? range[0], range, step);
  const [shown, setShown] = useState(appValue);
  // The last value sent or shown, so each snapped value is sent once even between two renders.
  const last = useRef(appValue);
  const dragging = useRef(false);
  useEffect(() => {
    if (dragging.current) return;
    last.current = appValue;
    setShown(appValue);
  }, [appValue]);
  const live = node.props.onChange === true && !disabled;
  const endDrag = () => {
    if (!dragging.current) return;
    dragging.current = false;
    last.current = appValue;
    setShown(appValue);
  };
  return (
    <input
      type="range"
      className="cmux-app-scene-slider-input"
      min={range[0]}
      max={range[1]}
      step={step}
      value={shown}
      disabled={!live}
      aria-label={sceneText(node.props.help) || undefined}
      onPointerDown={(event) => {
        dragging.current = true;
        // A release outside the track still ends the drag here.
        event.currentTarget.setPointerCapture?.(event.pointerId);
      }}
      onPointerUp={endDrag}
      onPointerCancel={endDrag}
      onLostPointerCapture={endDrag}
      onBlur={endDrag}
      onChange={(event) => {
        if (!live) return;
        const snapped = sliderSnap(Number(event.currentTarget.value), range, step);
        if (snapped === last.current) return;
        last.current = snapped;
        setShown(snapped);
        // Synchronously, inside the input event: the page host refuses input that is not a gesture.
        dispatch(node.id, "change", { value: snapped });
      }}
    />
  );
}

/** A Text with `date` and `dateStyle`: formatted here and ticked by the shared clock (sceneDate.ts),
 * so the app sends nothing while it counts. */
function SceneDateText({ props, style }: { props: SceneNode["props"]; style: SceneDateStyle }) {
  const now = useSceneNow(true);
  const text = formatSceneDate(style, props.date as number, now, { timeZone: props.timeZone });
  return <SceneTextContent text={text} transition={props.contentTransition} />;
}

const SHAPES = new Set(["Circle", "Capsule", "Rectangle", "RoundedRectangle"]);
/** HStack `alignment`: SwiftUI's vertical alignments (center is the stylesheet's default). */
const HSTACK_ALIGN: Record<string, string> = {
  top: "flex-start",
  bottom: "flex-end",
  firstTextBaseline: "first baseline",
  lastTextBaseline: "last baseline",
};

/** A stroked shape with `trim` draws its outline as SVG (a CSS border cannot draw part of itself). */
const trimmedOutline = (node: SceneNode): boolean =>
  SHAPES.has(node.type) && sceneColor(node.props.stroke) !== undefined && trimRange(node.props.trim) !== undefined;

/** The trimmed outline: `pathLength` 1, so the dash is the trimmed fraction; a circle starts at
 * 12 o'clock and runs clockwise, a rectangle at its top-left corner. The dash animates on the
 * node's `animation` (the node's part, useSceneMotion). */
function SceneShapeOutline({ node, partRef }: { node: SceneNode; partRef: RefObject<Element | null> }) {
  const props = node.props;
  const [boxWidth, boxHeight] = shapeBox(props);
  const size = Math.min(boxWidth, boxHeight);
  const width = Math.min(Math.max(0, sceneNumber(props.strokeWidth) ?? 1), size / 2);
  const [from, to] = trimRange(props.trim) ?? [0, 1];
  const outline = {
    ref: partRef as RefObject<SVGCircleElement & SVGRectElement>,
    pathLength: 1,
    fill: "none",
    strokeWidth: width,
    // A token is a var(), which a presentation attribute cannot read: the ink is a style.
    style: { stroke: sceneColor(props.stroke) },
    strokeDasharray: `${to - from} 1`,
    strokeDashoffset: -from,
  };
  const inner = size - width;
  const radius =
    node.type === "Circle" || node.type === "Capsule"
      ? inner / 2
      : node.type === "RoundedRectangle"
        ? Math.min(sceneNumber(props.cornerRadius) ?? 4, inner / 2)
        : 0;
  const cx = boxWidth / 2;
  const cy = boxHeight / 2;
  return (
    <svg className="cmux-app-scene-shape-svg" viewBox={`0 0 ${boxWidth} ${boxHeight}`} aria-hidden="true">
      {node.type === "Circle" ? (
        <circle {...outline} cx={cx} cy={cy} r={inner / 2} transform={`rotate(-90 ${cx} ${cy})`} />
      ) : (
        <rect
          {...outline}
          x={width / 2}
          y={width / 2}
          width={Math.max(0, boxWidth - width)}
          height={Math.max(0, boxHeight - width)}
          rx={radius}
        />
      )}
    </svg>
  );
}

/** A shape's box: `size` makes a square of that side; else its `frame` width and height (as the
 * native renderer: a shape fills its frame), each 16 when neither names it. */
function shapeBox(props: SceneNode["props"]): [number, number] {
  const size = sceneNumber(props.size);
  if (size !== undefined) return [Math.max(0, size), Math.max(0, size)];
  const frame = sceneRecord(props.frame);
  return [Math.max(0, sceneNumber(frame.width) ?? 16), Math.max(0, sceneNumber(frame.height) ?? 16)];
}

function contentOf(
  node: SceneNode,
  children: ReactNode,
  store: SceneStore,
  dispatch: SceneDispatch,
  disabled: boolean,
  partRef: RefObject<Element | null>,
): ReactNode {
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
    case "Text": {
      const dateStyle = sceneDateStyle(props);
      return (
        <span className="cmux-app-scene-text" style={textStyle(props)} data-date-style={dateStyle}>
          {dateStyle ? (
            <SceneDateText props={props} style={dateStyle} />
          ) : (
            <SceneTextContent text={sceneText(props.text)} transition={props.contentTransition} />
          )}
        </span>
      );
    }
    case "Icon":
      return (
        <SceneSymbol
          symbol={props.symbol}
          size={Math.max(6, sceneNumber(props.size) ?? 14)}
          color={sceneColor(props.color)}
          rendering={props.symbolRendering}
          palette={props.symbolColors}
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
      if (value === undefined) return <Spinner loading size={16} />;
      // An animated bar is a track and a fill the value scales, so the value runs on `animation`.
      if (props.animation !== undefined) {
        const fraction = Math.max(0, Math.min(1, value));
        return (
          <span
            className="cmux-app-scene-progress-track"
            // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a native <progress> cannot animate its value; this bar keeps its role and values
            role="progressbar"
            aria-valuemin={0}
            aria-valuemax={1}
            aria-valuenow={fraction}
            aria-label={sceneText(props.help) || undefined}
          >
            <span
              ref={partRef as RefObject<HTMLSpanElement | null>}
              className="cmux-app-scene-progress-fill"
              style={{ scale: `${fraction} 1` }}
            />
          </span>
        );
      }
      return (
        <progress
          className="cmux-app-scene-progress"
          max={1}
          value={Math.max(0, Math.min(1, value))}
          aria-label={sceneText(props.help) || undefined}
        />
      );
    }
    case "TextField":
      return <SceneTextField node={node} store={store} dispatch={dispatch} disabled={disabled} />;
    case "Circle":
    case "Capsule":
    case "Rectangle":
    case "RoundedRectangle":
      return trimmedOutline(node) ? <SceneShapeOutline node={node} partRef={partRef} /> : null;
    case "Particles":
      // A choreography (validated by the host) wins over a preset.
      return nodeChoreography(node) ? <SceneChoreography node={node} /> : <SceneParticles node={node} />;
    case "Line":
      return null;
    case "Image":
      return <SceneImage source={props.src} />;
    case "Toggle":
      return <SceneToggle node={node} dispatch={dispatch} disabled={disabled} />;
    case "Slider":
      return <SceneSlider node={node} dispatch={dispatch} disabled={disabled} />;
    case "Panel": {
      const title = sceneText(props.title);
      return (
        <>
          {title ? <span className="cmux-app-scene-panel-title">{title}</span> : null}
          {children}
        </>
      );
    }
    default:
      return undefined;
  }
}

type NodeViewProps = NodeProps & { leaving?: boolean };
const NO_CHILDREN: readonly string[] = [];

const SceneNodeView = memo(function SceneNodeView({ id, store, dispatch, leaving: own }: NodeViewProps): ReactNode {
  const live = useSceneNode(store, id);
  // A leaving node (and its subtree) draws from its last props, which the store keeps, until
  // its transition ends.
  const inLeaving = useContext(SceneLeavingContext);
  const leaving = own === true || inLeaving;
  const node = live ?? (leaving ? store.getDeparted(id) : undefined);
  const entering = useSceneEntering(store, node);
  const inheritedDisabled = useContext(DisabledContext);
  const element = useRef<HTMLElement>(null);
  const partRef = useRef<Element>(null);
  const type = node?.type;
  const part = useMemo<MotionPart | undefined>(() => {
    if (type === "ProgressView") return { ref: partRef, properties: ["scale"] };
    if (type && SHAPES.has(type))
      return { ref: partRef, properties: ["stroke-dasharray", "stroke-dashoffset", "stroke"] };
    return undefined;
  }, [type]);
  useSceneMotion(element, node, part);
  const shown = useSceneChildren(store, node?.children ?? NO_CHILDREN);
  if (!node) return null;
  const props = node.props;
  const disabled = inheritedDisabled || props.disabled === true || leaving;
  const childView = (child: (typeof shown)[number]) => (
    <SceneNodeView key={child.id} id={child.id} store={store} dispatch={dispatch} leaving={child.leaving} />
  );
  const children =
    node.type === "Reorderable" && props.onMove === true && !disabled ? (
      <SceneReorderable
        node={node}
        store={store}
        dispatch={dispatch}
        rows={shown.map((child) => ({ ...child, content: childView(child) }))}
      />
    ) : (
      shown.map(childView)
    );
  const content = contentOf(node, children, store, dispatch, disabled, partRef);
  if (content === undefined) return null;
  const style = sceneStyle(props) as SceneStyle & Record<`--${string}`, string | undefined>;
  // `loop`: scene.css runs the effect from these (no script per frame); the period follows ui.animationSpeed.
  const loop =
    props.loop !== undefined && typeof document !== "undefined"
      ? loopStyle(props.loop, currentMotionEnv(document).speed)
      : undefined;
  if (loop) {
    Object.assign(style, loop.vars);
    if (loop.effect === "breathe" && style.opacity !== undefined) style["--scene-opacity"] = String(style.opacity);
  }
  // `{kind, motion}`: the transition's own timing in place of the motion scale's steps (scene.css).
  if (props.transition !== undefined && typeof props.transition !== "string" && typeof document !== "undefined") {
    const timed = sceneTransitionVars(props.transition, currentMotionEnv(document), document);
    if (timed) Object.assign(style, timed);
  }
  if (node.type === "Button" && props.destructive === true) style.color = sceneColor("danger");
  if (node.type === "Panel") style.gap = sceneNumber(props.spacing) ?? "var(--cmux-app-scene-panel-spacing)";
  if (node.type === "VStack" || node.type === "LazyVStack" || node.type === "Reorderable") {
    style.alignItems =
      props.alignment === "center" ? "center" : props.alignment === "trailing" ? "flex-end" : "stretch";
  }
  if (node.type === "HStack") {
    // SwiftUI's vertical alignment: top, center (the default), bottom, or the first or last
    // text baseline (AM/PM beside a big time).
    style.alignItems = HSTACK_ALIGN[sceneText(props.alignment)];
  }
  const frame = sceneRecord(props.frame);
  if (node.type === "Line") {
    // A stroke along its width: `strokeWidth` thick (1 by default) in `stroke` (the separator ink).
    if (frame.width === undefined && frame.minWidth === undefined) style.width = "100%";
    if (frame.height === undefined) style.height = Math.max(0, sceneNumber(props.strokeWidth) ?? 1);
    style.backgroundColor = sceneColor(props.stroke) ?? sceneColor(props.fill) ?? sceneColor("separator");
  }
  if (SHAPES.has(node.type)) {
    // `size` sets both sides; a `frame` width or height wins on its own side (a bar, a capsule).
    const side = Math.max(0, sceneNumber(props.size) ?? 16);
    if (frame.width === undefined && frame.maxWidth === undefined && frame.minWidth === undefined) style.width = side;
    if (frame.height === undefined && frame.maxHeight === undefined && frame.minHeight === undefined)
      style.height = side;
    if (frame.maxWidth === "infinity" && frame.width === undefined) style.width = "100%";
    style.flexShrink = 0;
    // A gradient `fill` replaces the color; the `gradient` modifier (sceneStyle) draws over a color fill.
    const fillGradient = sceneGradient(props.fill);
    if (fillGradient) style.backgroundImage ??= fillGradient;
    style.backgroundColor = fillGradient
      ? undefined
      : (sceneColor(props.fill) ??
        (sceneColor(props.stroke) || style.backgroundImage ? "transparent" : sceneColor("secondary")));
    // A trimmed outline is SVG (SceneShapeOutline); the box draws only the fill.
    if (sceneColor(props.stroke) && !trimmedOutline(node)) {
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
    "data-style": node.type === "Panel" ? (props.style === "card" ? "card" : "glass") : undefined,
    "data-loop": loop?.effect,
    "aria-hidden": own === true || node.type === "Particles" ? true : undefined,
    // `glass`: the page's glass at that level (ui/glass/glass.css), the web twin of the App's material.
    "data-glass-level": sceneGlass(props.glass),
    "data-transition": sceneTransitionKind(props.transition),
    "data-entering": entering && !leaving ? "" : undefined,
    "data-leaving": own === true ? "" : undefined,
    "data-animation": props.animation === "smooth" || props.animation === "snappy" ? props.animation : undefined,
    // `frame({maxHeight: "infinity"})`: the node takes its stack's (or the tile's) whole height (scene.css).
    "data-fill-height": frame.maxHeight === "infinity" && frame.height === undefined ? "" : undefined,
    // `frame({maxWidth: "infinity"})`: the node takes the width its row has free (SwiftUI's flexible frame).
    "data-fill-width": frame.maxWidth === "infinity" && frame.width === undefined ? "" : undefined,
    // A ZStack child's `position` (scene.css): its center at `--app-x`, `--app-y`.
    "data-positioned": style["--app-x"] !== undefined ? "" : undefined,
    className: `cmux-app-scene-node cmux-app-scene-${node.type.toLowerCase()}${sceneGlass(props.glass) ? " ui-glass" : ""}`,
    ref: element as RefObject<HTMLDivElement & HTMLButtonElement>,
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
  if (own === true) rendered = <SceneLeavingContext.Provider value>{rendered}</SceneLeavingContext.Provider>;
  return <DisabledContext.Provider value={disabled}>{rendered}</DisabledContext.Provider>;
});

export function SceneRenderer({
  store,
  dispatch,
  resolveAsset,
  autofocus = true,
}: {
  store: SceneStore;
  dispatch: SceneDispatch;
  resolveAsset?: SceneAssetResolver;
  /** False: the scene's fields never take focus on their own; a click still focuses them. */
  autofocus?: boolean;
}) {
  const root = useSyncExternalStore(store.subscribeRoot, store.getRoot, store.getRoot);
  const generation = useSyncExternalStore(store.subscribeRoot, store.getGeneration, store.getGeneration);
  return (
    <AssetContext.Provider value={resolveAsset}>
      <AutofocusContext.Provider value={autofocus}>
        {root ? (
          <div className="cmux-app-scene-root">
            <SceneAppeared key={generation} store={store} generation={generation}>
              <SceneNodeView id={root} store={store} dispatch={dispatch} />
            </SceneAppeared>
          </div>
        ) : null}
      </AutofocusContext.Provider>
    </AssetContext.Provider>
  );
}
