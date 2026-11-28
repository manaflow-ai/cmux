// l10n-allow-file: the Compute card's English copy until the backend serves it localized.
// Settings > Team > Compute: who on the team uses what Cloud compute, and the team's monthly
// allotment scaled down, held or up in one click. The card renders `computeModel` (../computeAllotment.ts)
// and nothing else: the sentence, the dial's figures, the rows and their notes are derived there.
// Three layouts are on trial in the gallery (ledger, meter, inbox); the card is in no Settings
// category yet. It reads once when it mounts and after each click; it never polls.
import { useQuery } from "@tanstack/react-query";
import { useId, useState, type ReactNode } from "react";
import { Button } from "../../../ui/Button";
import { Disclosure } from "../../../ui/Disclosure";
import { Switch } from "../../../ui/Switch";
import { computeModel, type ComputeModel, type DialOption, type MemberRow } from "../computeAllotment";
import { useStore } from "../context";
import type { AllotmentPosition, AllotmentSet, AllotmentView } from "../ops";
import { settingsKeys } from "../queries";
import { locale } from "../strings";

export type ComputeLayout = "ledger" | "meter" | "inbox";

export type ComputeCardViewProps = {
  model: ComputeModel;
  layout: ComputeLayout;
  busy?: boolean;
  error?: string | null;
  onSet(run: AllotmentSet): void;
};

const ALLOTMENT_KEY = [...settingsKeys.all, "allotment"] as const;

/** The card on the settings store: one read on mount, the view a click answers replaces it. */
export function ComputeCard({ layout = "ledger" }: { layout?: ComputeLayout }) {
  const store = useStore();
  const query = useQuery(
    { queryKey: ALLOTMENT_KEY, queryFn: () => store.allotment(), staleTime: Infinity },
    store.queryClient,
  );
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const view = query.data;
  if (!view) return null;
  const onSet = async (run: AllotmentSet) => {
    setBusy(true);
    try {
      const reply = await store.setAllotment(run);
      setError(reply.error);
      if (reply.view) store.queryClient.setQueryData(ALLOTMENT_KEY, reply.view);
    } finally {
      setBusy(false);
    }
  };
  return (
    <ComputeCardView
      model={computeModel(view, locale())}
      layout={layout}
      busy={busy}
      error={error}
      onSet={(run) => void onSet(run)}
    />
  );
}

/** The card for a view with no store (the gallery): clicks run `answer`, the backend stand-in. */
export function ComputeCardDemo({
  view,
  layout,
  answer,
}: {
  view: AllotmentView;
  layout: ComputeLayout;
  answer(view: AllotmentView, run: AllotmentSet): AllotmentView;
}) {
  const [current, setCurrent] = useState(view);
  return (
    <ComputeCardView
      model={computeModel(current, "en")}
      layout={layout}
      onSet={(run) => setCurrent((before) => answer(before, run))}
    />
  );
}

/** The card itself: a dumb renderer of `model`. */
export function ComputeCardView({ model, layout, busy = false, error = null, onSet }: ComputeCardViewProps) {
  return (
    <section className="group" data-card="compute" data-compute-layout={layout} aria-busy={busy}>
      <h3 className="group-title">Compute</h3>
      <div className="rows">
        {layout === "inbox" ? (
          <Inbox model={model} busy={busy} onSet={onSet} />
        ) : (
          <>
            <div className="row">
              <p className="m-0" data-compute-sentence="">
                {model.sentence}
              </p>
            </div>
            {layout === "meter" ? (
              <Meter model={model} busy={busy} onSet={onSet} />
            ) : (
              <div className="row flex flex-wrap items-start justify-between gap-4">
                <Dial model={model} busy={busy} onSet={onSet} />
                <AutoSwitch model={model} busy={busy} onSet={onSet} />
              </div>
            )}
            {!model.empty && <MemberTable model={model} />}
          </>
        )}
        {error && (
          <div className="row">
            <p className="row-error m-0" role="alert">
              {error}
            </p>
          </div>
        )}
        <div className="row">
          <Disclosure label="Advanced">
            <p className="row-help m-0 pt-2" data-compute-hard-cap="">
              {model.hardCap}
            </p>
          </Disclosure>
        </div>
      </div>
    </section>
  );
}

type PartProps = { model: ComputeModel; busy: boolean; onSet(run: AllotmentSet): void };

// Equal columns, each as wide as the widest figure, so every figure sits centred under its own button.
function Dial({ model, busy, onSet }: PartProps) {
  return (
    <fieldset
      aria-label="Allotment"
      className="m-0 grid auto-cols-fr grid-flow-col gap-3 border-0 p-0"
      data-compute-dial=""
    >
      {model.options.map((option) => (
        <DialButton key={option.position} option={option} busy={busy} locked={model.locked} onSet={onSet} />
      ))}
    </fieldset>
  );
}

function DialButton({
  option,
  busy,
  locked,
  onSet,
}: {
  option: DialOption;
  busy: boolean;
  locked: boolean;
  onSet(run: AllotmentSet): void;
}) {
  return (
    <div className="flex flex-col items-stretch gap-1" data-compute-option={option.position}>
      <Button
        variant={option.proposed ? "solid" : "subtle"}
        disabled={busy || locked || option.disabled}
        data-proposed={option.proposed ? "" : undefined}
        onClick={() => onSet({ action: option.position })}
      >
        {option.label}
      </Button>
      <span className="row-help text-center whitespace-nowrap" data-compute-figure="">
        {option.figure}
      </span>
    </div>
  );
}

function AutoSwitch({ model, busy, onSet }: PartProps) {
  const label = useId();
  return (
    <span className="flex items-center gap-2" data-compute-auto="">
      <span id={label}>Auto</span>
      <Switch
        aria-labelledby={label}
        checked={model.auto}
        disabled={busy || model.locked}
        onCheckedChange={(on) => onSet({ auto: on })}
      />
    </span>
  );
}

/** `.row-help` is one clipped line on this page (unlayered sheet, so a utility class loses): table text wraps instead. */
const WRAP = { whiteSpace: "normal" } as const;

function MemberTable({ model }: { model: ComputeModel }) {
  const cell = "py-1 pr-4 text-left align-top";
  return (
    <div className="row">
      {/* Fixed columns at the row's own width: the table can never be wider than the card, and a long note wraps. */}
      <table className="border-collapse" style={{ width: "100%", tableLayout: "fixed" }} data-compute-table="">
        <colgroup>
          <col style={{ width: "34%" }} />
          <col style={{ width: "17%" }} />
          <col style={{ width: "19%" }} />
          <col style={{ width: "30%" }} />
        </colgroup>
        <thead>
          <tr className="row-help" style={WRAP}>
            <th className={cell} scope="col">
              Member
            </th>
            <th className={cell} scope="col">
              This month
            </th>
            <th className={cell} scope="col">
              Share of allotment
            </th>
            <th className={cell} scope="col">
              Note
            </th>
          </tr>
        </thead>
        <tbody>
          {model.rows.map((row) => (
            <MemberLine key={row.member} row={row} cell={cell} />
          ))}
          <tr data-compute-member="spares">
            <td className={cell}>
              <div>{model.spares.member}</div>
              <div className="row-help" style={WRAP}>
                {model.spares.detail}
              </div>
            </td>
            <td className={cell}>{model.spares.month}</td>
            <td className={`${cell} row-help`} style={WRAP} colSpan={2}>
              {model.spares.note}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  );
}

function MemberLine({ row, cell }: { row: MemberRow; cell: string }) {
  return (
    <tr data-compute-member={row.member}>
      <td className={cell}>
        <div>{row.member}</div>
        <div className="row-help" style={WRAP}>
          {row.detail}
        </div>
      </td>
      <td className={cell}>{row.month}</td>
      <td className={cell}>{row.share}</td>
      <td className={`${cell} row-help`} style={WRAP} data-compute-note="">
        {row.note}
      </td>
    </tr>
  );
}

/** The accent at falling strengths, one per member in the bar and its legend. */
const strength = (index: number) => Math.max(0.3, 1 - index * 0.12);

function Meter({ model, busy, onSet }: PartProps) {
  const { meter } = model;
  const option = (position: AllotmentPosition) => model.options.find((candidate) => candidate.position === position)!;
  const step = (position: "down" | "up", label: string, name: string) => {
    const choice = option(position);
    return (
      <Button
        size="sm"
        variant={choice.proposed ? "solid" : "subtle"}
        aria-label={`${name}: ${choice.figure}`}
        disabled={busy || model.locked || choice.disabled}
        data-compute-option={position}
        data-proposed={choice.proposed ? "" : undefined}
        onClick={() => onSet({ action: position })}
      >
        {label}
      </Button>
    );
  };
  return (
    <div className="row flex flex-col gap-2" data-compute-meter="">
      <div className="relative h-6 rounded-sm bg-input" aria-hidden="true">
        <div className="flex h-full gap-px overflow-hidden rounded-sm">
          {meter.segments.map((segment, index) => (
            <div
              key={segment.member}
              className="h-full bg-[var(--accent)]"
              style={{ width: `${segment.fraction * 100}%`, opacity: strength(index) }}
              data-compute-segment={segment.member}
            />
          ))}
        </div>
        <Tick at={meter.allot} />
        {meter.cap !== null && <Tick at={meter.cap} />}
      </div>
      <div className="relative h-12">
        <div
          className="absolute top-0 flex -translate-x-1/2 items-center gap-1"
          style={{ left: `${Math.min(meter.allot, 0.85) * 100}%` }}
          data-compute-dial=""
        >
          {step("down", "-", "Scale down")}
          <span className="row-help whitespace-nowrap">{meter.allotLabel}</span>
          {step("up", "+", "Scale up")}
          {!option("hold").proposed && (
            <Button
              size="sm"
              disabled={busy || model.locked || option("hold").disabled}
              data-compute-option="hold"
              onClick={() => onSet({ action: "hold" })}
            >
              {option("hold").label}
            </Button>
          )}
        </div>
        {meter.capLabel && meter.cap !== null && (
          <span
            className="row-help absolute top-8 -translate-x-full whitespace-nowrap"
            style={{ left: `${meter.cap * 100}%` }}
          >
            {meter.capLabel}
          </span>
        )}
      </div>
      <div className="flex flex-wrap items-center justify-between gap-4">
        <ul className="m-0 flex list-none flex-wrap gap-x-4 gap-y-1 p-0" data-compute-legend="">
          {model.rows.map((row, index) => (
            <li key={row.member} className="flex items-center gap-1" data-compute-member={row.member}>
              <span
                className="inline-block size-2 rounded-sm bg-[var(--accent)]"
                style={{ opacity: strength(index) }}
                aria-hidden="true"
              />
              <span>{row.member}</span>
              <span className="row-help">{row.month}</span>
            </li>
          ))}
          <li className="flex items-center gap-1" data-compute-member="spares">
            <span>{model.spares.member}:</span>
            <span className="row-help">
              {model.spares.detail}, {model.spares.month}
            </span>
          </li>
        </ul>
        <AutoSwitch model={model} busy={busy} onSet={onSet} />
      </div>
    </div>
  );
}

function Tick({ at }: { at: number }) {
  return <div className="absolute -top-1 -bottom-1 w-px bg-fg" style={{ left: `${Math.min(at, 1) * 100}%` }} />;
}

function Inbox({ model, busy, onSet }: PartProps) {
  const cards: ReactNode =
    model.reasons.length === 0 ? (
      <div className="row">
        <p className="m-0" data-compute-sentence="">
          {model.sentence}
        </p>
      </div>
    ) : (
      model.reasons.map((reason) => (
        <div key={reason.key} className="row flex items-start justify-between gap-4" data-compute-reason={reason.key}>
          <p className="m-0">{reason.text}</p>
          <div className="flex shrink-0 gap-2">
            {reason.accept && (
              <Button
                size="sm"
                variant="solid"
                disabled={busy}
                data-compute-accept={reason.accept}
                onClick={() => onSet({ action: reason.accept! })}
              >
                Accept
              </Button>
            )}
            <Button size="sm" disabled={busy} data-compute-not-now="" onClick={() => onSet({ action: "hold" })}>
              Not now
            </Button>
          </div>
        </div>
      ))
    );
  return (
    <>
      {cards}
      <div className="row flex items-center justify-between gap-4">
        <span data-compute-hold-line="">{model.holdLine}</span>
        <AutoSwitch model={model} busy={busy} onSet={onSet} />
      </div>
      {!model.empty && (
        <div className="row">
          <Disclosure label="Who uses what">
            <div className="pt-2">
              <MemberTable model={model} />
            </div>
          </Disclosure>
        </div>
      )}
    </>
  );
}
