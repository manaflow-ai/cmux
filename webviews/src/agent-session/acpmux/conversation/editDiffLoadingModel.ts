import { useLayoutEffect, useState, type RefObject } from "react";

/// Lines drawn as text while the renderer loads; past this an edit's remaining lines are one block
/// of their unwrapped height, so a huge diff paints a bounded number of nodes.
export const LOADING_TEXT_LINES = 400;

/// Whether the edit's lines under `ref` are drawn: its renderer has mounted something there, and
/// every Pierre host in it has its height (a host is empty for a frame or more after it mounts).
/// Watches only until then: its observers end when it says yes or the card unmounts.
export function useDiffPainted(ref: RefObject<HTMLElement | null>): boolean {
  const [painted, setPainted] = useState(false);
  useLayoutEffect(() => {
    const node = ref.current;
    if (!node || painted) return;
    const hosts = () => [...node.querySelectorAll<HTMLElement>("diffs-container")];
    const drawn = () => node.childElementCount > 0 && hosts().every((host) => host.getBoundingClientRect().height > 0);
    if (drawn()) {
      setPainted(true);
      return;
    }
    const view = node.ownerDocument.defaultView;
    const resize = view?.ResizeObserver ? new view.ResizeObserver(() => drawn() && setPainted(true)) : undefined;
    const watch = () => {
      if (drawn()) setPainted(true);
      else hosts().forEach((host) => resize?.observe(host));
    };
    const added = new (view?.MutationObserver ?? MutationObserver)(watch);
    added.observe(node, { childList: true, subtree: true });
    watch();
    return () => {
      added.disconnect();
      resize?.disconnect();
    };
  }, [ref, painted]);
  return painted;
}
