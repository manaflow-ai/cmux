import { createContext, use } from "react";

/**
 * The element a menu draws in to leave every backdrop root around `from` (Filter Effects 2: an
 * ancestor with a backdrop-filter, filter, mask, clip-path, opacity under 1 or a blend mode). Inside
 * one, a popup's own backdrop-filter sees only that root's content: the composer's glass box is one,
 * so the + menu's glass showed the project and machine pills behind the composer through it sharp
 * (Leo, 2026-10-31: "our + button is ass"). The parent of the outermost root inside the pane's shell
 * (`.acpmux-shell`, which carries the menu's colour tokens; the body on a page without one), or null
 * when there is none (the menu then stays beside its button).
 */
export function backdropLayer(from: Element | null): HTMLElement | null {
  const view = from?.ownerDocument.defaultView;
  if (!from || !view) return null;
  const shell = from.closest(".acpmux-shell") ?? from.ownerDocument.body;
  let outermost: Element | null = null;
  for (let node = from.parentElement; node && node !== shell; node = node.parentElement)
    if (isBackdropRoot(view.getComputedStyle(node))) outermost = node;
  return outermost?.parentElement ?? null;
}

/** Whether an element with this style is a backdrop root (Filter Effects 2). */
export function isBackdropRoot(style: CSSStyleDeclaration): boolean {
  const set = (value: string | undefined) => !!value && value !== "none";
  const backdrop = style.backdropFilter || style.getPropertyValue("-webkit-backdrop-filter");
  const mask = style.maskImage || style.getPropertyValue("-webkit-mask-image");
  const opacity = Number.parseFloat(style.opacity);
  return (
    set(backdrop) ||
    set(style.filter) ||
    set(mask) ||
    set(style.clipPath) ||
    (Number.isFinite(opacity) && opacity < 1) ||
    (!!style.mixBlendMode && style.mixBlendMode !== "normal")
  );
}

// The composer's `/` and `@` lists (SlashMenu, MentionMenu) float above its box, over the
// transcript. The box is glass (`.ui-glass`) and so a backdrop root: a list drawn inside it frosted
// the box alone, and the transcript read sharp through it, where the mode and model menus (portaled
// out) frost it. So a list draws out of the box, in a layer outside every backdrop root around it
// (backdropLayer, as the + menu does), kept on the box's place and size: the list's own CSS
// (styles.css `.acpmux-slash-menu`: 6 px above, the box's edges, its height cap) places it as
// before. The layer stays in the composer, so its colour tokens and rules still reach the rows.
// Not the page's portal container (UiProvider): that sits outside `.acpmux-shell` and its tokens.

export const ListAnchor = createContext<{ box: HTMLElement | null; inert: boolean }>({ box: null, inert: false });

/** The box the lists float above, or null outside a composer (a gallery card, a unit test). */
export function useComposerListBox(): HTMLElement | null {
  return use(ListAnchor).box;
}
