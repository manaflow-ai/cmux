import type { Strings } from "../shared/i18n";
import { intl } from "../../ui/intl";
import type { CloudDiskBar } from "./ops";
import { L, format } from "./strings";

/**
 * How the bar draws (RFD 0068 disk bar gallery): `segmented` (system, project, caches, free, with
 * the numbers), `single` (one used colour, the split on hover and in the expanded detail), `text`
 * (the sentence alone). The page ships `segmented`; the others are gallery variants.
 */
export type DiskBarVariant = "segmented" | "single" | "text";

interface DiskBarProps {
  bar: CloudDiskBar;
  strings: Strings;
  variant?: DiskBarVariant;
  /** The row's one-line form: the bar and "13.2 / 20 GB", no legend. */
  compact?: boolean;
}

const SEGMENT_NAME = {
  system: L.diskBarSystem,
  project: L.diskBarProject,
  caches: L.diskBarCaches,
  used: L.diskUsed,
  free: L.diskFree,
} as const;

/** Draws cmux-cloud-disk's view as it is: widths, rounding and the almost-full state come from Rust. */
export function DiskBar({ bar, strings, variant = "segmented", compact = false }: DiskBarProps) {
  const { t, language } = strings;
  const number = (gb: number) => intl.NumberFormat(language, { maximumFractionDigits: 1 }).format(gb);
  const total = format(t(L.gigabytes), { value: number(bar.total_gb) });
  if (bar.state === "allocated" || bar.used_gb === undefined || bar.free_gb === undefined) {
    return <span className="cloud-disk-bar-label">{total}</span>;
  }
  const label = format(t(L.diskBarLabel), { used: number(bar.used_gb), total });
  const sentence = format(t(L.diskBarText), { used: number(bar.used_gb), total, free: number(bar.free_gb) });
  const full = bar.state === "almost_full";
  const named = bar.segments.map(
    (s) => `${t(SEGMENT_NAME[s.kind])} ${format(t(L.gigabytes), { value: number(s.gb) })}`,
  );
  const split = named.join(" · ");
  const className = `cloud-disk-bar cloud-disk-bar-${variant}${full ? " cloud-disk-bar-almost-full" : ""}`;
  const warning = full && <strong className="cloud-disk-bar-warning">{t(L.diskBarAlmostFull)} · </strong>;
  if (variant === "text") {
    return (
      <span className={className} data-testid="cloud-disk-bar">
        {warning}
        {sentence}
      </span>
    );
  }
  const used = bar.segments.filter((s) => s.kind !== "free").reduce((sum, s) => sum + s.width, 0);
  const track = (
    <span
      className="cloud-meter-track cloud-disk-bar-track"
      // The track draws its segments as child spans, which an <img> cannot hold; it reads as one picture.
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="img"
      aria-label={`${sentence}. ${split}`}
      title={split}
    >
      {variant === "single" ? (
        <span className="cloud-disk-bar-segment cloud-disk-bar-used" style={{ width: `${used / 10}%` }} />
      ) : (
        bar.segments
          .filter((s) => s.width > 0 && s.kind !== "free")
          .map((s) => (
            <span
              key={s.kind}
              className={`cloud-disk-bar-segment cloud-disk-bar-${s.kind}`}
              style={{ width: `${s.width / 10}%` }}
            />
          ))
      )}
    </span>
  );
  return (
    <span className={className} data-testid="cloud-disk-bar">
      {track}
      <span className="cloud-disk-bar-label">
        {warning}
        {label}
      </span>
      {!compact && variant === "segmented" && (
        <span className="cloud-disk-bar-legend">
          {bar.segments.map((s, i) => (
            <span key={s.kind} className="cloud-disk-bar-key">
              <span className={`cloud-status-dot cloud-disk-bar-${s.kind}`} />
              {named[i]}
            </span>
          ))}
        </span>
      )}
      {!compact && variant === "single" && (
        <details className="cloud-disk-bar-details">
          <summary>{sentence}</summary>
          {split}
        </details>
      )}
    </span>
  );
}
