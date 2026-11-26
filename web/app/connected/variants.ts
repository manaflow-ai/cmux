/**
 * The looks of the "you're signed in, back to cmux" page (`/connected` and the
 * cmux account's after-sign-in page), picked with `?variant=` so they can be
 * compared side by side. One is on by default; an unknown id falls back to it.
 */
export const CONNECTED_PAGE_VARIANTS = [
  { id: "card", label: "Card: app and cmux tiles in a bordered panel" },
  { id: "plain", label: "Plain: the sign-in page's own column" },
  { id: "spotlight", label: "Spotlight: one large app tile with a status badge" },
] as const;

export type ConnectedPageVariant = (typeof CONNECTED_PAGE_VARIANTS)[number]["id"];

export const DEFAULT_CONNECTED_PAGE_VARIANT: ConnectedPageVariant = "card";

export function resolveConnectedPageVariant(raw: string | null | undefined): ConnectedPageVariant {
  const id = raw?.trim().toLowerCase();
  return CONNECTED_PAGE_VARIANTS.find((variant) => variant.id === id)?.id ?? DEFAULT_CONNECTED_PAGE_VARIANT;
}
