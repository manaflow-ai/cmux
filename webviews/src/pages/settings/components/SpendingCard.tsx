// l10n-allow-file: the Spending card's English copy until the backend serves it localized.
// Settings > Cloud > Spending (RFD 0080 "Spend controls"): overage past the plan's pool, off or on up to a monthly
// limit, and the size above which an agent asks first; the 80% banner and the paused-at-limit banner from the
// team's cap read. The card renders `spendingModel` (../spending.ts) and hands every change to `onChange`; it
// writes nothing itself. It is in no Settings category yet: gallery only (SpendingCard.gallery.tsx), so nothing
// changes for anyone until a later PR mounts it with the write.
import { type RefObject, useId, useRef, useState } from "react";
import { Notice, type NoticeAction } from "../../../ui/Notice";
import { Input } from "../../../ui/Input";
import { Select } from "../../../ui/Select";
import { Switch } from "../../../ui/Switch";
import type { SpendCap } from "../../cloud/spendCap";
import { type SpendingModel, type SpendingSettings, parseLimitUsd, parseShapeKey, spendingModel } from "../spending";

/** rows: the two setting rows, as RFD 0080 draws them. meter: the month's spend against the limit above them. */
export type SpendingLayout = "rows" | "meter";

export type SpendingCardViewProps = {
  model: SpendingModel;
  layout: SpendingLayout;
  busy?: boolean;
  error?: string | null;
  /** The overage limit: a positive amount, or null for off (an emptied field is off too). */
  onLimitChange(usd: number | null): void;
  onAskAboveChange(shape: SpendingSettings["ask_above"]): void;
  /** The paused banner's Run on This Mac; absent hides the button. */
  onRunOnMac?(): void;
};

/** The card for settings with no store (the gallery): changes apply to local state, the backend stand-in. */
export function SpendingCardDemo({
  settings,
  read,
  layout,
}: {
  settings: SpendingSettings;
  read?: SpendCap | null;
  layout: SpendingLayout;
}) {
  const [current, setCurrent] = useState(settings);
  return (
    <SpendingCardView
      model={spendingModel(current, read, "en")}
      layout={layout}
      onLimitChange={(usd) => setCurrent((before) => ({ ...before, overage_limit_usd: usd }))}
      onAskAboveChange={(shape) => setCurrent((before) => ({ ...before, ask_above: shape }))}
      onRunOnMac={() => {}}
    />
  );
}

/** The card itself: a dumb renderer of `model`. */
export function SpendingCardView({
  model,
  layout,
  busy = false,
  error = null,
  onLimitChange,
  onAskAboveChange,
  onRunOnMac,
}: SpendingCardViewProps) {
  const limitRef = useRef<HTMLInputElement>(null);
  // The switch can be on before a limit is typed (the field shows; nothing is sent until it holds an amount), so
  // the card, not the model, holds that wish: the pool-spent banner's Turn on overage sets it too.
  const [wantOn, setWantOn] = useState(model.overageOn);
  const raise = () => {
    if (!model.overageOn) setWantOn(true);
    queueMicrotask(() => {
      limitRef.current?.focus();
      limitRef.current?.select();
    });
  };
  return (
    <section className="group" data-card="spending" data-spending-layout={layout} aria-busy={busy}>
      <h3 className="group-title">Spending</h3>
      {model.banner && <SpendingNotice model={model} onRaise={raise} onRunOnMac={onRunOnMac} />}
      <div className="rows">
        {layout === "meter" && model.meter && <Meter meter={model.meter} />}
        <OverageRow
          model={model}
          busy={busy}
          limitRef={limitRef}
          wantOn={wantOn}
          setWantOn={setWantOn}
          onLimitChange={onLimitChange}
        />
        <AskAboveRow model={model} busy={busy} onAskAboveChange={onAskAboveChange} />
        {error && (
          <div className="row">
            <p className="row-error m-0" role="alert">
              {error}
            </p>
          </div>
        )}
      </div>
    </section>
  );
}

function SpendingNotice({
  model,
  onRaise,
  onRunOnMac,
}: {
  model: SpendingModel;
  onRaise(): void;
  onRunOnMac?(): void;
}) {
  const banner = model.banner!;
  const actions: NoticeAction[] = [
    {
      id: "raise",
      label: banner.kind === "pool_spent" ? "Turn on overage" : "Raise limit",
      onSelect: onRaise,
      primary: true,
    },
  ];
  if (banner.kind !== "near" && onRunOnMac)
    actions.push({ id: "run-on-mac", label: "Run on This Mac", onSelect: onRunOnMac });
  return (
    <div className="pb-2" data-spending-banner={banner.kind}>
      <Notice
        kind={banner.kind === "near" ? "warning" : "error"}
        placement="inline"
        title={banner.title}
        message={banner.message}
        actions={actions}
      />
    </div>
  );
}

function OverageRow({
  model,
  busy,
  limitRef,
  wantOn,
  setWantOn,
  onLimitChange,
}: {
  model: SpendingModel;
  busy: boolean;
  limitRef: RefObject<HTMLInputElement | null>;
  wantOn: boolean;
  setWantOn(on: boolean): void;
  onLimitChange(usd: number | null): void;
}) {
  const titleId = useId();
  const fieldId = useId();
  const [draft, setDraft] = useState(model.limitText);
  const [draftError, setDraftError] = useState<string | null>(null);
  const [synced, setSynced] = useState(model.limitText);
  if (synced !== model.limitText) {
    setSynced(model.limitText);
    setDraft(model.limitText);
    setWantOn(model.overageOn);
  }
  const on = wantOn || model.overageOn;
  const commit = () => {
    const parsed = parseLimitUsd(draft);
    if (!parsed.ok) {
      setDraftError(parsed.error);
      return;
    }
    setDraftError(null);
    if (parsed.usd === null) {
      // An empty field turns a saved limit off; with none saved yet, leaving the field keeps the switch on, waiting
      // for an amount, rather than flipping it back off unexplained.
      if (model.overageOn) {
        setWantOn(false);
        onLimitChange(null);
      }
      return;
    }
    if (model.limitText !== draft.trim()) onLimitChange(parsed.usd);
  };
  return (
    <div className="row" data-spending-row="overage">
      <div className="row-main">
        <div className="row-label">
          <div className="row-title" id={titleId}>
            Overage after the plan's pool
          </div>
          <div className="row-help" style={{ whiteSpace: "normal" }}>
            {model.overageHelp}
          </div>
        </div>
        <div className="row-control flex items-center gap-2">
          <Switch
            aria-labelledby={titleId}
            checked={on}
            disabled={busy}
            data-spending-overage=""
            onCheckedChange={(next) => {
              setWantOn(next);
              setDraftError(null);
              if (!next) {
                setDraft("");
                if (model.overageOn) onLimitChange(null);
              } else queueMicrotask(() => limitRef.current?.focus());
            }}
          />
          {on && (
            <span className="flex items-center gap-1 whitespace-nowrap">
              <label htmlFor={fieldId}>up to $</label>
              <Input
                id={fieldId}
                ref={limitRef}
                size="sm"
                inputMode="decimal"
                placeholder="__"
                style={{ width: "6em" }}
                value={draft}
                disabled={busy}
                aria-invalid={draftError ? true : undefined}
                data-spending-limit=""
                onChange={(event) => setDraft(event.currentTarget.value)}
                onBlur={commit}
                onKeyDown={(event) => {
                  if (event.key === "Enter") commit();
                }}
              />
              <span>a month</span>
            </span>
          )}
        </div>
      </div>
      {draftError && (
        <p className="row-error m-0" role="alert" data-spending-limit-error="">
          {draftError}
        </p>
      )}
    </div>
  );
}

function AskAboveRow({
  model,
  busy,
  onAskAboveChange,
}: {
  model: SpendingModel;
  busy: boolean;
  onAskAboveChange(shape: SpendingSettings["ask_above"]): void;
}) {
  const titleId = useId();
  return (
    <div className="row" data-spending-row="ask-above">
      <div className="row-main">
        <div className="row-label">
          <div className="row-title" id={titleId}>
            Ask before an agent goes above
          </div>
          <div className="row-help" style={{ whiteSpace: "normal" }}>
            {model.askHelp}
          </div>
        </div>
        <div className="row-control" data-spending-ask-above={model.askAbove}>
          <Select
            label="Ask before an agent goes above"
            labelledBy={titleId}
            value={model.askAbove}
            options={model.askOptions}
            disabled={busy}
            closeOnPick
            onChange={(key) => {
              const shape = parseShapeKey(key);
              if (shape) onAskAboveChange(shape);
            }}
          />
        </div>
      </div>
    </div>
  );
}

function Meter({ meter }: { meter: NonNullable<SpendingModel["meter"]> }) {
  return (
    <div className="row flex flex-col gap-1" data-spending-meter="">
      {/* The label under the bar says the amounts; the bar is its picture. */}
      <div className="h-2 overflow-hidden rounded-sm bg-input" aria-hidden="true">
        <div className="h-full bg-[var(--accent)]" style={{ width: `${meter.fraction * 100}%` }} />
      </div>
      <span className="row-help">{meter.label}</span>
    </div>
  );
}
