/// Focus with an explicit focus-ring choice. `focusVisible` (HTML FocusOptions) says whether the
/// browser draws the focus ring for a programmatic focus; TypeScript's DOM lib does not know the
/// member yet, so this one helper carries the type for every caller.
export type FocusRingOptions = FocusOptions & { focusVisible?: boolean };

export function focusWithRing(element: HTMLElement | null | undefined, options?: FocusRingOptions): void {
  element?.focus(options);
}
