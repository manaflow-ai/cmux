// The composer hat's `summary` header (trayFoldHead.experiment.ts). Leo, 2026-11-23, on a hat that read
// the Claude mark and a bare "2": "this 2 is too bare. it being alone, it's just bad. ... we need to
// have it meaningful even when there's only 1 thing ... like just im saying x subagents running y
// commands running etc with full text when you have space and it gradually shrinks when there is
// none... and have it not shift too much."
//
// One line, every kind in the same step (traySummaryFit.ts): its name for a lone item, "2 subagents
// running · 1 command running", "2 subagents · 1 command", each kind's mark and number, then the
// trailing kinds folded into "+N". A hidden probe beside the line holds every kind in every form (its
// words drawn by CSS from `data-text`, so the header's text and a copy never hold them), so
// a step is picked from measured widths before paint (no flicker), and again when the line's box
// resizes; a step grows back only with room to spare (hysteresis), so a boundary never flaps. The
// line fills the header's free room, so the time and the controls after it never move or clip.
import { type ReactNode, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { Translate } from "../i18n";
import { Icon } from "../icons/Icon";
import { PHASE_DWELL_MS } from "./hatStep";
import { useDwell } from "./HatStepSlot";
import type { TrayItem } from "./runningTray";
import { type TrayHeadForms, type TrayHeadPart, trayHeadForms } from "./trayHeadKinds";
import {
  nextSummaryLevel,
  SUMMARY_COUNT_LEVEL,
  type SummaryForm,
  summaryLevelStep,
  type SummaryKindWidths,
  type SummaryWidths,
} from "./traySummaryFit";

/// How many names a kind's hover lists before "+N more".
const PART_NAMES = 8;
/// The "+N" probe at its widest, so a fold that grows to two digits never needs a wider box.
const MORE_PROBE = "+99";

type Kind = { part: TrayHeadPart; forms: TrayHeadForms; named?: string };

export function HeadSummary({
  t,
  parts,
  plan,
  planIcon,
  separator,
  markSize,
  mark,
  nameOf,
  countOnly = false,
}: {
  t: Translate;
  parts: readonly TrayHeadPart[];
  plan: string;
  planIcon: string;
  /// Between the kinds in the word steps (trayKindLine.experiment.ts).
  separator: string;
  markSize: number;
  /// A kind's mark (its harness's logo for subagents, the kind's icon else), as the lines draw it.
  mark: (part: TrayHeadPart) => ReactNode;
  /// An item's name, as its line names it.
  nameOf: (item: TrayItem) => string;
  /// The `group-marks` arm: marks and numbers at every width; a lone item still reads its name.
  countOnly?: boolean;
}) {
  // What it counts changes at most once per dwell, as the step does: a burst of joins is one change.
  const shownParts = useDwell(parts, PHASE_DWELL_MS);
  const kinds = useMemo<readonly Kind[]>(() => {
    const lone = shownParts.length === 1 && shownParts[0]!.items.length === 1 && !shownParts[0]!.tone;
    return shownParts.map((part) => ({
      part,
      forms: trayHeadForms(t, part),
      ...(lone ? { named: nameOf(part.items[0]!) } : {}),
    }));
  }, [t, shownParts, nameOf]);
  const line = useRef<HTMLSpanElement>(null);
  const probe = useRef<HTMLSpanElement>(null);
  const levelRef = useRef<number | undefined>(undefined);
  const [level, setLevel] = useState<number | undefined>(undefined);
  const [widths, setWidths] = useState<SummaryWidths | undefined>(undefined);
  useLayoutEffect(() => {
    const box = line.current;
    const probes = probe.current;
    if (!box || !probes) return undefined;
    const measured = readWidths(probes, kinds.length);
    const fit = () => {
      const fitted = nextSummaryLevel(measured, box.clientWidth, levelRef.current);
      const next = countOnly && fitted > 0 ? Math.max(fitted, SUMMARY_COUNT_LEVEL) : fitted;
      levelRef.current = next;
      setLevel(next);
    };
    setWidths(measured);
    fit();
    if (typeof ResizeObserver === "undefined") return undefined;
    const observer = new ResizeObserver(fit);
    observer.observe(box);
    return () => observer.disconnect();
  }, [kinds, countOnly]);
  const step =
    widths && level !== undefined && widths.kinds.length === kinds.length
      ? summaryLevelStep(widths, level)
      : {
          form: (kinds[0]?.named !== undefined ? "named" : countOnly ? "count" : "long") as SummaryForm,
          shown: kinds.length,
        };
  const drawn = kinds.slice(0, step.shown);
  const folded = kinds.slice(step.shown);
  const foldedCount = folded.reduce((total, kind) => total + kind.part.items.length, 0);
  const words = step.form !== "count";
  return (
    <span
      className="acpmux-summary-text acpmux-running-tray__title acpmux-running-tray__kinds acpmux-running-tray__summary"
      data-summary={step.form}
      data-shown={step.shown}
      data-folded={folded.length || undefined}
    >
      {plan && (
        <span className="acpmux-running-tray__kind" data-kind="plan">
          <Icon name={planIcon} size={markSize} row />
          <span className="acpmux-running-tray__kind-text">{plan}</span>
        </span>
      )}
      <span ref={line} className="acpmux-running-tray__summary-line">
        {drawn.map((kind, index) => (
          <span key={kind.part.key} className="acpmux-running-tray__kind-unit">
            {words && index > 0 && (
              <span className="acpmux-running-tray__kind-sep" aria-hidden="true">
                {separator}
              </span>
            )}
            <SummaryKind t={t} kind={kind} form={step.form} mark={mark} nameOf={nameOf} />
          </span>
        ))}
        {folded.length > 0 && (
          <span
            className="acpmux-running-tray__summary-more"
            // tooltip-allow: the folded kinds draw nothing else; the hover names them.
            title={folded.map((kind) => kind.forms.long).join("\n")}
            aria-label={folded.map((kind) => kind.forms.long).join(", ")}
          >
            {`+${foldedCount}`}
          </span>
        )}
        {/* Every kind in every form, laid out but never seen or read: what each step needs. */}
        <span ref={probe} className="acpmux-running-tray__summary-probe" aria-hidden="true">
          {kinds.map((kind) => (
            <span key={kind.part.key} data-probe-kind="">
              {(["named", "long", "short", "count"] as const).map((form) =>
                form === "named" && kind.named === undefined ? null : (
                  <span key={form} className="acpmux-running-tray__summary-kind" data-form={form}>
                    <span style={{ width: markSize, flex: "none" }} />
                    <span data-text={formText(kind, form)} />
                  </span>
                ),
              )}
            </span>
          ))}
          <span data-probe="sep" className="acpmux-running-tray__kind-sep" data-text={separator} />
          <span data-probe="gap" className="acpmux-running-tray__summary-gap" />
          <span data-probe="more" className="acpmux-running-tray__summary-more" data-text={MORE_PROBE} />
        </span>
      </span>
    </span>
  );
}

function formText(kind: Kind, form: SummaryForm): string {
  return form === "named" ? (kind.named ?? kind.forms.long) : kind.forms[form];
}

function SummaryKind({
  t,
  kind,
  form,
  mark,
  nameOf,
}: {
  t: Translate;
  kind: Kind;
  form: SummaryForm;
  mark: (part: TrayHeadPart) => ReactNode;
  nameOf: (item: TrayItem) => string;
}) {
  const [names, setNames] = useState<string | undefined>(undefined);
  const { part, forms } = kind;
  // A reader always hears the long form; a lone item's name too when the line draws it.
  const label = form === "named" && kind.named ? `${forms.long} · ${kind.named}` : forms.long;
  return (
    <span
      className="acpmux-running-tray__kind acpmux-running-tray__summary-kind"
      data-kind={part.key}
      data-tone={part.tone}
      data-form={form}
      // tooltip-allow: the hover says what the kind counts, then names them.
      title={names}
      aria-label={label}
      onPointerEnter={() => {
        if (names !== undefined) return;
        const shown = part.items.slice(0, PART_NAMES).map(nameOf);
        const rest = part.items.length - shown.length;
        setNames([forms.long, ...shown, ...(rest > 0 ? [t("tools.more", { n: rest })] : [])].join("\n"));
      }}
    >
      {mark(part)}
      <span className="acpmux-running-tray__kind-text">{formText(kind, form)}</span>
    </span>
  );
}

/// Each kind's width in each form, and the separator, gap and "+N" widths, from the probe.
function readWidths(probe: HTMLElement, count: number): SummaryWidths {
  const width = (node: Element | null | undefined) => (node ? node.getBoundingClientRect().width : 0);
  const rows = [...probe.querySelectorAll(":scope > [data-probe-kind]")];
  const kinds: SummaryKindWidths[] = rows.slice(0, count).map((row) => {
    const named = row.querySelector(':scope > [data-form="named"]');
    return {
      ...(named ? { named: width(named) } : {}),
      long: width(row.querySelector(':scope > [data-form="long"]')),
      short: width(row.querySelector(':scope > [data-form="short"]')),
      count: width(row.querySelector(':scope > [data-form="count"]')),
    };
  });
  return {
    kinds,
    separator: width(probe.querySelector(':scope > [data-probe="sep"]')),
    gap: width(probe.querySelector(':scope > [data-probe="gap"]')),
    more: width(probe.querySelector(':scope > [data-probe="more"]')),
  };
}
