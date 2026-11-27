import {
  createContext,
  memo,
  useCallback,
  useContext,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
  type ReactNode,
  type RefObject,
} from "react";
import { measureElement as measureBox, useVirtualizer, type Range } from "@tanstack/react-virtual";
import { Spinner } from "../../agent-session/acpmux/conversation/icons";
import { Switch } from "../../ui/Switch";
import { offsetRange, sliceBand, type VisibleSlice } from "../../ui/visibleSlice";
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
  type SceneChild,
} from "./sceneMotion";
import { formatSceneDate, sceneDateStyle, useSceneNow, type SceneDateStyle } from "./sceneDate";
import {
  sceneColor,
  sceneNumber,
  sceneStyle,
  sceneText,
  textStyle,
  sceneGradient,
  sceneRecord,
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
type NodeProps = {
  id: string;
  store: SceneStore;
  dispatch: SceneDispatch;
  /** A windowed LazyVStack's child: its place in the stack (`data-index`) and the stack's measure. */
  index?: number;
  measure?: (element: HTMLElement | null) => void;
};
const DisabledContext = createContext(false);
const AssetContext = createContext<SceneAssetResolver | undefined>(undefined);
/** False where a scene shares the page with a field of cmux's own (the New Tab slot): its `autofocus` is ignored. */
const AutofocusContext = createContext(true);

/** How the scene scrolls. `host: false`: the page owns a scroller around it (New Tab's `.nt-app-page`).
 * `host: true`: the scene is as tall as its content and the host scrolls it outside the page (an app panel,
 * whose height `layout` reports); `slice` is the part the host shows, null until it sends one. */
type SceneScroll = { host: false } | { host: true; slice: VisibleSlice | null };
const PAGE_SCROLL: SceneScroll = { host: false };
const ScrollContext = createContext<SceneScroll>(PAGE_SCROLL);
/** The scene's top: a host's slice is in CSS px from it. */
const OriginContext = createContext<RefObject<HTMLDivElement | null> | null>(null);

/** Children a LazyVStack draws whole where the host scrolls the scene and has sent no slice (or the stack is
 * no longer than this): past it, with a slice, only the children near the slice mount. */
export const LAZY_STACK_WHOLE_CAP = 100;
/** The height a child of a type the stack has not measured yet takes (px). */
const LAZY_CHILD_ESTIMATE = 28;
/** Scenes that logged a LazyVStack over the cap drawn whole: each logs once. */
const loggedOverCap = new WeakSet<SceneStore>();

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

/** A Group or ForEach that only places its children inline (`display: contents`, and no style, menu, tap,
 * help or disabled of its own that its children would inherit): a windowed LazyVStack lays its children out
 * as its own, so `LazyVStack(ForEach(...))` windows the rows. */
function isInline(node: SceneNode | undefined): boolean {
  return (
    !!node &&
    (node.type === "Group" || node.type === "ForEach") &&
    !(Array.isArray(node.props.menu) && node.props.menu.length > 0) &&
    node.props.onTap !== true &&
    node.props.disabled !== true &&
    !sceneText(node.props.help) &&
    Object.values(sceneStyle(node.props)).every((value) => value === undefined)
  );
}

/** A LazyVStack's children with its inline Groups and ForEaches opened, kept as one array until they
 * change (once per children change, never per scroll). It watches the Groups and ForEaches it met. */
class StackItems {
  private children: readonly string[] = [];
  private items: readonly string[] = [];
  private stale = true;
  private containers = new Set<string>();
  private readonly watched = new Map<string, () => void>();
  private listener: (() => void) | undefined;

  constructor(private readonly store: SceneStore) {}

  setChildren(children: readonly string[]): void {
    if (children === this.children) return;
    this.children = children;
    this.stale = true;
  }

  get = (): readonly string[] => {
    if (this.stale) this.compute();
    return this.items;
  };

  subscribe = (listener: () => void): (() => void) => {
    this.listener = listener;
    this.watch();
    return () => {
      this.listener = undefined;
      for (const stop of this.watched.values()) stop();
      this.watched.clear();
    };
  };

  private compute(): void {
    this.stale = false;
    const containers = new Set<string>();
    const flat: string[] = [];
    let opened = false;
    const walk = (ids: readonly string[], depth: number) => {
      for (const id of ids) {
        const node = this.store.getNode(id);
        if (node && (node.type === "Group" || node.type === "ForEach")) containers.add(id);
        if (depth < 64 && isInline(node)) {
          opened = true;
          walk(node!.children, depth + 1);
        } else flat.push(id);
      }
    };
    walk(this.children, 0);
    const next = opened ? flat : this.children;
    const same = next.length === this.items.length && next.every((id, at) => id === this.items[at]);
    if (!same) this.items = next;
    this.containers = containers;
    if (this.listener) this.watch();
  }

  private watch(): void {
    for (const [id, stop] of this.watched)
      if (!this.containers.has(id)) {
        stop();
        this.watched.delete(id);
      }
    for (const id of this.containers)
      if (!this.watched.has(id))
        this.watched.set(
          id,
          this.store.subscribeNode(id, () => {
            this.stale = true;
            this.listener?.();
          }),
        );
  }
}

function useStackItems(store: SceneStore, children: readonly string[]): readonly string[] {
  const source = useMemo(() => new StackItems(store), [store]);
  source.setChildren(children);
  return useSyncExternalStore(source.subscribe, source.get, source.get);
}

function scrollParent(element: HTMLElement | null): HTMLElement | null {
  const view = element?.ownerDocument.defaultView;
  if (!element || !view) return null;
  for (let parent = element.parentElement; parent; parent = parent.parentElement) {
    const overflow = view.getComputedStyle(parent).overflowY;
    if (overflow === "auto" || overflow === "scroll" || overflow === "overlay") return parent;
  }
  return null;
}

// While the host scrolls the scene, the stack's range comes from the slice (`rangeExtractor`); TanStack only
// needs a viewport to ask for one, and never scrolls anything.
// The same rect from the first render (`initialRect`): with none, TanStack has no range until its layout effect
// runs, and the first windowed commit would unmount every child (the focused one too) before the band mounts.
const HOST_RECT = { width: 1, height: 1 };
const hostRect = (_instance: unknown, cb: (rect: { width: number; height: number }) => void) => {
  cb(HOST_RECT);
};
const hostOffset = (_instance: unknown, cb: (offset: number, isScrolling: boolean) => void) => {
  cb(0, false);
};
const noScroll = () => {};

/** The wrappers that draw no box of their own (`display: contents`, scene.css): a Group, a ForEach and a
 * context menu's. Their children are the stack's flex items, so the wrapper itself measures 0. */
const CONTENTS_WRAPPER = ".cmux-app-scene-group, .cmux-app-scene-foreach, .cmux-app-scene-context";

/** An element out of the column's flow (fixed or absolute): no flex item, so no height and no gap. A scene
 * node never is; an open context menu's anchor and the popup's focus guards beside it are (fixed). Only
 * those other elements read their style, so a measure reads none per row or per wrapper. */
function outOfFlow(element: HTMLElement): boolean {
  if (element.dataset.appNode !== undefined) return false;
  const position = element.ownerDocument.defaultView?.getComputedStyle(element).position;
  return position === "fixed" || position === "absolute";
}

/** A stack child's height in a column whose items are `gap` apart. A `display: contents` wrapper spans its
 * boxes (through nested wrappers) and the gaps between them, as the column lays them out; walking its
 * own children only, never the list. */
function childHeight(element: HTMLElement, gap: number): number {
  if (!element.matches(CONTENTS_WRAPPER)) return element.offsetHeight;
  let height = 0;
  let boxes = 0;
  const walk = (parent: Element) => {
    for (const child of parent.children as HTMLCollectionOf<HTMLElement>) {
      if (child.hidden) continue;
      if (child.matches(CONTENTS_WRAPPER)) walk(child);
      else if (!outOfFlow(child)) {
        height += child.offsetHeight;
        boxes++;
      }
    }
  };
  walk(element);
  return height + Math.max(0, boxes - 1) * gap;
}

/** Holds the place of unmounted children (their heights and the gaps between them). */
function LazySpacer({ height }: { height: number }) {
  return <div className="cmux-app-scene-lazy-spacer" aria-hidden="true" style={{ height: Math.max(0, height) }} />;
}

/** A LazyVStack's children. Inside a scroller the page owns, only the children that meet the band one
 * viewport above and below the scroller's view mount; where the host scrolls the scene, every child draws
 * until the stack passes `LAZY_STACK_WHOLE_CAP` and the host's slice arrives, then only those near the
 * slice (`sliceBand`). Spacers keep each unmounted child's height and gap, so the scene's height (and the
 * panel's `layout`) does not change. A child's height is measured once mounted; one never mounted takes
 * the first measured height of its type. The focused child stays mounted. Scene motion holds: a removed child
 * with a `transition` keeps its place while it leaves, and a child enters only when a render added it, never
 * when a scroll brings it into the window. */
function LazyStackChildren({
  node,
  shown,
  store,
  dispatch,
}: {
  node: SceneNode;
  /** The stack's own children with those leaving (`useSceneChildren`), drawn when the stack draws whole. */
  shown: readonly SceneChild[];
  store: SceneStore;
  dispatch: SceneDispatch;
}) {
  // The stack's own element, through a hidden probe in it (no flex item, so no gap): the probe's ref is set
  // before this component's layout effects run, the stack's own only after them.
  const probe = useRef<HTMLSpanElement | null>(null);
  const stack = useMemo(
    () => ({
      get current() {
        return probe.current?.parentElement ?? null;
      },
    }),
    [],
  );
  const live = useStackItems(store, node.children);
  // The windowed rows: the opened children, plus those leaving at their old places (one array per change).
  const rows = useSceneChildren(store, live);
  const items = useMemo(() => rows.map((row) => row.id), [rows]);
  const scroll = useContext(ScrollContext);
  const origin = useContext(OriginContext);
  const gap = Math.max(0, sceneNumber(node.props.spacing) ?? 0);
  const count = items.length;
  const slice = scroll.host ? scroll.slice : null;
  const overCap = count > LAZY_STACK_WHOLE_CAP;
  // The page's scroller, found once the stack is in the document (undefined until then: nothing mounts).
  const [scroller, setScroller] = useState<HTMLElement | null | undefined>(scroll.host ? null : undefined);
  useLayoutEffect(() => {
    if (!scroll.host) setScroller(scrollParent(stack.current));
  }, [scroll.host, stack]);
  // Heights by child id, read from the whole drawing once when the first slice arrives, so the windowed
  // stack is exactly as tall; and the first measured height of each child type.
  const sizes = useRef(new Map<string, number>());
  const learned = useRef(new Map<string, number>());
  const [seeded, setSeeded] = useState(false);
  const mode: "pending" | "whole" | "window" = scroll.host
    ? overCap && slice && seeded
      ? "window"
      : "whole"
    : scroller === undefined
      ? "pending"
      : scroller
        ? "window"
        : "whole";
  const windowed = mode === "window";

  // Once, when the first slice reaches a stack drawn whole: never again per slice or per scroll.
  useLayoutEffect(() => {
    if (!scroll.host || !overCap || !slice || seeded || !stack.current) return;
    const wanted = new Set(items);
    for (const element of stack.current.querySelectorAll<HTMLElement>("[data-app-node]")) {
      const id = element.dataset.appNode!;
      if (wanted.delete(id)) sizes.current.set(id, childHeight(element, gap));
    }
    setSeeded(true);
  }, [scroll.host, overCap, slice, seeded, stack, items, gap]);

  const drawnWholeOverCap = overCap && mode === "whole" && !(scroll.host && slice);
  useEffect(() => {
    if (!drawnWholeOverCap || loggedOverCap.has(store)) return;
    loggedOverCap.add(store);
    console.warn(
      `app scene: a LazyVStack draws all ${count} children (over its cap of ${LAZY_STACK_WHOLE_CAP}): ` +
        "the host sends no visible slice for this scene",
    );
  }, [drawnWholeOverCap, store, count]);

  // Where the stack starts: in the scroller's content (the page's scroll) or under the scene's top (a slice).
  const [margin, setMargin] = useState(0);
  const frame = useCallback(
    () => (scroll.host ? (origin?.current ?? null) : (scroller ?? null)),
    [scroll.host, origin, scroller],
  );
  const measureMargin = useCallback(() => {
    const element = stack.current;
    const viewport = frame();
    if (!windowed || !element || !viewport) return;
    const next = scroll.host
      ? element.getBoundingClientRect().top - viewport.getBoundingClientRect().top
      : element.getBoundingClientRect().top -
        viewport.getBoundingClientRect().top +
        viewport.scrollTop -
        viewport.clientTop;
    setMargin((previous) => (previous === next ? previous : next));
  }, [windowed, stack, frame, scroll.host]);
  useLayoutEffect(measureMargin);

  const indexOf = useMemo(() => new Map(items.map((id, index) => [id, index])), [items]);
  // A row a render just added enters (scene motion); one that only scrolled into the window does not. The rows
  // drawn before: null until the stack first draws rows, which may enter only if the stack itself came after the
  // scene's first frame (as a new stack's children do; a page scroller's stack draws its rows a pass late).
  // Written only once a draw commits, so a row mounting in the render that added it is not known yet (it
  // enters), and one mounting in any later render is (it only scrolled in).
  const [cameLate] = useState(() => store.hasDrawn());
  const known = useRef<ReadonlySet<string> | null>(null);
  useEffect(() => {
    if (mode === "pending") return;
    known.current = new Set(items);
  }, [items, mode]);
  const scrolledIn = useCallback(
    (id: string) => (known.current === null ? !cameLate : known.current.has(id)),
    [cameLate],
  );
  // Tracked from mount, not from the first slice: a child focused while the stack draws whole must stay
  // mounted when the first slice windows it. Installed in a layout effect, before any child's passive effect
  // (a TextField's autofocus) can move focus, and seeded from the focus it finds (an `autoFocus` attribute
  // or a child's layout effect focused before it).
  const focused = useRef<string | undefined>(undefined);
  useLayoutEffect(() => {
    const element = stack.current;
    if (!element) return;
    // The outermost of the stack's items around the target (a child drawn whole has no `data-index`, and an
    // inline Group's children are items of their own).
    const childOf = (target: EventTarget | null) => {
      let child: string | undefined;
      for (let at = target as HTMLElement | null; at && at !== element; at = at.parentElement) {
        const id = at.dataset?.appNode;
        if (id !== undefined && indexOf.has(id)) child = id;
      }
      return child;
    };
    const focusIn = (event: FocusEvent) => {
      focused.current = childOf(event.target);
    };
    const focusOut = (event: FocusEvent) => {
      if (!element.contains(event.relatedTarget as Node | null)) focused.current = undefined;
    };
    const active = element.ownerDocument.activeElement;
    if (active && element.contains(active)) focused.current = childOf(active);
    element.addEventListener("focusin", focusIn);
    element.addEventListener("focusout", focusOut);
    return () => {
      element.removeEventListener("focusin", focusIn);
      element.removeEventListener("focusout", focusOut);
    };
  }, [stack, indexOf]);

  const itemKey = useCallback((index: number) => items[index]!, [items]);
  // react-doctor-disable-next-line react-hooks-js/incompatible-library -- TanStack Virtual returns functions the React Compiler cannot memoize safely, so this stack stays uncompiled on purpose; its range comes from the host slice and it measures each child itself, so ui/VirtualList does not fit.
  const virtualizer = useVirtualizer<HTMLElement, HTMLElement>({
    count,
    enabled: windowed,
    getScrollElement: () => (scroll.host ? stack.current : (scroller ?? null)),
    estimateSize: (index) => {
      const id = items[index]!;
      return sizes.current.get(id) ?? learned.current.get(store.getNode(id)?.type ?? "") ?? LAZY_CHILD_ESTIMATE;
    },
    getItemKey: itemKey,
    gap,
    scrollMargin: margin,
    overscan: 0,
    measureElement: (element, entry, self) =>
      element.matches(CONTENTS_WRAPPER) ? childHeight(element, gap) : measureBox(element, entry, self),
    ...(scroll.host && {
      initialRect: HOST_RECT,
      observeElementRect: hostRect,
      observeElementOffset: hostOffset,
      scrollToFn: noScroll,
    }),
    rangeExtractor: (range: Range) => {
      // Called only from the virtualizer's own reads (it draws and scrolls after the hook returns), never
      // from inside the hook, so `virtualizer` is always set here: the hook keeps one for the stack's life.
      const self = virtualizer;
      const measured = self.measurementsCache;
      let band: { low: number; high: number } | null;
      if (scroll.host) {
        // A slice holds until the host's next one, so it carries over to later revisions by design. When a
        // later revision ends above the slice, the host shows the scene's end: the band follows (its top
        // clamped to one slice height above the stack's end), so the view never comes up blank.
        const end = measured && measured.length === range.count ? measured[range.count - 1]?.end : undefined;
        band =
          slice && end !== undefined && slice.top + slice.height > end
            ? sliceBand({ ...slice, top: Math.max(0, end - slice.height) })
            : slice
              ? sliceBand(slice)
              : null;
      } else {
        const height = self.scrollRect?.height ?? 0;
        const offset = self.scrollOffset ?? 0;
        band = height > 0 ? { low: offset - height, high: offset + 2 * height } : null;
      }
      const indexes: number[] = [];
      if (band && measured && measured.length === range.count) {
        const { start, end } = offsetRange(
          range.count,
          (index) => measured[index]!.start,
          (index) => measured[index]!.end,
          band,
        );
        for (let index = start; index < end; index++) indexes.push(index);
      }
      const kept = focused.current === undefined ? undefined : indexOf.get(focused.current);
      if (kept !== undefined && kept < range.count && !indexes.includes(kept)) {
        indexes.push(kept);
        indexes.sort((a, b) => a - b);
      }
      return indexes;
    },
  });
  // The mounted `display: contents` children: no observer sees them resize (they have no box), so they are
  // measured again whenever the stack's own box resizes (a row in one grew, or the width changed).
  const wrappers = useRef(new Set<HTMLElement>());
  // Content above the stack can move it: watch each box from the stack up to the frame (no per-child observer).
  useLayoutEffect(() => {
    const viewport = frame();
    if (!windowed || !viewport || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(() => {
      measureMargin();
      for (const wrapper of wrappers.current) {
        if (!wrapper.isConnected) wrappers.current.delete(wrapper);
        else virtualizer.resizeItem(Number(wrapper.dataset.index), childHeight(wrapper, gap));
      }
    });
    for (let element: HTMLElement | null = stack.current; element; element = element.parentElement) {
      observer.observe(element);
      if (element === viewport) break;
    }
    return () => observer.disconnect();
  }, [windowed, frame, measureMargin, stack, virtualizer, gap]);
  const measure = useCallback(
    (element: HTMLElement | null) => {
      const type = element?.dataset.appType;
      if (element && type && !learned.current.has(type)) {
        const height = childHeight(element, gap);
        if (height > 0) learned.current.set(type, height);
      }
      if (element?.matches(CONTENTS_WRAPPER)) wrappers.current.add(element);
      virtualizer.measureElement(element);
    },
    [virtualizer, gap],
  );

  const drawn: ReactNode[] = [<span key="probe" ref={probe} hidden />];
  if (mode === "pending") return drawn;
  if (!windowed) {
    // Drawn whole as a VStack draws, its Groups and ForEaches kept.
    for (const child of shown)
      drawn.push(
        <SceneNodeView key={child.id} id={child.id} store={store} dispatch={dispatch} leaving={child.leaving} />,
      );
    return drawn;
  }
  const virtual = virtualizer.getVirtualItems();
  const total = virtualizer.getTotalSize();
  if (!virtual.length) {
    if (count) drawn.push(<LazySpacer key="lead" height={total} />);
    return drawn;
  }
  let previous: (typeof virtual)[number] | undefined;
  for (const item of virtual) {
    if (!previous && item.index > 0) drawn.push(<LazySpacer key="lead" height={item.start - margin - gap} />);
    else if (previous && item.index > previous.index + 1)
      drawn.push(<LazySpacer key={`before:${item.key}`} height={item.start - previous.end - 2 * gap} />);
    const row = rows[item.index]!;
    drawn.push(
      <SceneNodeView
        key={item.key}
        id={row.id}
        index={item.index}
        measure={measure}
        store={store}
        dispatch={dispatch}
        leaving={row.leaving}
        scrolledIn={scrolledIn}
      />,
    );
    previous = item;
  }
  if (previous && previous.index < count - 1)
    drawn.push(<LazySpacer key="tail" height={margin + total - previous.end - gap} />);
  return drawn;
}

type NodeViewProps = NodeProps & {
  leaving?: boolean;
  /** A windowed LazyVStack's child: true when this mount only scrolled into the window (no enter motion). */
  scrolledIn?: (id: string) => boolean;
};
const NO_CHILDREN: readonly string[] = [];

const SceneNodeView = memo(function SceneNodeView({
  id,
  store,
  dispatch,
  index,
  measure,
  leaving: own,
  scrolledIn,
}: NodeViewProps): ReactNode {
  const live = useSceneNode(store, id);
  // A leaving node (and its subtree) draws from its last props, which the store keeps, until
  // its transition ends.
  const inLeaving = useContext(SceneLeavingContext);
  const leaving = own === true || inLeaving;
  const node = live ?? (leaving ? store.getDeparted(id) : undefined);
  const entering = useSceneEntering(store, node, scrolledIn?.(id) !== true);
  const inheritedDisabled = useContext(DisabledContext);
  const element = useRef<HTMLElement>(null);
  // One ref for both: the motion hooks read `element`, and the stack measures the node.
  const ref = useCallback(
    (el: HTMLElement | null) => {
      element.current = el;
      measure?.(el);
    },
    [measure],
  );
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
    node.type === "LazyVStack" ? (
      <LazyStackChildren node={node} shown={shown} store={store} dispatch={dispatch} />
    ) : node.type === "Reorderable" && props.onMove === true && !disabled ? (
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
    ref,
    "data-index": index,
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
  hostScrolled = false,
  visibleSlice = null,
  autofocus = true,
}: {
  store: SceneStore;
  dispatch: SceneDispatch;
  resolveAsset?: SceneAssetResolver;
  /** The host scrolls the scene outside the page (an app panel): see `SceneScroll`. */
  hostScrolled?: boolean;
  /** With `hostScrolled`, the part of the scene the host shows (CSS px from its top); null: none yet. */
  visibleSlice?: VisibleSlice | null;
  /** False: the scene's fields never take focus on their own; a click still focuses them. */
  autofocus?: boolean;
}) {
  const root = useSyncExternalStore(store.subscribeRoot, store.getRoot, store.getRoot);
  const origin = useRef<HTMLDivElement | null>(null);
  const scroll = useMemo<SceneScroll>(
    () => (hostScrolled ? { host: true, slice: visibleSlice } : PAGE_SCROLL),
    [hostScrolled, visibleSlice],
  );
  const generation = useSyncExternalStore(store.subscribeRoot, store.getGeneration, store.getGeneration);
  return (
    <AssetContext.Provider value={resolveAsset}>
      <AutofocusContext.Provider value={autofocus}>
        <ScrollContext.Provider value={scroll}>
          <OriginContext.Provider value={origin}>
            {root ? (
              <div ref={origin} className="cmux-app-scene-root">
                <SceneAppeared key={generation} store={store} generation={generation}>
                  <SceneNodeView id={root} store={store} dispatch={dispatch} />
                </SceneAppeared>
              </div>
            ) : null}
          </OriginContext.Provider>
        </ScrollContext.Provider>
      </AutofocusContext.Provider>
    </AssetContext.Provider>
  );
}
