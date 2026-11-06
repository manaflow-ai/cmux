// Session Info's panel frame (SessionInfo.tsx SessionInfoPanel) draws again only when what it is
// handed changes. SessionInfoPresence draws on every snapshot (a running command's output, a streamed
// token), and hands the frame a new `presence` object and a new sections element each time, though
// both hold the same values: without this the frame drew on each one, with a scroll running too
// (Leo, 2026-11-06: "I think we should have it be, like, the same for the session info").
import { isValidElement } from "react";

/// The same values, one level down: plain objects and arrays by their members' identity.
function shallowSame(a: unknown, b: unknown): boolean {
  if (Object.is(a, b)) return true;
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  const keys = Object.keys(a);
  if (keys.length !== Object.keys(b).length) return false;
  return keys.every(
    (key) =>
      Object.prototype.hasOwnProperty.call(b, key) &&
      Object.is((a as Record<string, unknown>)[key], (b as Record<string, unknown>)[key]),
  );
}

/// A prop the frame draws the same: the same value, an element of the same type and key with the
/// same props, or an object (the presence and its `props`) whose members are the same.
function samePart(a: unknown, b: unknown): boolean {
  if (Object.is(a, b)) return true;
  if (isValidElement(a) || isValidElement(b)) {
    if (!isValidElement(a) || !isValidElement(b)) return false;
    return a.type === b.type && a.key === b.key && shallowSame(a.props, b.props);
  }
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return false;
  const keys = Object.keys(a);
  if (keys.length !== Object.keys(b).length) return false;
  return keys.every(
    (key) =>
      Object.prototype.hasOwnProperty.call(b, key) &&
      shallowSame((a as Record<string, unknown>)[key], (b as Record<string, unknown>)[key]),
  );
}

/// `memo`'s comparison for the panel frame: every prop drawn the same (samePart).
export function samePanelProps(previous: object, next: object): boolean {
  const keys = Object.keys(next);
  if (keys.length !== Object.keys(previous).length) return false;
  return keys.every(
    (key) =>
      Object.prototype.hasOwnProperty.call(previous, key) &&
      samePart((previous as Record<string, unknown>)[key], (next as Record<string, unknown>)[key]),
  );
}
