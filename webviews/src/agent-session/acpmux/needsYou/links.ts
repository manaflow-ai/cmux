// An agent points at an open ask instead of restating it: `cmux://needs-you/<permissionId>` (any
// build's scheme), the id `acpmux pending --json` prints as `needsYou`. In a reply it draws as a
// chip (conversation/Markdown.tsx) that opens the header's Needs you list on that ask; the page
// handles it, so the link never leaves the pane.
import { askItemId } from "./model";

/// What a permission id may hold in a link (acpmux ids are UUIDs; DeepLink's token rule).
const TOKEN = /^[A-Za-z0-9._-]{1,200}$/;
const LINK = /^cmux(?:-[a-z0-9-]+)?:\/\/needs-you\/([^/?#]+)$/;

/// The Needs you item a link names, or undefined for any other text.
export function needsYouTarget(href: string): string | undefined {
  const id = LINK.exec(href.trim())?.[1];
  return id && TOKEN.test(id) ? askItemId(id) : undefined;
}

/// The link for an ask, in `scheme` (the build's, links.ts `linkScheme`).
export function needsYouLink(permissionId: string, scheme = "cmux"): string | undefined {
  return TOKEN.test(permissionId) ? `${scheme}://needs-you/${permissionId}` : undefined;
}

/// Whether the header's list is off (data-needs-you="off" on <html>: the Debug choice, or the App
/// Store's Needs You item not installed); a link then draws as its text. NeedsYou.tsx `needsYouMode`
/// reads the same attribute; this one stays here so a reply's Markdown does not load the list.
export function needsYouListOff(
  root: { dataset: DOMStringMap } | undefined = globalThis.document?.documentElement,
): boolean {
  return root?.dataset.needsYou === "off";
}

type Opener = (itemId?: string) => void;
const openers = new Set<Opener>();

/// The header's list registers here while it is mounted; it opens on the item asked for.
export function onOpenNeedsYou(opener: Opener): () => void {
  openers.add(opener);
  return () => void openers.delete(opener);
}

/// Opens the Needs you list, on `itemId` when given. False when no list is mounted (the toggle is
/// off, or the page has no header).
export function openNeedsYou(itemId?: string): boolean {
  for (const opener of openers) opener(itemId);
  return openers.size > 0;
}
