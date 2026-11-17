import { ContextMenu, type ContextMenuItem } from "../../ui/ContextMenu";
import { useT, type Translate } from "./i18n";
import { Icon } from "./icons/Icon";
import { type FloatingStatus, type QuickFloating } from "./floatingChatModel";
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
          <Icon name="action.pin" size={16} />
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
        <Icon name="action.pin" size={16} />
      </button>
    </div>
  );
}
