// Contacts directory for New Message: recipient autocomplete, handle lookup
// (iMessage vs SMS availability) and participant resolution. See PROTOCOL.md.

export type Service = "iMessage" | "SMS";

export interface Handle {
  value: string; // as displayed: "+1 (555) 564-8583", "kate-bell@mac.com"
  label: string; // "mobile", "home", "work", "iPhone"
  service: Service;
}

export interface Contact {
  id: string;
  name: string;
  initials: string;
  colorHex: string;
  handles: Handle[];
}

const phone = (value: string, label: string, service: Service = "iMessage"): Handle => ({ value, label, service });
const email = (value: string, label: string, service: Service = "iMessage"): Handle => ({ value, label, service });

/** Ids of the people who already share the hosted conversations match server.ts participants. */
export const CONTACTS: Contact[] = [
  { id: "lawrence", name: "Lawrence Chen", initials: "LC", colorHex: "#FF9F0A", handles: [phone("+1 (415) 555-0132", "mobile"), email("lawrence@cmux.dev", "work")] },
  { id: "austin", name: "Austin Wang", initials: "AW", colorHex: "#30D158", handles: [phone("+1 (415) 555-0178", "mobile"), email("austin@cmux.dev", "work")] },
  { id: "leo", name: "Leo Li", initials: "LL", colorHex: "#BF5AF2", handles: [phone("+1 (650) 555-0144", "iPhone"), email("leo@cmux.dev", "work")] },
  { id: "john", name: "John Appleseed", initials: "JA", colorHex: "#FF375F", handles: [phone("+1 (888) 555-5512", "mobile"), email("John-Appleseed@mac.com", "work")] },
  // Apple's sample contacts.
  { id: "kate", name: "Kate Bell", initials: "KB", colorHex: "#64D2FF", handles: [phone("+1 (555) 564-8583", "mobile"), email("kate-bell@mac.com", "work")] },
  { id: "anna", name: "Anna Haro", initials: "AH", colorHex: "#FFD60A", handles: [phone("+1 (555) 522-8243", "home"), email("anna-haro@mac.com", "home")] },
  { id: "daniel", name: "Daniel Higgins Jr.", initials: "DH", colorHex: "#5E5CE6", handles: [phone("+1 (555) 478-7672", "home"), email("d-higgins@mac.com", "home")] },
  { id: "david", name: "David Taylor", initials: "DT", colorHex: "#AC8E68", handles: [phone("+1 (555) 610-6679", "home")] },
  // Reachable only by SMS: his token and the service label turn green.
  { id: "hank", name: "Hank M. Zakroff", initials: "HZ", colorHex: "#8E8E93", handles: [phone("+1 (555) 766-4823", "work", "SMS")] },
];

const fold = (s: string) => s.normalize("NFD").replace(/\p{Diacritic}/gu, "").toLowerCase();
const digits = (s: string) => s.replace(/\D/g, "");

export function isEmail(raw: string) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(raw.trim());
}
export function isPhone(raw: string) {
  const t = raw.trim();
  return /^\+?[\d\s().\-]+$/.test(t) && digits(t).length >= 7;
}

/** Canonical key for a handle: lowercased email or bare digits (US numbers without the leading 1). */
export function handleKey(raw: string): string | null {
  const t = raw.trim();
  if (isEmail(t)) return fold(t);
  if (isPhone(t)) {
    const d = digits(t);
    return d.length === 11 && d.startsWith("1") ? d.slice(1) : d;
  }
  return null;
}

/**
 * Messages' recipient autocomplete: a contact matches when a word of the name
 * starts with the query, or a handle contains it. Name-prefix matches first,
 * then word-prefix, then handle matches; alphabetical within each tier.
 * A blank query returns every contact, alphabetical.
 */
export function searchContacts(query: string, limit: number, exclude: Set<string> = new Set()): Contact[] {
  const q = fold(query.trim());
  // A blank query lists everyone (the + Add Contact picker).
  if (!q) return CONTACTS.filter((c) => !exclude.has(c.id)).sort((a, b) => a.name.localeCompare(b.name)).slice(0, limit);
  const qDigits = digits(q);
  const ranked: { c: Contact; tier: number }[] = [];
  for (const c of CONTACTS) {
    if (exclude.has(c.id)) continue;
    const name = fold(c.name);
    let tier = -1;
    if (name.startsWith(q)) tier = 0;
    else if (name.split(/\s+/).some((w) => w.startsWith(q))) tier = 1;
    else if (
      c.handles.some((h) => fold(h.value).includes(q) || (qDigits.length >= 3 && qDigits === q.replace(/[\s()+\-.]/g, "") && digits(h.value).includes(qDigits)))
    )
      tier = 2;
    if (tier >= 0) ranked.push({ c, tier });
  }
  ranked.sort((a, b) => a.tier - b.tier || a.c.name.localeCompare(b.c.name));
  return ranked.slice(0, limit).map((r) => r.c);
}

export function contactForHandle(raw: string): { contact: Contact; handle: Handle } | null {
  const key = handleKey(raw);
  if (!key) return null;
  for (const contact of CONTACTS)
    for (const handle of contact.handles) if (handleKey(handle.value) === key) return { contact, handle };
  return null;
}

/**
 * Availability lookup for a typed address. Known handles report their own
 * service; unknown emails are iMessage, unknown phone numbers SMS, anything
 * else is not a valid address (`service: null`).
 */
export function lookupHandle(raw: string): { handle: string; service: Service | null; contact?: Contact } {
  const known = contactForHandle(raw);
  if (known) return { handle: raw.trim(), service: known.handle.service, contact: known.contact };
  const t = raw.trim();
  if (isEmail(t)) return { handle: t, service: "iMessage" };
  if (isPhone(t)) return { handle: t, service: "SMS" };
  return { handle: t, service: null };
}
