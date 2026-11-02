import { useEffect, useRef } from "react";
import { ContextMenu, type ContextMenuItem } from "../../ui/ContextMenu";
import { useT, type Translate } from "./i18n";
import { Icon } from "./icons/Icon";
import type { FloatingState } from "./floatingState";
import type { ComposerAttachment } from "./attachments";

/// What the compact bar shows of the chat: working, waiting on the user, or quiet.
export type FloatingStatus = "streaming" | "attention" | "idle";

/// Start Agent's floating chat around its page (cx-b9qi): the App's state and the page's asks.
export interface QuickFloating {
  readonly state: FloatingState;
  readonly status: FloatingStatus;
  readonly title: string;
  /// The reply's last line, for the compact bar.
  readonly line?: string;
  setOnTop(onTop: boolean): void;
  setCollapsed(collapsed: boolean): void;
  moveToTab(): void;
  /// Include focused tab: attaches what the user is looking at in cmux to the next prompt, as a chip.
  includeContext(): void;
}

/// Include focused tab's chip from the App's `quick.context` reply (`{name, text}`), or nothing when
/// the user is looking at nothing it can include. One chip at a time: a newer one replaces it. An
/// untitled tab's chip is named `fallback`.
export function contextAttachment(value: unknown, fallback: string): ComposerAttachment | undefined {
  const raw = (value ?? {}) as { name?: unknown; text?: unknown };
  if (typeof raw.text !== "string" || !raw.text.trim()) return undefined;
  const name = typeof raw.name === "string" && raw.name.trim() ? raw.name : fallback;
  return { id: "floating-context", kind: "text", name, mimeType: "text/plain", size: raw.text.length, text: raw.text };
}

/// The chat's state for the compact bar: an ask waiting on the user comes first, then a turn running.
export function floatingStatus(waiting: boolean, running: boolean): FloatingStatus {
  if (waiting) return "attention";
  return running ? "streaming" : "idle";
}

/// The floating chat's keys while it holds a chat: ⌘J folds it to the compact bar and back, ⌘⇧I
/// includes the focused tab. They are the panel's own, like Return and Escape. ⌘⇧P is not one: it
/// is the app's command palette in every web view (Lawrence 2026-10-19), so the app takes it before
/// the page; Keep on Top is the header's pin button.
export function useFloatingKeys(floating: QuickFloating | undefined) {
  const latest = useRef(floating);
  latest.current = floating;
  const holding = floating?.state.holding === true;
  useEffect(() => {
    if (!holding) return;
    const onKey = (event: KeyboardEvent) => {
      const current = latest.current;
      if (!current || event.isComposing || !event.metaKey || event.altKey || event.ctrlKey) return;
      const key = event.key.toLowerCase();
      if (key === "j" && !event.shiftKey) current.setCollapsed(!current.state.collapsed);
      else if (key === "i" && event.shiftKey && !current.state.collapsed) current.includeContext();
      else return;
      event.preventDefault();
      event.stopPropagation();
    };
    // ui-allow: the floating panel's own window keys (⌘J, ⌘⇧I), wherever focus is in its page, like an app menu key.
    document.addEventListener("keydown", onKey, true);
    return () => document.removeEventListener("keydown", onKey, true);
  }, [holding]);
}

function StatusMark({ status }: { status: FloatingStatus }) {
  const t = useT();
  if (status === "idle") return null;
  const label = t(status === "attention" ? "sidebar.markInput" : "sidebar.markRunning");
  return (
    <span className="acpmux-floating-status" data-status={status} title={label}>
      <span className="acpmux-hidden-label">{label}</span>
    </span>
  );
}

/// The floating chat header's right-click menu: its buttons by name. Only the header has one: the
/// compact bar's panel is 44 pt tall, too short to show a menu drawn in the page.
function floatingMenu(floating: QuickFloating, t: Translate): ContextMenuItem[] {
  const onTop = floating.state.onTop;
  // Every row keeps the check column, so the labels line up whether Keep on top is on or not.
  const row = (label: string, on = false) => (
    <>
      <span className="acpmux-header-customize-check" aria-hidden="true">
        {on ? "✓" : ""}
      </span>
      {label}
    </>
  );
  return [
    { id: "include", label: row(t("floating.includeContext")), onSelect: () => floating.includeContext() },
    {
      id: "onTop",
      label: row(t("floating.keepOnTop"), onTop),
      ariaLabel: t("floating.keepOnTop"),
      onSelect: () => floating.setOnTop(!onTop),
    },
    { id: "collapse", label: row(t("render.collapse")), onSelect: () => floating.setCollapsed(true) },
    { id: "moveToTab", label: row(t("floating.moveToTab")), onSelect: () => floating.moveToTab() },
  ];
}

/// The open floating chat's header: its title, include the focused tab, keep on top, fold to the
/// compact bar, move to a tab.
export function FloatingHeader({ floating }: { floating: QuickFloating }) {
  const t = useT();
  return (
    <ContextMenu className="acpmux-floating-menu-host" items={floatingMenu(floating, t)}>
      <header className="acpmux-floating-header">
        <StatusMark status={floating.status} />
        <span className="acpmux-floating-title">{floating.title}</span>
        <button
          type="button"
          className="acpmux-header-tool"
          aria-label={t("floating.includeContext")}
          title={`${t("floating.includeContext")} ⌘⇧I`}
          onClick={() => floating.includeContext()}
        >
          <Icon name="composer.mention" size={16} />
        </button>
        <button
          type="button"
          className="acpmux-header-tool"
          aria-label={t("floating.keepOnTop")}
          aria-pressed={floating.state.onTop}
          title={t("floating.keepOnTop")}
          onClick={() => floating.setOnTop(!floating.state.onTop)}
        >
          <Icon name="action.pin" size={16} selected={floating.state.onTop} />
        </button>
        <button
          type="button"
          className="acpmux-header-tool"
          aria-label={t("render.collapse")}
          title={`${t("render.collapse")} ⌘J`}
          onClick={() => floating.setCollapsed(true)}
        >
          {/* Folds up into the bar: the chevron points up. */}
          <Icon name="disclosure.expanded" size={16} className="acpmux-icon-flip" />
        </button>
        <button
          type="button"
          className="acpmux-header-tool"
          aria-label={t("floating.moveToTab")}
          title={`${t("floating.moveToTab")} ⌘↩`}
          onClick={() => floating.moveToTab()}
        >
          <Icon name="link.open.newtab" size={16} />
        </button>
      </header>
    </ContextMenu>
  );
}

/// The folded floating chat: one row with the chat's state, title and last line. A click or ⌘J opens it.
export function FloatingCompactBar({ floating }: { floating: QuickFloating }) {
  const t = useT();
  return (
    <div className="acpmux-floating-bar" data-status={floating.status}>
      <button
        type="button"
        className="acpmux-floating-bar-open"
        aria-label={`${t("render.expand")}: ${floating.title}`}
        title={t("render.expand")}
        data-tooltip-shortcut="⌘J"
        onClick={() => floating.setCollapsed(false)}
      >
        <StatusMark status={floating.status} />
        <span className="acpmux-floating-title">{floating.title}</span>
        {floating.line && <span className="acpmux-floating-line">{floating.line}</span>}
      </button>
      <button
        type="button"
        className="acpmux-header-tool"
        aria-label={t("floating.keepOnTop")}
        aria-pressed={floating.state.onTop}
        title={t("floating.keepOnTop")}
        onClick={() => floating.setOnTop(!floating.state.onTop)}
      >
        <Icon name="action.pin" size={16} selected={floating.state.onTop} />
      </button>
    </div>
  );
}
