// The browser toolbar strip: Back, Forward, Reload (Stop while loading), the omnibar with its
// page-info chip and bookmark star, the pinned extension actions and the Extensions button, the
// pinned trailing buttons and More, and the load progress line. The web twin of the native
// BrowserChromeView toolbar row at the Standard density (toolbarModel.ts holds the numbers). It
// draws the props and reports presses as `BrowserToolbarCommand`s; the editing field itself can be
// the omnibox's (`field`). As the pane narrows the toolbar collapses in the native order
// (resolveLayout); only the buttons that fit are rendered, so its cost does not grow with the
// number of pinned buttons. The live toolbar page (pages/browser-toolbar) passes the host's
// resolved buttons, badges and density metrics, its own field, and its layout.
import {
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type CSSProperties,
  type MouseEvent as ReactMouseEvent,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
} from "react";
import { Icon } from "../../agent-session/acpmux/icons/Icon";
import type { Strings } from "../../pages/shared/i18n";
import { toolbarStrings } from "./strings";
import {
  resolveLayout,
  shownButtons,
  TOOLBAR_METRICS as M,
  visibleButtons,
  type BrowserToolbarCommand,
  type ChipLabel,
  type ExtensionAction,
  type OmnibarBadges,
  type OmnibarState,
  type ResolvedToolbarButton,
  type ToolbarButton,
  type ToolbarLayout,
  type ToolbarRowMetrics,
} from "./toolbarModel";
import "./browserChrome.css";

/**
 * - `flat`: today's bar, a tonal fill over the toolbar with a hover lift.
 * - `outlined`: no fill at rest, a hairline edge; the page shows through.
 * - `capsule`: the flat bar fully rounded, its chip a circle.
 */
export type OmnibarLook = "flat" | "outlined" | "capsule";

export type BrowserToolbarProps = {
  navigation: {
    canGoBack: boolean;
    canGoForward: boolean;
    loading: boolean;
    /** False turns Reload off (the Markdown tab's empty state); absent means on. */
    canReload?: boolean;
    /** 0...1 while loading; the line under the toolbar. */
    progress?: number;
  };
  omnibar: OmnibarState;
  extensions?: { shows: boolean; pinned: readonly ExtensionAction[] };
  /** The pinned trailing buttons that have something to show; More is always added. */
  buttons?: readonly ToolbarButton[];
  onCommand: (command: BrowserToolbarCommand) => void;
  look?: OmnibarLook;
  /** The pane's width; absent, the toolbar measures itself. */
  width?: number;
  /** The omnibox's field, drawn in place of the address text whenever given (at rest too). */
  field?: ReactNode;
  strings?: Strings;
  /** The host's resolved trailing buttons (More included), drawn as given in place of `buttons`. */
  resolvedButtons?: readonly ResolvedToolbarButton[];
  /** The density's sizes; absent, the Standard density's. */
  metrics?: ToolbarRowMetrics;
  /** The layout to draw (the page resolved it); absent, the toolbar resolves its own. */
  layout?: ToolbarLayout;
  /** Badges inside the omnibar, before the star. */
  badges?: OmnibarBadges;
  /** False: the omnibar alone (a popup window's bar). */
  showsButtons?: boolean;
  /** False: no load progress line (the host draws it). */
  showsProgress?: boolean;
  /** The buttons never take DOM focus, so a press keeps the field editing. */
  holdsFieldFocus?: boolean;
  /** A press on the field's area; absent, an idle press sends `focusAddressBar`. */
  onFieldMouseDown?: (event: ReactMouseEvent<HTMLDivElement>) => void;
  /** The address the chip drags out at rest; null: no drag. */
  chipDrag?: { url: string; title: string | null } | null;
  /** The pinned extension whose popup is open, and the Extensions menu open: drawn pressed. */
  extensionPressed?: string | null;
  extensionsPressed?: boolean;
  /** An extension crashed: a warning button before the Extensions button (`label`: name and tooltip). */
  extensionsCrashed?: { label: string } | null;
  style?: CSSProperties;
};

const standardStyle = {
  "--bc-bar": `${M.bar}px`,
  "--bc-button": `${M.button}px`,
  "--bc-spacing": `${M.spacing}px`,
  "--bc-margin": `${M.margin}px`,
  "--bc-inset": `${M.inset}px`,
  "--bc-gap-below": `${M.gapBelow}px`,
  "--bc-chip": `${M.chip}px`,
  "--bc-chip-leading": `${M.chipLeading}px`,
  "--bc-text-leading": `${M.textLeading}px`,
  "--bc-trailing-padding": `${M.trailingPadding}px`,
  "--bc-trailing-box": `${M.trailingBox}px`,
} as CSSProperties;

/** The CSS sizes for the host's density: the row is the bar's height (the host places it). */
export function rowMetricsStyle(m: ToolbarRowMetrics): CSSProperties {
  const chip = m.bar - 2 * M.chipLeading;
  return {
    "--bc-bar": `${m.bar}px`,
    "--bc-button": `${m.button}px`,
    "--bc-spacing": `${m.spacing}px`,
    "--bc-margin": `${m.margin}px`,
    "--bc-inset": `${m.inset}px`,
    "--bc-trailing-inset": `${m.trailingInset ?? m.inset}px`,
    "--bc-gap-below": "0px",
    "--bc-chip": `${chip}px`,
    "--bc-chip-leading": `${M.chipLeading}px`,
    "--bc-text-leading": `${M.textLeading}px`,
    "--bc-trailing-padding": `${M.trailingPadding}px`,
    "--bc-trailing-box": `${m.trailingIcon + 2}px`,
    "--bc-bar-radius": `${m.cornerRadius}px`,
    "--text-field": `${m.fontSize}px`,
  } as CSSProperties;
}

/** Icon sizes: the Standard density's, or the host's. */
type IconSizes = { toolbar: number; chip: number; trailing: number; star: number };
const STANDARD_ICONS: IconSizes = { toolbar: 20, chip: 16, trailing: 18, star: 20 };

/** A press that must not move DOM focus out of the field. */
const keepFocus = (event: ReactMouseEvent) => event.preventDefault();
/**
 * `keepFocus` for a draggable control (a pinned extension): only while the field has the keys, so
 * at rest the press can still start a drag to reorder.
 */
const keepFocusWhileEditing = (event: ReactMouseEvent) => {
  if (event.currentTarget.ownerDocument.activeElement?.tagName === "INPUT") event.preventDefault();
};

// MARK: Button states (BrowserToolbarPolicy)

type ButtonState = {
  icon: string;
  label: string;
  enabled: boolean;
  active: boolean;
  tooltip: boolean;
  progress?: number;
};

export function toolbarButtonState(strings: Strings, button: ToolbarButton): ButtonState {
  const t = strings.t;
  const base = { enabled: true, active: false, tooltip: false };
  switch (button.id) {
    case "media":
      return { ...base, icon: "browser.toolbar.media", label: t("browser.toolbar.media") };
    case "zoom":
      return {
        ...base,
        icon: button.percent < 100 ? "browser.toolbar.zoom.out" : "browser.toolbar.zoom.in",
        label: strings.format("browser.toolbar.zoom", String(button.percent)),
        tooltip: true,
      };
    case "favorites":
      return { ...base, icon: "browser.toolbar.bookmarks", label: t("browser.toolbar.favorites") };
    case "downloads":
      return {
        ...base,
        icon: button.inProgress ? "browser.toolbar.downloads.active" : "browser.toolbar.downloads",
        label: t("browser.toolbar.downloads"),
        active: !!button.inProgress,
        progress: button.inProgress ? (button.progress ?? -1) : undefined,
      };
    case "designMode": {
      const enabled = button.enabled ?? true;
      return {
        ...base,
        icon: "theme",
        label: t("browser.toolbar.designMode"),
        enabled,
        active: !!button.active,
        tooltip: !enabled,
      };
    }
    case "profile":
      return {
        ...base,
        icon: "browser.toolbar.profile",
        label: button.name
          ? strings.format("browser.toolbar.profile", button.name)
          : t("browser.toolbar.profileUnknown"),
        tooltip: true,
      };
    case "theme":
      return {
        ...base,
        icon: `appearance.${button.scheme}`,
        label: strings.format("browser.toolbar.theme", t(`browser.toolbar.theme.${button.scheme}`)),
        tooltip: true,
      };
    case "devTools":
      if (!button.available) {
        const reason = button.needsChromium
          ? "browser.toolbar.devTools.needsChromium"
          : "browser.toolbar.devTools.unavailable";
        return {
          ...base,
          icon: "browser.toolbar.devtools",
          label: t(reason),
          enabled: false,
          tooltip: true,
        };
      }
      return {
        ...base,
        icon: "browser.toolbar.devtools",
        label: t("browser.toolbar.devTools"),
        active: !!button.open,
      };
    case "overflow":
      return { ...base, icon: "action.more.vertical", label: t("browser.toolbar.more") };
  }
}

function chipLabel(strings: Strings, label: ChipLabel | undefined): string | undefined {
  if (!label) return undefined;
  if (typeof label === "object") return label.keyword;
  const keys = {
    notSecure: "pageInfo.chip.notSecure",
    dangerous: "pageInfo.chip.dangerous",
    file: "pageInfo.chip.file",
    product: "pageInfo.chip.product",
  } as const;
  return strings.t(keys[label]);
}

// MARK: Parts

type IconButtonProps = {
  icon: string;
  label: string;
  tooltip?: boolean;
  enabled?: boolean;
  active?: boolean;
  progress?: number;
  onPress: () => void;
  onMenu?: () => void;
  id: string;
  /** The `layout` rect key. */
  rect?: string;
  holdsFocus?: boolean;
  iconSize?: number;
  pressed?: boolean;
  /** The control's accessibility identifier (the DOM id VoiceOver and UI automation read), as the native view's. */
  domId?: string;
  /** A press held `HOLD_MENU_MS` opens `onMenu` instead of pressing (long-press Back and Forward). */
  holdMenu?: boolean;
};

/** How long a press on Back or Forward is held before its history menu opens (ChromeButton's hold timer). */
export const HOLD_MENU_MS = 400;

/**
 * A press held for `HOLD_MENU_MS` opens the button's menu instead of pressing it (ChromeButton's
 * `showHoldMenu`). The timer runs only while the button is held and stops on release, leave or cancel.
 */
export function useHoldMenu(onMenu: (() => void) | undefined, enabled: boolean) {
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const opened = useRef(false);
  const stop = () => {
    if (timer.current !== null) clearTimeout(timer.current);
    timer.current = null;
  };
  useEffect(() => stop, []);
  if (!onMenu || !enabled) return null;
  return {
    onPointerDown: (event: ReactPointerEvent<HTMLButtonElement>) => {
      opened.current = false;
      if (event.button !== 0) return;
      stop();
      timer.current = setTimeout(() => {
        timer.current = null;
        opened.current = true;
        onMenu();
      }, HOLD_MENU_MS);
    },
    onPointerUp: stop,
    onPointerLeave: stop,
    onPointerCancel: stop,
    /** The click that ends a press whose menu opened presses nothing. */
    swallowsClick: () => {
      const swallow = opened.current;
      opened.current = false;
      return swallow;
    },
  };
}

function ToolbarIconButton({
  icon,
  label,
  tooltip,
  enabled = true,
  active,
  progress,
  onPress,
  onMenu,
  id,
  rect,
  holdsFocus,
  iconSize = STANDARD_ICONS.toolbar,
  pressed,
  holdMenu,
  domId,
}: IconButtonProps) {
  const hold = useHoldMenu(holdMenu ? onMenu : undefined, enabled);
  return (
    <button
      type="button"
      id={domId}
      className="bc-button"
      data-toolbar-button={id}
      data-rect={rect ?? id}
      aria-label={label}
      title={tooltip ? label : undefined}
      disabled={!enabled}
      data-active={active || pressed || undefined}
     
      onMouseDown={holdsFocus ? keepFocus : undefined}
      onPointerDown={hold?.onPointerDown}
      onPointerUp={hold?.onPointerUp}
      onPointerLeave={hold?.onPointerLeave}
      onPointerCancel={hold?.onPointerCancel}
      onClick={() => {
        if (!hold?.swallowsClick()) onPress();
      }}
      onContextMenu={
        onMenu
          ? (event) => {
              event.preventDefault();
              onMenu();
            }
          : undefined
      }
    >
      <Icon name={icon} size={iconSize} />
      {progress !== undefined && <ProgressRing value={progress} />}
    </button>
  );
}

/** The ring around Downloads while one runs: filled clockwise from the top, a short arc when unsized. */
function ProgressRing({ value }: { value: number }) {
  const circumference = 2 * Math.PI * 11;
  const fraction = value < 0 ? 0.15 : Math.min(1, value);
  return (
    <svg className="bc-progress-ring" viewBox="0 0 24 24" aria-hidden="true" data-unsized={value < 0 || undefined}>
      <circle cx="12" cy="12" r="11" strokeDasharray={`${fraction * circumference} ${circumference}`} />
    </svg>
  );
}

/** The drag type of a pinned extension moving among the pinned. */
const EXTENSION_DRAG = "application/x-cmux-extension-action";

function ExtensionButton({
  action,
  index,
  send,
  holdsFocus,
  pressed,
}: {
  action: ExtensionAction;
  index: number;
  send: (command: BrowserToolbarCommand) => void;
  holdsFocus?: boolean;
  pressed?: boolean;
}) {
  return (
    <button
      type="button"
      id={`browser.extension.action.${action.id}`}
      className="bc-button bc-extension"
      data-rect={`action:${action.id}`}
      aria-label={extensionLabel(action)}
      title={action.name}
      disabled={action.enabled === false}
      data-active={pressed || undefined}
     
      onMouseDown={holdsFocus ? keepFocusWhileEditing : undefined}
      draggable
      onDragStart={(event) => {
        event.dataTransfer.setData(EXTENSION_DRAG, action.id);
        event.dataTransfer.effectAllowed = "move";
      }}
      onDragOver={(event) => {
        if (!event.dataTransfer.types.includes(EXTENSION_DRAG)) return;
        event.preventDefault();
        event.dataTransfer.dropEffect = "move";
      }}
      onDrop={(event) => {
        const id = event.dataTransfer.getData(EXTENSION_DRAG);
        if (!id) return;
        event.preventDefault();
        if (id !== action.id) send({ type: "moveExtension", id, index });
      }}
      onClick={() => send({ type: "extensionAction", id: action.id })}
      onContextMenu={(event) => {
        event.preventDefault();
        send({ type: "extensionContextMenu", id: action.id });
      }}
    >
      {action.iconUrl ? (
        <img className="bc-extension-icon" src={action.iconUrl} alt="" draggable={false} />
      ) : (
        <span className="bc-extension-icon bc-extension-initial" aria-hidden="true">
          {Array.from(action.name)[0]?.toUpperCase()}
        </span>
      )}
      {/* Chromium's drawing already carries the badge; only the letter fallback draws its own. */}
      {!action.iconUrl && action.badge?.text && (
        <span
          className="bc-extension-badge"
          style={action.badge.color ? ({ "--bc-badge": action.badge.color } as CSSProperties) : undefined}
        >
          {action.badge.text}
        </span>
      )}
    </button>
  );
}

/**
 * What VoiceOver reads for an extension's button: its name, then the badge the icon draws (the
 * native button's accessibility value).
 */
export function extensionLabel(action: ExtensionAction): string {
  const value = action.value || action.badge?.text;
  return value ? `${action.label ?? action.name}, ${value}` : (action.label ?? action.name);
}

/**
 * The drag image of a page dragged out of the chip: its title, else its URL, as one line of the
 * bar's text (PageInfoChipButton's drag image). Laid out off screen for the snapshot, then removed.
 */
export function setChipDragImage(dataTransfer: DataTransfer, chipDrag: { url: string; title: string | null }): void {
  const label = document.createElement("div");
  label.className = "bc-drag-label";
  label.textContent = chipDrag.title?.trim() || chipDrag.url;
  document.body.append(label);
  dataTransfer.setDragImage?.(label, 8, label.offsetHeight / 2);
  setTimeout(() => label.remove(), 0);
}

export function AddressText({
  text,
  host,
  editing,
}: {
  text: string;
  host?: readonly [number, number];
  editing?: boolean;
}) {
  if (editing || !host)
    return (
      <span className="bc-address-text" data-emphasis={editing ? undefined : "none"}>
        {text}
      </span>
    );
  const [start, end] = host;
  return (
    <span className="bc-address-text" data-emphasis="host">
      <span className="bc-dim">{text.slice(0, start)}</span>
      <span className="bc-host">{text.slice(start, end)}</span>
      <span className="bc-dim">{text.slice(end)}</span>
    </span>
  );
}

/** A right-click opens the same menu the press does (the native badges' `menu(for:)`). */
function menuPress(open: () => void) {
  return (event: ReactMouseEvent) => {
    event.preventDefault();
    open();
  };
}

function Badges({
  badges,
  send,
  holdsFocus,
}: {
  badges: OmnibarBadges;
  send: (command: BrowserToolbarCommand) => void;
  holdsFocus?: boolean;
}) {
  const press = holdsFocus ? keepFocus : undefined;
  return (
    <>
      {badges.focusMode && (
        <button
          type="button"
          id="cmux.browser.focusModeBadge"
          className="bc-badge bc-badge-text bc-badge-focus"
          data-rect="badge:focusMode"
          title={badges.focusMode.help}
         
          onMouseDown={press}
          onClick={() => send({ type: "focusModeBadge" })}
        >
          {/* icon-scale-allow: the native badge's 12 pt keyboard glyph (FocusModeBadgeView) */}
          <Icon name="keyboard" size={12} />
          {badges.focusMode.text}
        </button>
      )}
      {badges.profile && (
        <button
          type="button"
          id="cmux.browser.profileBadge"
          className="bc-badge bc-badge-profile"
          data-rect="badge:profile"
          aria-label={badges.profile.help ?? badges.profile.name}
          title={badges.profile.help ?? badges.profile.name}
         
          style={badges.profile.color ? ({ "--bc-profile": badges.profile.color } as CSSProperties) : undefined}
          onMouseDown={press}
          onClick={() => send({ type: "profileBadge" })}
          onContextMenu={menuPress(() => send({ type: "profileBadge" }))}
        >
          {badges.profile.symbol ? (
            <span
              className="bc-badge-symbol"
              aria-hidden="true"
              style={profileSymbolStyle(badges.profile.symbol)}
              data-symbol={badges.profile.monogram}
            />
          ) : (
            badges.profile.monogram
          )}
        </button>
      )}
      {badges.machine && (
        <button
          type="button"
          className="bc-badge bc-badge-text bc-badge-machine"
          data-rect="badge:machine"
          aria-label={badges.machine.help}
          title={badges.machine.help}
         
          onMouseDown={press}
          onClick={() => send({ type: "machineBadge" })}
          onContextMenu={menuPress(() => send({ type: "machineBadge" }))}
        >
          <span className="bc-badge-label">{badges.machine.text}</span>
        </button>
      )}
    </>
  );
}

type OmnibarProps = {
  state: OmnibarState;
  strings: Strings;
  send: (command: BrowserToolbarCommand) => void;
  field?: ReactNode;
  badges?: OmnibarBadges;
  holdsFocus?: boolean;
  onFieldMouseDown?: (event: ReactMouseEvent<HTMLDivElement>) => void;
  chipDrag?: { url: string; title: string | null } | null;
  icons: IconSizes;
};

function Omnibar({
  state,
  strings,
  send,
  field,
  badges,
  holdsFocus,
  onFieldMouseDown,
  chipDrag,
  icons,
}: OmnibarProps) {
  const t = strings.t;
  const label = chipLabel(strings, state.chip.label);
  const surface = state.suggestionsOpen ? "card" : state.editing ? "editing" : "idle";
  const chipName = [t("pageInfo.chip.tooltip"), label].filter(Boolean).join(", ");
  return (
    <div
      className="bc-omnibar"
      data-rect="omnibar"
      data-surface={surface}
      data-upward={state.upward || undefined}
      data-gallery-track
    >
      <button
        type="button"
        className="bc-chip"
        data-rect="chip"
        data-tone={state.chip.tone}
        data-labeled={label ? true : undefined}
        data-pressed={state.pageInfoOpen || undefined}
        aria-label={chipName}
        aria-haspopup="dialog"
        aria-expanded={state.chip.triggerable ? !!state.pageInfoOpen : undefined}
        title={state.chip.triggerable ? t("pageInfo.chip.tooltip") : undefined}
        disabled={!state.chip.triggerable}
       
        // A drag out of the chip needs the press's default; at rest there is no focus to keep.
        onMouseDown={holdsFocus && !chipDrag ? keepFocus : undefined}
        draggable={chipDrag ? true : undefined}
        onDragStart={
          chipDrag
            ? (event) => {
                event.dataTransfer.setData("text/uri-list", chipDrag.url);
                event.dataTransfer.setData("text/plain", chipDrag.url);
                event.dataTransfer.effectAllowed = "copyLink";
                setChipDragImage(event.dataTransfer, chipDrag);
              }
            : undefined
        }
        onClick={() => send({ type: "pageInfo" })}
      >
        <Icon name={state.chip.icon} size={icons.chip} row />
        {label && <span className="bc-chip-label">{label}</span>}
      </button>
      {/* oxlint-disable-next-line jsx-a11y/no-static-element-interactions -- A press around the text goes to the input inside, the field's one control; this wrapper is not a separate control. */}
      <div
        className="bc-field"
        onMouseDown={onFieldMouseDown}
        onPointerDown={onFieldMouseDown || state.editing ? undefined : () => send({ type: "focusAddressBar" })}
      >
        {field ??
          (state.text ? (
            <AddressText text={state.text} host={state.host} editing={state.editing} />
          ) : (
            <span className="bc-address-text bc-placeholder">{t("browser.omnibar.placeholder")}</span>
          ))}
      </div>
      {badges && <Badges badges={badges} send={send} holdsFocus={holdsFocus} />}
      {state.bookmark !== "hidden" && (
        <button
          type="button"
          id="cmux.browser.bookmarkStar"
          className="bc-star"
          data-rect="star"
          data-on={state.bookmark === "on" || undefined}
          aria-label={t(state.bookmark === "on" ? "browser.bookmark.edit" : "browser.bookmark.add")}
          aria-pressed={state.bookmark === "on"}
         
          onMouseDown={holdsFocus ? keepFocus : undefined}
          onClick={() => send({ type: "bookmark" })}
        >
          {/* icon-scale-allow: the star draws at the toolbar glyph side, one ink box with the arrows and the puzzle (OmnibarMetrics.starIconSize) */}
          <Icon
            name={state.bookmark === "on" ? "browser.omnibox.star.active" : "browser.omnibox.star"}
            size={icons.star}
          />
        </button>
      )}
    </div>
  );
}

// MARK: The toolbar

function useWidth(fixed: number | undefined) {
  const ref = useRef<HTMLDivElement>(null);
  const [measured, setMeasured] = useState<number | null>(null);
  useLayoutEffect(() => {
    const node = ref.current;
    if (fixed !== undefined || !node) return;
    // Read before the first paint, so the first frame already has its final layout.
    setMeasured(node.getBoundingClientRect().width);
    const observer = new ResizeObserver(([entry]) => setMeasured(entry.contentRect.width));
    observer.observe(node);
    return () => observer.disconnect();
  }, [fixed]);
  return { ref, width: fixed ?? measured };
}

export function BrowserToolbar({
  navigation,
  omnibar,
  extensions = { shows: false, pinned: [] },
  buttons = [],
  onCommand: send,
  look = "flat",
  width: fixedWidth,
  field,
  strings = toolbarStrings(),
  resolvedButtons,
  metrics,
  layout: givenLayout,
  badges,
  showsButtons = true,
  showsProgress = true,
  holdsFieldFocus,
  onFieldMouseDown,
  chipDrag,
  extensionPressed,
  extensionsPressed,
  extensionsCrashed,
  style,
}: BrowserToolbarProps) {
  const t = strings.t;
  const { ref, width } = useWidth(givenLayout ? 0 : fixedWidth);
  const layout =
    givenLayout ??
    resolveLayout(
      width ?? Number.POSITIVE_INFINITY,
      resolvedButtons ?? buttons,
      extensions.pinned.length,
      extensions.shows,
      metrics,
    );
  const loading = navigation.loading;
  const icons: IconSizes = metrics
    ? { toolbar: metrics.toolbarIcon, chip: metrics.chipIcon, trailing: metrics.trailingIcon, star: metrics.starIcon }
    : STANDARD_ICONS;
  const sizes = metrics ? rowMetricsStyle(metrics) : standardStyle;
  const hold = holdsFieldFocus;
  return (
    <div
      ref={ref}
      className="bc-toolbar"
      role="toolbar"
      data-look={look}
      data-measured={width === null ? undefined : true}
      style={{ ...sizes, ...(fixedWidth === undefined ? null : { width: fixedWidth }), ...style }}
    >
      {showsButtons && (
        <div className="bc-group bc-navigation">
          <ToolbarIconButton
            id="back"
            domId="browser.toolbar.back"
            icon="browser.toolbar.back"
            label={t("browser.toolbar.back")}
            enabled={navigation.canGoBack}
            holdsFocus={hold}
            iconSize={icons.toolbar}
            onPress={() => send({ type: "goBack" })}
            onMenu={() => send({ type: "navigationMenu", direction: "back" })}
            holdMenu
          />
          {layout.showsForward && (
            <ToolbarIconButton
              id="forward"
              domId="browser.toolbar.forward"
              icon="browser.toolbar.forward"
              label={t("browser.toolbar.forward")}
              enabled={navigation.canGoForward}
              holdsFocus={hold}
              iconSize={icons.toolbar}
              onPress={() => send({ type: "goForward" })}
              onMenu={() => send({ type: "navigationMenu", direction: "forward" })}
              holdMenu
            />
          )}
          <ToolbarIconButton
            id="reload"
            domId="browser.toolbar.reload"
            icon={loading ? "browser.toolbar.stop" : "browser.toolbar.reload"}
            label={t(loading ? "browser.toolbar.stop" : "browser.toolbar.reload")}
            enabled={loading || navigation.canReload !== false}
            holdsFocus={hold}
            iconSize={icons.toolbar}
            onPress={() => send({ type: loading ? "stop" : "reload" })}
            onMenu={() => send({ type: "navigationMenu", direction: "reload" })}
          />
        </div>
      )}
      <Omnibar
        state={omnibar}
        strings={strings}
        send={send}
        field={field}
        badges={badges}
        holdsFocus={hold}
        onFieldMouseDown={onFieldMouseDown}
        chipDrag={chipDrag}
        icons={icons}
      />
      {showsButtons && (extensions.shows || extensionsCrashed) && (
        <div className="bc-group bc-extensions">
          {extensions.pinned.slice(0, layout.visiblePinned).map((action, index) => (
            <ExtensionButton
              key={action.id}
              action={action}
              index={index}
              send={send}
              holdsFocus={hold}
              pressed={extensionPressed === action.id}
            />
          ))}
          {extensionsCrashed && (
            <ToolbarIconButton
              id="extensionsCrashed"
              domId="browser.extensions.crashed"
              icon="browser.toolbar.extensions.crashed"
              label={extensionsCrashed.label}
              tooltip
              holdsFocus={hold}
              iconSize={icons.toolbar}
              onPress={() => send({ type: "reloadCrashedExtensions" })}
            />
          )}
          {extensions.shows && (
            <ToolbarIconButton
              id="extensions"
              domId="browser.extensions.button"
              icon="browser.toolbar.extensions"
              label={t("browser.toolbar.extensions")}
              holdsFocus={hold}
              iconSize={icons.toolbar}
              pressed={extensionsPressed}
              onPress={() => send({ type: "extensionsMenu" })}
            />
          )}
        </div>
      )}
      {showsButtons && (
        <div className="bc-group bc-trailing">
          {resolvedButtons
            ? [
                ...visibleButtons(resolvedButtons, layout.collapse),
                ...resolvedButtons.filter((button) => button.id === "overflow"),
              ].map((button) => (
                <ToolbarIconButton
                  key={button.id}
                  id={button.id}
                  domId={`browser.toolbar.${button.id}`}
                  rect={`button:${button.id}`}
                  icon={button.icon}
                  label={button.label}
                  tooltip={button.tooltip}
                  enabled={button.enabled}
                  active={button.active}
                  pressed={button.pressed}
                  progress={button.progress}
                  holdsFocus={hold}
                  iconSize={icons.toolbar}
                  onPress={() => send({ type: "toolbarButton", button: button.id })}
                  onMenu={button.opensMenu ? () => send({ type: "toolbarButton", button: button.id }) : undefined}
                />
              ))
            : shownButtons(buttons, layout.collapse).map((button) => {
                const state = toolbarButtonState(strings, button);
                return (
                  <ToolbarIconButton
                    key={button.id}
                    id={button.id}
                    rect={`button:${button.id}`}
                    {...state}
                    holdsFocus={hold}
                    onPress={() => send({ type: "toolbarButton", button: button.id })}
                  />
                );
              })}
        </div>
      )}
      {showsProgress && (
        <div
          className="bc-progress"
          data-visible={loading || undefined}
          style={{ "--bc-progress": loading ? (navigation.progress ?? 0) : 1 } as CSSProperties}
          aria-hidden="true"
        />
      )}
    </div>
  );
}

/** An SF Symbol profile icon: the host's template image as a mask in the badge's text color. */
export function profileSymbolStyle(symbol: string): CSSProperties {
  const mask = `url("${symbol}") center / contain no-repeat`;
  return { backgroundColor: "currentColor", mask, WebkitMask: mask };
}
