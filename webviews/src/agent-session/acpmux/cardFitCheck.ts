// The geometry check of Leo's card rule (conversation/cardFit.css, 2026-11-22: "overlapping text via
// the buttosn when the pane is small"): no text run under a button, no button over another, nothing
// past the card's right edge. No imports, so a browser test can import it and run it in any gallery
// stage as `(${cardFitProblems})(document)`; cardFit.gallery.ts runs it in its plays.

/** The cards the check reads: every `.cv-fit` card, and the cards that predate it. */
export const CARD_FIT_CARDS =
  ".cv-fit, .acpmux-edited, .acpmux-permission-card, .ui-notice, .acpmux-agent-line, .acpmux-bg-card, .acpmux-trust-ask";

/**
 * The places a card's text runs under one of its buttons, its buttons overlap, or either leaves the
 * card past its right edge; empty when every card on the page holds at this width. Self-contained
 * (no imports, no helpers outside it) so a browser test can run it in any gallery stage as
 * `(${cardFitProblems})(document)`.
 */
export function cardFitProblems(doc: Document): string[] {
  const view = doc.defaultView!;
  const CARDS =
    ".cv-fit, .acpmux-edited, .acpmux-permission-card, .ui-notice, .acpmux-agent-line, .acpmux-bg-card, .acpmux-trust-ask";
  const CONTROL = "button, a[href], [role='button']";
  const TEXT_IN_CONTROL = "button, a, [role='button'], input, textarea, select";
  // An open menu or tooltip floats over the card by design; the stage judges popups itself.
  const POPUP = ".ui-popup, .acpmux-mp, [role='menu'], [role='dialog'], [role='tooltip'], [role='listbox']";
  type Box = { left: number; top: number; right: number; bottom: number };
  const problems = new Set<string>();

  const clips = (element: Element) => {
    const style = view.getComputedStyle(element);
    return style.overflowX !== "visible" || style.overflowY !== "visible" || style.contain.includes("paint");
  };
  const intersect = (a: Box, b: Box): Box => ({
    left: Math.max(a.left, b.left),
    top: Math.max(a.top, b.top),
    right: Math.min(a.right, b.right),
    bottom: Math.min(a.bottom, b.bottom),
  });
  const empty = (box: Box) => box.right - box.left < 0.5 || box.bottom - box.top < 0.5;
  // A box clipped by every ancestor between it and the card (the card's own clip excluded, so a run
  // past its edge still shows as past it).
  const clipped = (start: Element | null, card: Element, box: Box): Box | undefined => {
    let out = box;
    for (let at = start; at && at !== card; at = at.parentElement) {
      if (!clips(at)) continue;
      out = intersect(out, at.getBoundingClientRect());
      if (empty(out)) return undefined;
    }
    return empty(out) ? undefined : out;
  };
  // Hidden for a reader: display none, visibility hidden, opacity 0, or clipped away (a screen-reader
  // only span's `clip-path: inset(50%)` or `clip: rect(0 0 0 0)`) on it or an ancestor in the card.
  const hidden = (element: Element, card: Element, opacityCounts: boolean) => {
    for (let at: Element | null = element; at; at = at.parentElement) {
      const style = view.getComputedStyle(at);
      if (style.display === "none" || style.visibility === "hidden" || style.visibility === "collapse") return true;
      if (opacityCounts && Number(style.opacity) === 0) return true;
      if (style.clipPath.startsWith("inset(50%") || (style.position === "absolute" && style.clip.startsWith("rect(0")))
        return true;
      if (at === card) break;
    }
    return false;
  };
  const overlap = (a: Box, b: Box) =>
    Math.min(a.right, b.right) - Math.max(a.left, b.left) > 1 &&
    Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top) > 1;
  const within = (inner: Box, outer: Box) =>
    inner.left >= outer.left - 1 &&
    inner.right <= outer.right + 1 &&
    inner.top >= outer.top - 1 &&
    inner.bottom <= outer.bottom + 1;
  const snippet = (text: string) => {
    const one = text.replace(/\s+/g, " ").trim();
    return one.length > 40 ? `${one.slice(0, 39)}…` : one;
  };
  const label = (control: Element) =>
    snippet(
      control.getAttribute("aria-label") ||
        control.getAttribute("title") ||
        control.textContent ||
        control.className.toString() ||
        control.tagName.toLowerCase(),
    );
  const name = (card: Element) => {
    const known = CARDS.split(", ")
      .map((selector) => selector.slice(1))
      .filter((cls) => card.classList.contains(cls) && cls !== "cv-fit");
    const first = known[0] ?? [...card.classList].find((cls) => cls !== "cv-fit") ?? card.tagName.toLowerCase();
    return card.classList.contains("cv-fit") && known.length === 0 ? `${first}.cv-fit` : first;
  };
  const px = (value: number) => Math.round(value);

  for (const card of doc.querySelectorAll(CARDS)) {
    if (card.closest(POPUP)) continue;
    const box = card.getBoundingClientRect();
    if (box.width === 0 || box.height === 0 || hidden(card, card, false)) continue;
    const cardName = name(card);

    // The innermost controls: a chip's wrapper and its button are one control.
    const controls: { control: Element; rect: Box }[] = [];
    for (const control of card.querySelectorAll(CONTROL)) {
      if (control.querySelector(CONTROL) || control.closest(POPUP) || hidden(control, card, false)) continue;
      const own = control.getBoundingClientRect();
      if (own.width === 0 || own.height === 0) continue;
      const rect = clipped(control.parentElement, card, own);
      if (rect) controls.push({ control, rect });
    }

    // Visible text runs, one rect per line box, each with the control it is the label of (if any):
    // a run is checked against every other control, so a row-wide button whose trailing track
    // another button lies over (a subagent line's Stop) is judged by its words, not its box.
    const texts: { text: string; rect: Box; owner: Element | null }[] = [];
    const walker = doc.createTreeWalker(card, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const text = node.textContent ?? "";
      if (!text.trim()) continue;
      const parent = node.parentElement;
      if (!parent || parent.closest(POPUP) || hidden(parent, card, true)) continue;
      const owner = parent.closest(TEXT_IN_CONTROL);
      if (owner && !card.contains(owner)) continue;
      const range = doc.createRange();
      range.selectNodeContents(node);
      for (const own of range.getClientRects()) {
        if (own.width < 0.5 || own.height < 0.5) continue;
        const rect = clipped(parent, card, own);
        if (rect) texts.push({ text, rect, owner });
      }
    }

    for (const { text, rect, owner } of texts) {
      if (rect.right > box.right + 1)
        problems.add(
          `${cardName}: “${snippet(text)}” runs past the card's right edge (${px(rect.right)} > ${px(box.right)})`,
        );
      for (const { control, rect: other } of controls)
        if (
          owner !== control &&
          !control.contains(owner) &&
          !(owner && owner.contains(control)) &&
          overlap(rect, other)
        )
          problems.add(`${cardName}: “${snippet(text)}” runs under the “${label(control)}” button`);
    }
    for (let i = 0; i < controls.length; i++) {
      const { control, rect } = controls[i]!;
      if (rect.right > box.right + 1)
        problems.add(
          `${cardName}: the “${label(control)}” button leaves the card (${px(rect.right)} > ${px(box.right)})`,
        );
      for (let j = i + 1; j < controls.length; j++)
        // One box wholly inside the other is a button laid over a track its row keeps for it; its
        // words are what must not collide, and the text check above judges those.
        if (overlap(rect, controls[j]!.rect) && !within(rect, controls[j]!.rect) && !within(controls[j]!.rect, rect))
          problems.add(`${cardName}: the “${label(control)}” button overlaps “${label(controls[j]!.control)}”`);
    }
  }
  return [...problems];
}
