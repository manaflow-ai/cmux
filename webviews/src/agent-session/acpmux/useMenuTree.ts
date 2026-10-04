import type React from "react";
import { useState } from "react";
import { useHoverIntent } from "./useHoverIntent";

/// One row of a layered model menu. A row with `children` or a `panel` opens a submenu on
/// hover (after the intent delay), ArrowRight or, without `run`, a click; `run` is the
/// row's one-click action, which closes the menu unless it returns "keep".
export type MenuNode = {
  key: string;
  label: string;
  /// A mark drawn before the label (a harness's brand mark).
  icon?: React.ReactNode;
  detail?: string;
  /// A key that picks the row (the recents' 1 to 9).
  hint?: string;
  /// Present on choices: whether this is what the session runs.
  checked?: boolean;
  /// A header drawn above the first row of each run of rows with the same section.
  section?: string;
  /// The "More…" row of a folded level.
  more?: boolean;
  children?: MenuNode[];
  /// Submenu content that isn't rows (the effort slider); arrows step it through `step`.
  panel?: React.ReactNode;
  step?(delta: number): void;
  run?(): void | "keep";
  /// The pointer or the arrows came to rest on the row (a harness row's prewarm hint).
  rest?(): void;
};

export type MenuTree = ReturnType<typeof useMenuTree>;

const opens = (node: MenuNode | undefined) => Boolean(node && (node.children?.length || node.panel));

/// The open path and keyboard position of a layered menu, shared by the layouts that draw
/// submenus beside their row (cascade) or above it (the drill). `path[i]` is the row open
/// at level i; `level` is the level the arrows move in. `entry` is the row a submenu's
/// keyboard focus lands on: "last" when submenus list their best row at the bottom.
export function useMenuTree(
  root: MenuNode[],
  {
    entry,
    rootEntry = entry,
    onDone,
    aim,
  }: {
    entry: "first" | "last";
    /// Where the top level's highlight starts when nothing there is checked.
    rootEntry?: "first" | "last";
    onDone(): void;
    aim(level: number): Element | null | undefined;
  },
) {
  const [path, setPath] = useState<string[]>([]);
  const [level, setLevel] = useState(0);
  const [active, setActive] = useState<(string | undefined)[]>([]);
  const intent = useHoverIntent();

  const nodesAt = (at: number): MenuNode[] => {
    let nodes = root;
    for (let index = 0; index < at; index += 1) nodes = nodes.find((node) => node.key === path[index])?.children ?? [];
    return nodes;
  };
  const entryKey = (nodes: MenuNode[]) => (entry === "last" ? nodes.at(-1) : nodes[0])?.key;
  const activeKey = (at: number): string | undefined => {
    const nodes = nodesAt(at);
    const key = active[at];
    if (key && nodes.some((node) => node.key === key)) return key;
    if (at > 0) return undefined;
    return ([...nodes].reverse().find((node) => node.checked) ?? (rootEntry === "last" ? nodes.at(-1) : nodes[0]))?.key;
  };
  const setActiveAt = (at: number, key: string | undefined) => {
    nodesAt(at)
      .find((node) => node.key === key)
      ?.rest?.();
    setActive((list) => {
      const next = list.slice(0, at + 1);
      next[at] = key;
      return next;
    });
  };
  const openAt = (at: number, node: MenuNode, focus: boolean) => {
    setPath((list) => [...list.slice(0, at), node.key]);
    if (!focus) return;
    setLevel(at + 1);
    setActive((list) => {
      const next = list.slice(0, at + 2);
      next[at] = node.key;
      next[at + 1] = entryKey(node.children ?? []);
      return next;
    });
  };
  const closeAt = (at: number) => setPath((list) => list.slice(0, at));

  const run = (node: MenuNode) => {
    if (node.run) {
      if (node.run() !== "keep") onDone();
      return;
    }
    const at = nodesAtLevelOf(node);
    if (at >= 0 && opens(node)) openAt(at, node, true);
  };
  const nodesAtLevelOf = (node: MenuNode) => {
    for (let at = 0; at <= path.length; at += 1) if (nodesAt(at).includes(node)) return at;
    return -1;
  };

  return {
    path,
    level,
    activeKey,
    nodesAt,
    reset() {
      intent.cancel();
      setPath([]);
      setLevel(0);
      setActive([]);
    },
    /// Closes the submenus from level `at` down, as a breadcrumb does.
    collapse(at: number) {
      intent.cancel();
      closeAt(at);
      setLevel((current) => Math.min(current, at));
    },
    track: intent.track,
    cancelHover: intent.cancel,
    /// The pointer entered a row: highlight it now; after the intent delay its submenu opens
    /// (or a sibling's closes), unless the pointer is on its way into the open submenu.
    hover(at: number, node: MenuNode) {
      setActiveAt(at, node.key);
      intent.schedule(
        () => {
          setLevel(at);
          if (opens(node)) openAt(at, node, false);
          else closeAt(at);
        },
        () => aim(at),
      );
    },
    click(node: MenuNode) {
      intent.cancel();
      run(node);
    },
    /// Arrows, Return, and Escape as a step back. Returns false for keys it leaves to the layout
    /// (Escape at the top level, typing).
    keyDown(event: React.KeyboardEvent): boolean {
      const nodes = nodesAt(level);
      const parent = level > 0 ? nodesAt(level - 1).find((node) => node.key === path[level - 1]) : undefined;
      if (parent?.panel && !parent.children?.length) {
        // Inside a slider panel the arrows step it.
        if (event.key === "ArrowRight" || event.key === "ArrowUp") parent.step?.(1);
        else if (event.key === "ArrowLeft" || event.key === "ArrowDown") parent.step?.(-1);
        else if (event.key === "Escape" || event.key === "Enter") {
          setLevel(level - 1);
          closeAt(level - 1);
        } else return false;
        event.preventDefault();
        return true;
      }
      const key = activeKey(level);
      const index = nodes.findIndex((node) => node.key === key);
      const node = nodes[index];
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        if (nodes.length === 0) return true;
        const step = event.key === "ArrowDown" ? 1 : -1;
        const from = index < 0 ? (step > 0 ? -1 : nodes.length) : index;
        setActiveAt(level, nodes[(from + step + nodes.length) % nodes.length]!.key);
      } else if (event.key === "ArrowRight") {
        if (!node || !opens(node)) return true;
        openAt(level, node, true);
      } else if (event.key === "ArrowLeft") {
        if (level === 0) return path.length > 0 ? (closeAt(0), true) : true;
        setLevel(level - 1);
        closeAt(level - 1);
      } else if (event.key === "Enter") {
        if (node) run(node);
      } else if (event.key === "Escape") {
        if (level > 0) {
          setLevel(level - 1);
          closeAt(level - 1);
        } else if (path.length > 0) closeAt(0);
        else return false;
      } else return false;
      event.preventDefault();
      return true;
    },
  };
}
