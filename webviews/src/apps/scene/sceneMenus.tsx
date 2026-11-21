import { useRef, useState, type ReactNode } from "react";
import { Menu, MenuButton, MenuItem, MenuPopup, MenuSeparator, Submenu } from "../../ui/Menu";
import type { NativePopupDescription, NativePopupEvent, NativePopupRow } from "../../ui/nativePopup";
import type { SceneDispatch } from "./SceneRenderer";
import { SceneSymbol } from "./SceneSymbol";
import { sceneRecord, sceneText } from "./sceneStyle";

type Entry = {
  path: number[];
  title: string;
  symbol?: string;
  disabled: boolean;
  destructive: boolean;
  divider: boolean;
  children?: Entry[];
};

function entries(value: unknown, path: number[] = [], depth = 0): Entry[] {
  if (!Array.isArray(value) || depth > 64) return [];
  return value.map((raw, index) => {
    const item = sceneRecord(raw);
    const next = [...path, index];
    return {
      path: next,
      title: sceneText(item.title),
      symbol: typeof item.symbol === "string" ? item.symbol : undefined,
      disabled: item.disabled === true,
      destructive: item.destructive === true,
      divider: item.divider === true,
      ...(Array.isArray(item.children) ? { children: entries(item.children, next, depth + 1) } : {}),
    };
  });
}

function rows(items: Entry[]): NativePopupRow[] {
  return items.map((item) => ({
    id: item.path.join("."),
    kind: item.divider ? "separator" : item.children ? "submenu" : "action",
    label: item.title,
    icon: item.symbol,
    disabled: item.disabled,
    ...(item.children ? { children: rows(item.children) } : {}),
  }));
}

function MenuRows({ items, pick }: { items: Entry[]; pick: (path: number[]) => void }) {
  return items.map((item) => {
    const key = item.path.join(".");
    if (item.divider) return <MenuSeparator key={key} />;
    const label = (
      <>
        {item.symbol ? <SceneSymbol symbol={item.symbol} className="ui-menu-icon" /> : null}
        <span>{item.title}</span>
      </>
    );
    if (item.children)
      return (
        <Submenu key={key} label={label} disabled={item.disabled}>
          <MenuRows items={item.children} pick={pick} />
        </Submenu>
      );
    return (
      <MenuItem
        key={key}
        disabled={item.disabled}
        className={item.destructive ? "cmux-app-scene-menu-danger" : undefined}
        onSelect={() => pick(item.path)}
      >
        {label}
      </MenuItem>
    );
  });
}

function useSceneMenu(value: unknown, node: string, dispatch: SceneDispatch) {
  const items = entries(value);
  const pick = (path: number[]) => dispatch(node, "menu", { path });
  const native: { model: NativePopupDescription; onEvent: (event: NativePopupEvent) => void } = {
    model: { side: "bottom", align: "start", width: 220, rows: rows(items) },
    onEvent(event) {
      if (event.type !== "pick" || !event.id) return;
      const path = event.id.split(".").map(Number);
      let level = items;
      let found: Entry | undefined;
      for (const index of path) {
        found = level.find((item) => item.path[item.path.length - 1] === index);
        if (!found || found.disabled || found.divider) return;
        level = found.children ?? [];
      }
      if (found && !found.children) pick(found.path);
    },
  };
  return { items, pick, native };
}

export function SceneMenu({
  value,
  node,
  dispatch,
  title,
  disabled,
}: {
  value: unknown;
  node: string;
  dispatch: SceneDispatch;
  title: string;
  disabled: boolean;
}) {
  const menu = useSceneMenu(value, node, dispatch);
  return (
    <Menu native={menu.native}>
      <MenuButton className="cmux-app-scene-button" label={title} disabled={disabled}>
        {title}
      </MenuButton>
      <MenuPopup>
        <MenuRows items={menu.items} pick={menu.pick} />
      </MenuPopup>
    </Menu>
  );
}

/** A context menu uses the same nested menu and index paths as a Menu node. Its trigger is anchored
 * at the pointer; closing restores the original control. Both native and page menus share rows. */
export function SceneContextMenu({
  value,
  node,
  dispatch,
  children,
}: {
  value: unknown;
  node: string;
  dispatch: SceneDispatch;
  children: ReactNode;
}) {
  const menu = useSceneMenu(value, node, dispatch);
  const [point, setPoint] = useState<{ x: number; y: number }>();
  const target = useRef<HTMLElement | null>(null);
  return (
    <Menu
      open={point !== undefined}
      onOpenChange={(open) => {
        if (!open) setPoint(undefined);
      }}
      native={menu.native}
    >
      {/* oxlint-disable-next-line jsx-a11y/no-static-element-interactions -- Relays context-menu keys from the focusable scene control inside, as ui/ContextMenu does; this wrapper is not a separate control. */}
      <div
        className="cmux-app-scene-context"
        data-popup-open={point ? "" : undefined}
        onContextMenu={(event) => {
          // An inner scene node owns its own context menu.
          if (event.defaultPrevented || !menu.items.length) return;
          event.preventDefault();
          event.stopPropagation();
          target.current =
            event.target instanceof HTMLElement ? event.target.closest<HTMLElement>("button,input,[tabindex]") : null;
          setPoint({ x: event.clientX, y: event.clientY });
        }}
        onKeyDown={(event) => {
          if (event.key !== "ContextMenu" && !(event.key === "F10" && event.shiftKey)) return;
          event.preventDefault();
          event.stopPropagation();
          target.current = event.target as HTMLElement;
          const box = target.current.getBoundingClientRect();
          setPoint({ x: box.left, y: box.bottom });
        }}
      >
        {children}
      </div>
      {point ? (
        <span className="cmux-app-scene-context-anchor" style={{ left: point.x, top: point.y }} aria-hidden="true">
          <MenuButton className="cmux-app-scene-context-trigger" label="">
            {null}
          </MenuButton>
        </span>
      ) : null}
      <MenuPopup finalFocus={target}>
        <MenuRows items={menu.items} pick={menu.pick} />
      </MenuPopup>
    </Menu>
  );
}
