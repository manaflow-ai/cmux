// A card that sits directly under the open Inspector (the computer use live preview,
// computerUse/computerUsePreview.css), as the Codex app stacks its preview under its summary panel.
// The Inspector publishes on the pane's shell where that card goes, and the card publishes the room
// it takes, which the Inspector's height leaves free (inspector.css). Each side measures once per
// resize of its own box (one ResizeObserver), never in a per-frame loop.
import { useLayoutEffect } from "react";

/// The layout's gap between two cards: the card under the Inspector sits this far below it.
export const INSPECTOR_STACK_GAP = 8;

/// The card's place under the panel, in px of the chat stage's own box (the card's containing block):
/// its top the panel's foot plus the gap, less the stage's top in the shell (`stageTop`); its right
/// edge the panel's. Floating, the panel keeps `margin` from the stage's right edge, so the card does
/// too. Pushing, the panel is beside the stage, so the card reaches past the stage's edge by the
/// panel's width.
export function underInspector(
  panel: { top: number; height: number; width: number },
  stageTop: number,
  push: boolean,
  margin: number,
): { top: number; right: number } {
  return {
    top: Math.round(panel.top + panel.height + INSPECTOR_STACK_GAP - stageTop),
    right: push ? -Math.round(panel.width) : margin,
  };
}

/// The room a card under the panel takes from the panel's height: its own height and the gap.
export const underInspectorRoom = (cardHeight: number) => Math.round(cardHeight) + INSPECTOR_STACK_GAP;

const PANEL = ":scope > aside.acpmux-chat-inspector";
const STAGE = ":scope > .acpmux-main > .acpmux-stage";
const TOP = "--acpmux-inspector-under-top";
const RIGHT = "--acpmux-inspector-under-right";
const ROOM = "--acpmux-inspector-under-room";

/// The top of `node` in `shell`'s box, by its offset parents (a translate never moves it).
function topIn(node: HTMLElement, shell: HTMLElement): number {
  let top = 0;
  for (let at: Element | null = node; at && at !== shell; at = (at as HTMLElement).offsetParent) {
    top += (at as HTMLElement).offsetTop;
  }
  return top;
}

/// While the panel is drawn, publishes on `shell` where a card under it goes
/// (--acpmux-inspector-under-top and -right): again when the panel resizes, and when its place
/// (`push`, `under`: its top) changes.
export function useUnderInspector(
  shell: HTMLElement | null | undefined,
  drawn: boolean,
  push: boolean,
  margin: number,
  under?: string,
): void {
  useLayoutEffect(() => {
    const panel = drawn ? shell?.querySelector<HTMLElement>(PANEL) : null;
    if (!shell || !panel) return;
    const publish = () => {
      const stage = shell.querySelector<HTMLElement>(STAGE);
      const place = underInspector(
        { top: panel.offsetTop, height: panel.offsetHeight, width: panel.offsetWidth },
        stage ? topIn(stage, shell) : 0,
        push,
        margin,
      );
      shell.style.setProperty(TOP, `${place.top}px`);
      shell.style.setProperty(RIGHT, `${place.right}px`);
    };
    publish();
    const observer = typeof ResizeObserver === "function" ? new ResizeObserver(publish) : undefined;
    observer?.observe(panel);
    return () => {
      observer?.disconnect();
      shell.style.removeProperty(TOP);
      shell.style.removeProperty(RIGHT);
    };
  }, [shell, drawn, push, margin, under]);
}

/// While `card` shows, publishes on its pane's shell the room it takes under the panel
/// (--acpmux-inspector-under-room), again when it resizes (a frame of another shape, the done state).
export function useUnderInspectorRoom(card: HTMLElement | null): void {
  useLayoutEffect(() => {
    const shell = card?.closest<HTMLElement>(".acpmux-shell");
    if (!card || !shell) return;
    const publish = () => shell.style.setProperty(ROOM, `${underInspectorRoom(card.offsetHeight)}px`);
    publish();
    const observer = typeof ResizeObserver === "function" ? new ResizeObserver(publish) : undefined;
    observer?.observe(card);
    return () => {
      observer?.disconnect();
      shell.style.removeProperty(ROOM);
    };
  }, [card]);
}
