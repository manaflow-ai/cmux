// AutoSize's chat rows (RFD 0080 piece 4, RFD 0133 items 1 and 2): one row from the computer, not
// from the agent, every time AutoSize grows, shrinks or holds it. The rows come from Rust
// (cmux-cloud-start-core `autosize_row::push`, the FFI op `cloud_autosize_rows`); this file only
// types them and picks each row's words. It derives no row and folds nothing.
import { intl } from "../../../ui/intl";
import type { Translate } from "../i18n";

export type AutoSizeKind = "grow" | "shrink" | "hold";
export type AutoSizeCause = "memory" | "cpu" | "disk" | "oom" | "heavy_task" | "idle" | "unknown";
export type AutoSizeHold =
  | { code: "at_plan_limit" }
  | { code: "at_max_size" }
  | { code: "user_cap" }
  | { code: "other"; name: string };
export type AutoSizeShape = { vcpu: number; mem_gib: number; disk_gib: number; hourly_usd: number };
export type AutoSizeOffer = { do: "upgrade"; plan: string; label: string; vcpu: number; mem_gib: number };

/** One row, as `autosize_row::Row` serializes it. */
export type AutoSizeRow = {
  key: string;
  machine: string;
  record: string;
  kind: AutoSizeKind;
  hold?: AutoSizeHold;
  cause: AutoSizeCause;
  cause_text: string;
  from: AutoSizeShape;
  to?: AutoSizeShape;
  hourly_usd: number;
  rate_change_usd: number;
  /** The server's own sentence: the fallback for a hold code this build has no words for. */
  line: string;
  offer?: AutoSizeOffer;
  at_ms: number;
  last_at_ms: number;
  count: number;
};

/** A row's words, ready to draw. */
export type AutoSizeRowView = {
  kind: AutoSizeKind;
  /** "Grew to 4 vCPU / 8 GiB" */
  title: string;
  /** "it ran out of memory" */
  why: string;
  /** "$0.30 an hour" */
  rate: string;
  /** "+$0.15" on a grow, "−$0.15" on a shrink, empty on a hold. */
  change: string;
  /** "×3" when a hold repeated, else empty. */
  repeats: string;
  /** The button's label, when the row offers the plan above. */
  upgrade?: string;
};

function money(usd: number, lang: string): string {
  return intl
    .NumberFormat(lang, { style: "currency", currency: "USD", minimumFractionDigits: 2, maximumFractionDigits: 3 })
    .format(usd);
}

function number(value: number, lang: string): string {
  return intl.NumberFormat(lang, { maximumFractionDigits: 1 }).format(value);
}

export function shapeLabel(t: Translate, lang: string, vcpu: number, memGib: number): string {
  return t("autosize.shape", { vcpu: number(vcpu, lang), mem: number(memGib, lang) });
}

function why(t: Translate, row: AutoSizeRow): string {
  if (row.kind === "hold") {
    switch (row.hold?.code) {
      case "at_plan_limit":
        return t("autosize.hold.planLimit");
      case "at_max_size":
        return t("autosize.hold.maxSize");
      case "user_cap":
        return t("autosize.hold.userCap");
      default:
        return row.cause_text || row.line;
    }
  }
  switch (row.cause) {
    case "memory":
    case "oom":
      return t("autosize.cause.memory");
    case "cpu":
      return t("autosize.cause.cpu");
    case "disk":
      return t("autosize.cause.disk");
    case "heavy_task":
      return t("autosize.cause.heavyTask");
    case "idle":
      return t("autosize.cause.idle");
    default:
      return row.cause_text;
  }
}

export function autoSizeRowView(row: AutoSizeRow, t: Translate, lang: string): AutoSizeRowView {
  const now = row.kind !== "hold" && row.to ? row.to : row.from;
  const shape = shapeLabel(t, lang, now.vcpu, now.mem_gib);
  const title =
    row.kind === "grow"
      ? t("autosize.grew", { shape })
      : row.kind === "shrink"
        ? t("autosize.shrank", { shape })
        : t("autosize.held", { shape });
  const delta = row.rate_change_usd;
  const change = delta > 0 ? `+${money(delta, lang)}` : delta < 0 ? `−${money(-delta, lang)}` : "";
  const offer = row.offer;
  return {
    kind: row.kind,
    title,
    why: why(t, row),
    rate: t("autosize.rate", { rate: money(row.hourly_usd, lang) }),
    change,
    repeats: row.count > 1 ? t("autosize.repeats", { count: number(row.count, lang) }) : "",
    upgrade: offer
      ? t("autosize.upgrade", { plan: offer.label, shape: shapeLabel(t, lang, offer.vcpu, offer.mem_gib) })
      : undefined,
  };
}

const KINDS: readonly AutoSizeKind[] = ["grow", "shrink", "hold"];
const CAUSES: readonly AutoSizeCause[] = ["memory", "cpu", "disk", "oom", "heavy_task", "idle", "unknown"];

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function isText(value: unknown): value is string {
  return typeof value === "string";
}

function shapeOf(value: unknown): AutoSizeShape | undefined {
  if (!isRecord(value)) return undefined;
  const { vcpu, mem_gib, disk_gib, hourly_usd } = value;
  if (!isNumber(vcpu) || !isNumber(mem_gib) || !isNumber(disk_gib) || !isNumber(hourly_usd)) return undefined;
  return { vcpu, mem_gib, disk_gib, hourly_usd };
}

function holdOf(value: unknown): AutoSizeHold | undefined {
  if (!isRecord(value)) return undefined;
  const code = value.code;
  if (code === "at_plan_limit" || code === "at_max_size" || code === "user_cap") return { code };
  if (code === "other" && isText(value.name)) return { code, name: value.name };
  return undefined;
}

function offerOf(value: unknown): AutoSizeOffer | undefined {
  if (!isRecord(value)) return undefined;
  const { plan, label, vcpu, mem_gib } = value;
  if (value.do !== "upgrade" || !isText(plan) || plan === "" || !isText(label)) return undefined;
  if (!isNumber(vcpu) || !isNumber(mem_gib)) return undefined;
  return { do: "upgrade", plan, label, vcpu, mem_gib };
}

function rowOf(value: unknown): AutoSizeRow | undefined {
  if (!isRecord(value)) return undefined;
  const { key, machine, record, kind, cause, cause_text, hourly_usd, rate_change_usd, line, at_ms, last_at_ms, count } =
    value;
  if (!isText(key) || key === "" || !isText(machine) || !isText(record) || !isText(cause_text) || !isText(line)) {
    return undefined;
  }
  if (!KINDS.includes(kind as AutoSizeKind) || !CAUSES.includes(cause as AutoSizeCause)) return undefined;
  if (!isNumber(hourly_usd) || !isNumber(rate_change_usd) || !isNumber(at_ms) || !isNumber(last_at_ms)) {
    return undefined;
  }
  if (!isNumber(count) || count < 1) return undefined;
  const from = shapeOf(value.from);
  if (!from) return undefined;
  const to = value.to === undefined || value.to === null ? undefined : shapeOf(value.to);
  if (value.to !== undefined && value.to !== null && !to) return undefined;
  const hold = value.hold === undefined || value.hold === null ? undefined : holdOf(value.hold);
  const offer = value.offer === undefined || value.offer === null ? undefined : offerOf(value.offer);
  return {
    key,
    machine,
    record,
    kind: kind as AutoSizeKind,
    ...(hold ? { hold } : {}),
    cause: cause as AutoSizeCause,
    cause_text,
    from,
    ...(to ? { to } : {}),
    hourly_usd,
    rate_change_usd,
    line,
    ...(offer ? { offer } : {}),
    at_ms,
    last_at_ms,
    count,
  };
}

/// `place.autosize` (Rust `autosize_row::Row` JSON, oldest first): every well-formed row, a malformed one dropped;
/// undefined when none is left.
export function autoSizeRowsOf(value: unknown): readonly AutoSizeRow[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const rows = value.map(rowOf).filter((row): row is AutoSizeRow => row !== undefined);
  return rows.length > 0 ? rows : undefined;
}
