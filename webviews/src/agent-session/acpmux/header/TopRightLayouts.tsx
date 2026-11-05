// The chat header's top-right icons in the consolidated layouts (Debug Settings
// `agentChat.topRight.consolidate`, topRightLayout.ts), in place of today's row while one is chosen:
//
// - Morph: one control. A click expands it in place, leftward, into the set (Arc's and Safari's collapsed toolbars,
//   Xcode's inspector toggles); a pick closes the set and the icon you clicked becomes the control,
//   lit, for as long as its pane is open, as it becomes that pane's tab. Its glyph flies from the
//   picked spot into the control and on toward the right pane.
// - Tab strip: today's row while nothing is open beside the chat; once a pane is, its icon draws as
//   a tab at the header's trailing edge, against the right pane's own tab strip (Chrome's tab feet),
//   and the rest sit after it, quiet.
// - Dock: one recent-panes button, as a browser's recent tabs: open panes first, then recent, then
//   the rest; a badge counts the open ones.
//
// Every move is in the `web` motion category: the CSS runs on the pane's motion tokens (0 with
// animation off, data-cmux-motion), and the one scripted glide asks motionMode() first, so with
// animation off each change lands in one frame and every handler still runs.
import { useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore, type CSSProperties, type RefObject } from "react";
import { useT } from "../i18n";
import { tooltipProps } from "../shortcuts";
import { Menu, MenuButton, MenuGroup, MenuItem, MenuPopup } from "../../../ui/Menu";
import { motionMode } from "../../../ui/motion/motionMode";
import { HeaderIcon } from "./HeaderIcon";
import type { HeaderQuickTool } from "./headerQuickTools";
import type { QuickActionId } from "./quickActions";
import {
  dockSections,
  morphFace,
  notePaneOpened,
  openTools,
  recentPanes,
  subscribeRecentPanes,
  type TopRightLayout,
} from "./topRightLayout";
import "./topRight.css";

const GLYPH = 16;

type Shortcuts = Partial<Record<QuickActionId, string | undefined>>;

export function TopRightLayouts({
  layout,
  tools,
  shortcuts,
}: {
  layout: Exclude<TopRightLayout, "row">;
  tools: readonly HeaderQuickTool[];
  shortcuts: Shortcuts;
}) {
  const order = useSyncExternalStore(subscribeRecentPanes, recentPanes, recentPanes);
  if (layout === "morph") return <MorphControl tools={tools} order={order} shortcuts={shortcuts} />;
  if (layout === "tabStrip") return <TabStripTools tools={tools} order={order} shortcuts={shortcuts} />;
  return <DockButton tools={tools} order={order} shortcuts={shortcuts} />;
}

/// Runs a pick and remembers it, so the morph face and the dock's Recent follow.
const runTool = (tool: HeaderQuickTool) => {
  tool.run?.();
  notePaneOpened(tool.id);
};

/// The pane's motion token in ms (0 with animation off).
function motionMs(element: Element, token = "--agent-motion-in"): number {
  const view = element.ownerDocument.defaultView;
  const raw = view?.getComputedStyle(element).getPropertyValue(token).trim() ?? "";
  // No token (a page outside the app): the scale's standard step. Motion off is a 0 token, which
  // motionMode() already reads as "none".
  const value = Number.parseFloat(raw);
  if (!Number.isFinite(value)) return 120;
  return raw.endsWith("ms") ? value : raw.endsWith("s") ? value * 1000 : value;
}

/// The picked glyph glides from where it was picked into the control, then a little on toward the
/// right pane, and fades: the icon you click becomes the control (and the pane's tab). `web`
/// category: none with animation off or a hidden page; with Reduce Motion it only fades.
function glide(from: Element | null, to: Element | null) {
  if (!from || !to) return;
  const mode = motionMode(from.ownerDocument);
  if (mode === "none") return;
  const glyph = from.querySelector(".acpmux-header-glyph");
  if (!glyph) return;
  const start = glyph.getBoundingClientRect();
  const end = to.getBoundingClientRect();
  const ghost = glyph.cloneNode(true) as HTMLElement;
  ghost.classList.add("acpmux-topright-ghost");
  Object.assign(ghost.style, { left: `${start.left}px`, top: `${start.top}px`, width: `${start.width}px`, height: `${start.height}px` });
  from.ownerDocument.body.append(ghost);
  const dx = end.left + (end.width - start.width) / 2 - start.left;
  const dy = end.top + (end.height - start.height) / 2 - start.top;
  const ms = Math.max(motionMs(to) * 2, 1);
  const frames: Keyframe[] =
    mode === "reduced"
      ? [{ opacity: 1 }, { opacity: 0 }]
      : [
          { transform: "translate(0, 0)", opacity: 1 },
          { transform: `translate(${dx}px, ${dy}px)`, opacity: 1, offset: 0.7 },
          { transform: `translate(${dx + 12}px, ${dy}px)`, opacity: 0 },
        ];
  const run = ghost.animate(frames, { duration: ms, easing: "cubic-bezier(0.2, 0, 0, 1)" });
  const done = () => ghost.remove();
  run.onfinish = done;
  run.oncancel = done;
}

/// FLIP for the strip: a tool that changes place (a pane opens and its icon becomes a tab) glides
/// from its old spot. `web` category, as `glide`.
function useFlip(container: RefObject<HTMLElement | null>, key: string) {
  const rects = useRef(new Map<string, DOMRect>());
  useLayoutEffect(() => {
    const root = container.current;
    if (!root) return;
    const mode = motionMode(root.ownerDocument);
    const next = new Map<string, DOMRect>();
    for (const item of root.querySelectorAll<HTMLElement>("[data-quick-action]")) {
      const id = item.dataset.quickAction!;
      const rect = item.getBoundingClientRect();
      next.set(id, rect);
      const before = rects.current.get(id);
      if (!before || mode !== "full") continue;
      const dx = before.left - rect.left;
      if (Math.abs(dx) < 1) continue;
      item.animate([{ transform: `translateX(${dx}px)` }, { transform: "translateX(0)" }], {
        duration: Math.max(motionMs(item), 1),
        easing: "cubic-bezier(0.2, 0, 0, 1)",
      });
    }
    rects.current = next;
  }, [container, key]);
}

function ToolButton({
  tool,
  shortcut,
  className = "",
  tabIndex,
  onPick,
  index,
}: {
  tool: HeaderQuickTool;
  shortcut?: string;
  className?: string;
  tabIndex?: number;
  onPick: (tool: HeaderQuickTool, button: HTMLButtonElement) => void;
  index?: number;
}) {
  return (
    <button
      type="button"
      data-quick-action={tool.id}
      className={`acpmux-header-tool ${className}`.trim()}
      aria-label={tool.label}
      aria-pressed={tool.pressed}
      tabIndex={tabIndex}
      style={index === undefined ? undefined : ({ "--acpmux-topright-i": index } as CSSProperties)}
      {...tooltipProps(tool.title ?? tool.label, tool.title ? undefined : shortcut)}
      onClick={(event) => onPick(tool, event.currentTarget)}
    >
      <HeaderIcon name={tool.icon} size={GLYPH} selected={tool.pressed === true} />
    </button>
  );
}

function MorphControl({
  tools,
  order,
  shortcuts,
}: {
  tools: readonly HeaderQuickTool[];
  order: readonly QuickActionId[];
  shortcuts: Shortcuts;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const root = useRef<HTMLDivElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  // Opened from the keyboard (a click with no pointer detail): the set's first icon takes focus.
  const byKeyboard = useRef(false);
  const face = morphFace(tools, order);
  const openCount = openTools(tools, order).length;
  useEffect(() => {
    if (!open) return;
    const doc = root.current?.ownerDocument;
    const away = (event: PointerEvent) => {
      if (!root.current?.contains(event.target as Node)) setOpen(false);
    };
    doc?.addEventListener("pointerdown", away, true);
    // From the keyboard, the set's first icon takes focus, as a toolbar's does.
    if (byKeyboard.current)
      root.current?.querySelector<HTMLButtonElement>(".acpmux-topright-morph-set button")?.focus({ preventScroll: true });
    return () => doc?.removeEventListener("pointerdown", away, true);
  }, [open]);
  const pick = (tool: HeaderQuickTool, button: HTMLButtonElement) => {
    runTool(tool);
    setOpen(false);
    glide(button, trigger.current);
    if (byKeyboard.current) trigger.current?.focus({ preventScroll: true });
  };
  const label = t("header.topRight.panes");
  return (
    <div
      ref={root}
      className="acpmux-topright-morph"
      data-open={open || undefined}
      onKeyDown={(event) => {
        if (event.key !== "Escape" || !open) return;
        event.preventDefault();
        event.stopPropagation();
        setOpen(false);
        trigger.current?.focus({ preventScroll: true });
      }}
    >
      <div
        className="acpmux-topright-morph-set"
        role="toolbar"
        aria-label={label}
        aria-hidden={!open}
        inert={!open}
        style={{ "--acpmux-topright-n": tools.length } as CSSProperties}
      >
        {tools.map((tool, index) => (
          <ToolButton
            key={tool.id}
            tool={tool}
            shortcut={shortcuts[tool.id]}
            index={tools.length - index}
            tabIndex={open ? 0 : -1}
            onPick={pick}
          />
        ))}
      </div>
      <button
        ref={trigger}
        type="button"
        className="acpmux-header-tool acpmux-topright-morph-trigger"
        aria-label={face ? `${label}: ${face.label}` : label}
        aria-expanded={open}
        aria-pressed={face ? true : undefined}
        data-face={face?.id ?? "panes"}
        {...tooltipProps(face ? face.label : label, undefined)}
        onClick={(event) => {
          byKeyboard.current = event.detail === 0;
          setOpen(!open);
        }}
      >
        <span className="acpmux-topright-face" key={face?.id ?? "panes"}>
          <HeaderIcon name={face?.icon ?? "tunable.sidebar"} size={GLYPH} selected={face !== undefined} />
        </span>
        {openCount > 1 && (
          <span className="acpmux-topright-count" aria-hidden="true">
            {openCount}
          </span>
        )}
      </button>
    </div>
  );
}

function TabStripTools({
  tools,
  order,
  shortcuts,
}: {
  tools: readonly HeaderQuickTool[];
  order: readonly QuickActionId[];
  shortcuts: Shortcuts;
}) {
  const root = useRef<HTMLDivElement>(null);
  const open = openTools(tools, order);
  const docked = open.length > 0;
  const rest = tools.filter((tool) => !tool.pressed);
  useFlip(root, `${docked}:${open.map((tool) => tool.id).join()}`);
  const pick = (tool: HeaderQuickTool) => runTool(tool);
  return (
    <div ref={root} className="acpmux-topright-strip" data-docked={docked || undefined}>
      {docked ? (
        <>
          <div className="acpmux-topright-strip-rest">
            {rest.map((tool) => (
              <ToolButton key={tool.id} tool={tool} shortcut={shortcuts[tool.id]} onPick={pick} />
            ))}
          </div>
          <div className="acpmux-topright-strip-tabs">
            {open.map((tool) => (
              <ToolButton
                key={tool.id}
                tool={tool}
                shortcut={shortcuts[tool.id]}
                className="acpmux-topright-tab"
                onPick={pick}
              />
            ))}
          </div>
        </>
      ) : (
        tools.map((tool) => <ToolButton key={tool.id} tool={tool} shortcut={shortcuts[tool.id]} onPick={pick} />)
      )}
    </div>
  );
}

function DockButton({
  tools,
  order,
  shortcuts,
}: {
  tools: readonly HeaderQuickTool[];
  order: readonly QuickActionId[];
  shortcuts: Shortcuts;
}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const sections = dockSections(tools, order);
  const label = t("header.topRight.recentPanes");
  const rows = (list: readonly HeaderQuickTool[]) =>
    list.map((tool) => (
      <MenuItem
        key={tool.id}
        className="acpmux-chat-menu-item acpmux-topright-dock-row"
        disabled={!tool.run}
        onSelect={() => runTool(tool)}
      >
        <span className="acpmux-topright-dock-glyph" data-on={tool.pressed || undefined}>
          <HeaderIcon name={tool.icon} size={14} selected={tool.pressed === true} />
        </span>
        <span className="acpmux-chat-menu-label">{tool.title ?? tool.label}</span>
        {shortcuts[tool.id] && <kbd className="acpmux-chat-menu-key">{shortcuts[tool.id]}</kbd>}
      </MenuItem>
    ));
  return (
    <Menu open={open} onOpenChange={setOpen}>
      <MenuButton
        className="acpmux-header-tool acpmux-topright-dock"
        label={label}
        title={label}
        data-menu="recent-panes"
      >
        <HeaderIcon name="history.recent" size={GLYPH} selected={sections.open.length > 0} />
        {sections.open.length > 0 && (
          <span className="acpmux-topright-count" aria-hidden="true">
            {sections.open.length}
          </span>
        )}
      </MenuButton>
      <MenuPopup className="acpmux-chat-menu-popover acpmux-topright-dock-popover" align="end">
        {sections.open.length > 0 && <MenuGroup label={t("header.topRight.openNow")}>{rows(sections.open)}</MenuGroup>}
        {sections.recent.length > 0 && <MenuGroup label={t("header.topRight.recent")}>{rows(sections.recent)}</MenuGroup>}
        {sections.more.length > 0 && <MenuGroup label={t("header.topRight.more")}>{rows(sections.more)}</MenuGroup>}
      </MenuPopup>
    </Menu>
  );
}
