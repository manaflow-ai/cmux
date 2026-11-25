// Focus-visible inside a part, as a state the part's owner writes (`data-focused`), never a wide
// `:has(:focus-visible)` (transcript-motion-model step 7, invariant I8). A `:has()` whose subject is
// the composer form, the card, the dock or `body` was checked again for every node a keystroke or
// a streamed chunk inserted under it; the attribute changes only when focus does.
//
// Only one element of a document matches `:focus-visible`, the focused one, so `X:has(:focus-visible)`
// is "the active element is a descendant of X and matches `:focus-visible`". The watch reads exactly
// that on each focus change (`focusin`, `focusout`, the window's `focus` and `blur`), and again on a
// key press, since a key can turn a pointer-placed focus visible. It calls `onChange` only when the
// answer changes: a keystroke writes nothing.

/// Whether a descendant of `scope` (not `scope` itself, as `:has()` reads) is focused and matches
/// `:focus-visible`.
export function focusVisibleWithin(scope: Element): boolean {
  const active = scope.ownerDocument.activeElement;
  if (!active || active === scope || !scope.contains(active)) return false;
  try {
    return active.matches(":focus-visible");
  } catch {
    // An engine without `:focus-visible` (jsdom before 22) reads focus alone.
    return active.matches(":focus");
  }
}

/// Watches focus-visible within `scope`; `onChange` gets the first answer at once, then each change.
/// Returns the unsubscribe.
export function watchFocusVisible(scope: HTMLElement, onChange: (focused: boolean) => void): () => void {
  const view = scope.ownerDocument.defaultView;
  let focused = focusVisibleWithin(scope);
  onChange(focused);
  const check = () => {
    const next = focusVisibleWithin(scope);
    if (next === focused) return;
    focused = next;
    onChange(next);
  };
  // `focusout` runs while the active element is still the old one: read once focus has landed.
  const checkAfterMove = () => queueMicrotask(check);
  scope.addEventListener("focusin", check);
  scope.addEventListener("focusout", checkAfterMove);
  scope.addEventListener("keydown", check, true);
  view?.addEventListener("focus", check);
  view?.addEventListener("blur", check);
  return () => {
    scope.removeEventListener("focusin", check);
    scope.removeEventListener("focusout", checkAfterMove);
    scope.removeEventListener("keydown", check, true);
    view?.removeEventListener("focus", check);
    view?.removeEventListener("blur", check);
  };
}
