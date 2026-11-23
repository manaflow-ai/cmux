// Settings > Keys (design/settings-keys.md): the rows the card draws from `cmux.settings.keys.list`,
// which is `cmux keys ls --json` (cmux-tui cli/key_broker.rs) plus the key requests waiting for the
// person. Records never carry a value. Older records lack the newer fields (label, hosts, uses), so
// every field is read defensively here and the card only draws.
import type { KeyRecordWire, KeyRequestWire, KeysState } from "./ops";
import { intl } from "../../ui/intl";

export type KeyState = "live" | "expired" | "revoked";

/** One key's row. */
export type KeyRow = {
  id: string;
  label: string;
  /** The name agents use (`cmux keys use NAME`), when it differs from the label. */
  name: string | null;
  /** `local` keys keep a value on this Mac; a provider key (`cloudflare`) lives at the provider. */
  provider: string;
  purpose: string | null;
  /** The sites it may be sent to; empty: any. */
  hosts: string[];
  /** Where it was written or used: each store, then each use's target with its count. */
  places: string[];
  /** Who stored or minted it, and who asked for it, shortened for a person (``actorLabel``). */
  by: string | null;
  askedBy: string | null;
  createdAt: number | null;
  expiresAt: number | null;
  state: KeyState;
};

/** One waiting request's row. */
export type KeyRequestRow = {
  id: string;
  name: string;
  purpose: string;
  hosts: string[];
  requester: string;
  askedAt: number | null;
};

const stateOrder: Record<KeyState, number> = { live: 0, expired: 1, revoked: 2 };

function time(value: string | null | undefined): number | null {
  if (!value) return null;
  const at = Date.parse(value);
  return Number.isFinite(at) ? at : null;
}

function strings(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === "string" && item !== "") : [];
}

/** A record's state: the CLI's, else from its expiry (an older CLI that did not say). */
export function keyState(record: KeyRecordWire, now: number): KeyState {
  if (record.state === "revoked" || record.state === "expired" || record.state === "live") return record.state;
  const expires = time(record.expires_at);
  return expires !== null && expires <= now ? "expired" : "live";
}

/** Who the CLI says did something (`CLAUDE_CODE_SESSION_ID=…`, `user=leo`), for a person: the
 * agent's product and the start of its session id, or the user's name. */
export function actorLabel(by: string | null | undefined): string | null {
  const text = by?.trim();
  if (!text) return null;
  const at = text.indexOf("=");
  if (at < 0) return text;
  const variable = text.slice(0, at);
  const value = text.slice(at + 1);
  const short = value.length > 8 ? value.slice(0, 8) : value;
  switch (variable) {
    case "user":
      return value;
    case "CLAUDE_CODE_SESSION_ID":
      return `Claude Code · ${short}`;
    case "CODEX_SESSION_ID":
      return `Codex · ${short}`;
    case "CMUX_SESSION_ID":
      return `cmux · ${short}`;
    case "ACPMUX_SESSION":
      return `acpmux · ${short}`;
    default:
      return value || text;
  }
}

/** The card's key rows: live first, then expired, then revoked; newest first within each (ties by
 * id, so the order never flickers). */
export function keyRows(state: KeysState | null | undefined, now: number): KeyRow[] {
  return (state?.keys ?? [])
    .filter((record) => typeof record?.id === "string" && record.id !== "")
    .map((record): KeyRow => {
      const name = record.name?.trim() || null;
      const label = record.label?.trim() || name || record.bucket?.trim() || record.id;
      const uses = (Array.isArray(record.uses) ? record.uses : [])
        .filter((use) => typeof use?.target === "string" && use.target !== "")
        .map((use) => (typeof use.count === "number" && use.count > 1 ? `${use.target} ×${use.count}` : use.target));
      return {
        id: record.id,
        label,
        name: name && name !== label ? name : null,
        provider: record.provider || "local",
        purpose: record.purpose?.trim() || null,
        hosts: strings(record.hosts),
        places: [...new Set([...strings(record.stores), ...uses])],
        by: actorLabel(record.by),
        askedBy: actorLabel(record.asked_by),
        createdAt: time(record.created_at),
        expiresAt: time(record.expires_at),
        state: keyState(record, now),
      };
    })
    .sort(
      (a, b) =>
        stateOrder[a.state] - stateOrder[b.state] ||
        (b.createdAt ?? 0) - (a.createdAt ?? 0) ||
        a.id.localeCompare(b.id),
    );
}

/** The waiting requests, oldest first (the one asked first is answered first). */
export function keyRequestRows(state: KeysState | null | undefined): KeyRequestRow[] {
  return (state?.requests ?? [])
    .filter((request: KeyRequestWire) => typeof request?.id === "string" && typeof request.name === "string")
    .map((request) => ({
      id: request.id,
      name: request.name,
      purpose: request.purpose?.trim() ?? "",
      hosts: strings(request.hosts),
      requester: actorLabel(request.requester) ?? request.requester ?? "",
      askedAt: time(request.asked_at),
    }))
    .sort((a, b) => (a.askedAt ?? 0) - (b.askedAt ?? 0) || a.id.localeCompare(b.id));
}

/** A date in the page's locale: the day, and the time when it is today. */
export function keyDate(at: number, now: number, locale: string): string {
  const date = new Date(at);
  const sameDay = new Date(now).toDateString() === date.toDateString();
  const format = sameDay
    ? intl.DateTimeFormat(locale, { hour: "numeric", minute: "2-digit" })
    : intl.DateTimeFormat(locale, { month: "short", day: "numeric" });
  return format.format(date);
}
