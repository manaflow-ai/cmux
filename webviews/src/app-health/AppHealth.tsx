// App health in shared web (design/app-health.md): a tiny indicator for when a part of the app is
// stuck, slow or being repaired. Its card is native (AppHealthPopover.swift, never a web page). It renders
// one `HealthSnapshot` and nothing when it is quiet (every part healthy, no queued action). There is no animation, pulse or
// timer here: a new snapshot is a state transition, and the dot and its line appear and leave
// together in one frame, in a slot of fixed height, so nothing around them moves.
import type { Strings } from "../pages/shared/i18n";
import { Button } from "../ui/Button";
import { useConnectionQuiet } from "../ui/lasting";
import { indicatorHeadline, type HealthTone } from "./model";
import type { HealthSnapshot } from "./types";
import "./appHealth.css";

/** Where the indicator sits: `footer`, the sidebar footer's dot and line (shipped); `titlebar`, a
 * dot at the titlebar's trailing edge with the line as its tooltip; `pill`, an inline pill with the
 * worst part's Repair. */
export type AppHealthTreatment = "footer" | "titlebar" | "pill";

export interface AppHealthActions {
  /** Opens app health's native card. */
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
  // A part that is only slow shows nothing here (model.ts indicatorHeadline); the native card still lists it.
  const head = indicatorHeadline(snapshot, strings);
  // A queued action alone ("Reconnecting; will close X when back") is a link the person can do nothing
  // about: it waits the shared 10 s. A part that is stuck, repairing or failed shows at once, with its click.
  const pendingOnly = head !== null && head.part === null;
  const pendingLasting = useConnectionQuiet(pendingOnly);
  if (!head || (pendingOnly && !pendingLasting)) return null;
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
