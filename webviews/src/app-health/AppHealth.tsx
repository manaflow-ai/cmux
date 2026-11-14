// App health in shared web (design/app-health.md): a tiny indicator for when a part of the app is
// stuck, slow or being repaired, and the popover it opens. Both render one `HealthSnapshot` and
// nothing when it is quiet (every part healthy, no queued action). There is no animation, pulse or
// timer here: a new snapshot is a state transition, and the dot and its line appear and leave
// together in one frame, in a slot of fixed height, so nothing around them moves.
import type { Strings } from "../pages/shared/i18n";
import { Button } from "../ui/Button";
import { Disclosure } from "../ui/Disclosure";
import { headline, indicatorHeadline, otherParts, pendingLine, toneOf, type HealthTone } from "./model";
import type { HealthPart, HealthSnapshot } from "./types";
import "./appHealth.css";

/** Where the indicator sits: `footer`, the sidebar footer's dot and line (shipped); `titlebar`, a
 * dot at the titlebar's trailing edge with the line as its tooltip; `pill`, an inline pill with the
 * worst part's Repair. */
export type AppHealthTreatment = "footer" | "titlebar" | "pill";

export interface AppHealthActions {
  /** Opens the popover (the host shows `#/app-health` anchored to the indicator). */
  open(): void;
  /** The person's Repair for one part: `cmux.app.health.repair_now {id}`. */
  repair(id: string): void;
}

export function AppHealthDot({ tone }: { tone: HealthTone }) {
  return <span className="ah-dot" data-tone={tone} aria-hidden="true" />;
}

export function AppHealthIndicator({
  snapshot,
  strings,
  actions,
  treatment = "footer",
}: {
  snapshot: HealthSnapshot | null | undefined;
  strings: Strings;
  actions: AppHealthActions;
  treatment?: AppHealthTreatment;
}) {
  // A part that is only slow shows nothing here (model.ts indicatorHeadline); the popover still lists it.
  const head = indicatorHeadline(snapshot, strings);
  if (!head) return null;
  if (treatment === "titlebar")
    return (
      <Button
        variant="ghost"
        size="sm"
        icon
        className="ah-indicator"
        data-treatment="titlebar"
        aria-label={head.text}
        /* tooltip-allow: the dot has no text; the tooltip is its one line */
        title={head.text}
        onClick={actions.open}
      >
        <AppHealthDot tone={head.tone} />
      </Button>
    );
  const repairable = treatment === "pill" && head.part?.canRepair ? head.part : null;
  return (
    <div className="ah-indicator" data-treatment={treatment} data-tone={head.tone}>
      <button type="button" className="ui-button ah-indicator-open" onClick={actions.open}>
        <AppHealthDot tone={head.tone} />
        <span className="ah-line">{head.text}</span>
      </button>
      {repairable && (
        <Button variant="subtle" size="sm" className="ah-repair" onClick={() => actions.repair(repairable.id)}>
          {strings.t("appHealth.repair")}
        </Button>
      )}
    </div>
  );
}

export function AppHealthPopover({
  snapshot,
  strings,
  repair,
}: {
  snapshot: HealthSnapshot | null | undefined;
  strings: Strings;
  repair(id: string): void;
}) {
  const head = headline(snapshot, strings);
  if (!snapshot || !head) return null;
  const worst = head.part;
  const others = otherParts(snapshot, worst);
  const pending = snapshot.pending ?? [];
  return (
    <section className="ah-popover" aria-label={strings.t("appHealth.title")} data-tone={head.tone}>
      <div className="ah-head">
        <AppHealthDot tone={head.tone} />
        <span className="ah-head-line">{head.text}</span>
        {worst?.canRepair && (
          <Button variant="solid" size="sm" onClick={() => repair(worst.id)}>
            {strings.t("appHealth.repairNow")}
          </Button>
        )}
      </div>
      {worst && <p className="ah-detail selectable">{worst.detail}</p>}
      {others.length > 0 && (
        <ul className="ah-parts">
          {others.map((part) => (
            <PartRow key={part.id} part={part} strings={strings} repair={repair} />
          ))}
        </ul>
      )}
      {pending.length > 0 && (worst || pending.length > 1 || (snapshot.pendingMore ?? 0) > 0) && (
        <ul className="ah-pending">
          {/* With no unhealthy part the head already says the first queued action. */}
          {(worst ? pending : pending.slice(1)).map((item) => (
            <li key={item.id}>{pendingLine(item.label, strings)}</li>
          ))}
          {(snapshot.pendingMore ?? 0) > 0 && (
            <li className="ah-more">{strings.format("appHealth.pendingMore", String(snapshot.pendingMore))}</li>
          )}
        </ul>
      )}
      {snapshot.receipts.length > 0 && (
        <Disclosure className="ah-receipts" label={strings.t("appHealth.receipts")}>
          <ul>
            {snapshot.receipts.map((receipt) => (
              <li key={`${receipt.atMs}:${receipt.id}:${receipt.action}`} data-outcome={receipt.outcome}>
                <span className="ah-outcome">{strings.t(`appHealth.outcome.${receipt.outcome}`)}</span>
                <span className="ah-receipt-detail selectable">{receipt.detail}</span>
              </li>
            ))}
          </ul>
        </Disclosure>
      )}
    </section>
  );
}

function PartRow({ part, strings, repair }: { part: HealthPart; strings: Strings; repair(id: string): void }) {
  return (
    <li className="ah-part" data-state={part.state}>
      <span className="ah-part-dot">
        <AppHealthDot tone={toneOf(part.state)} />
      </span>
      <div className="ah-part-text">
        <span className="ah-part-line">
          {strings.format("appHealth.line", part.label, strings.t(`appHealth.state.${part.state}`))}
        </span>
        <span className="ah-detail selectable">{part.detail}</span>
      </div>
      {part.canRepair && (
        <Button variant="subtle" size="sm" onClick={() => repair(part.id)}>
          {strings.t("appHealth.repair")}
        </Button>
      )}
    </li>
  );
}
