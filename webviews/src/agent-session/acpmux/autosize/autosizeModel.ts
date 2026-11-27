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
