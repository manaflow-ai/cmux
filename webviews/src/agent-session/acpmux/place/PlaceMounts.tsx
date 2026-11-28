import { useEffect, useMemo, useState } from "react";
import { useExperimentSwitch } from "../../../experiments/switches";
import { CLOUD_TOGGLE_SWITCH } from "../hybrid/hybridModel";
import { MoveProgress, type MoveProgressLook } from "./MoveProgress";
import { PlaceControl, type PlaceControlLook } from "./PlaceControl";
import { placeActions, type PlaceClaims } from "./usePlace";
import { useHeaderState } from "../header/headerState";
import { AutoStatusLine } from "../auto/AutoStatusLine";
import { statusTicks, type StatusActionId } from "../auto/computerStatus";
import { AutoSizeFold } from "../autosize/AutoSizeRow";
import { callNative } from "../callNative";
import { translate } from "../i18n";
import { errorMessage } from "../transportErrors";

/// What ships: the chip in the composer's location row, and the card over the composer
/// (PlaceControl.gallery.tsx and MoveProgress.gallery.tsx compare the other looks).
const SHIPPED_CONTROL: PlaceControlLook = "menu";
const SHIPPED_MOVE: MoveProgressLook = "card";

/// The chat's place control, reading `pane.tabState`'s `place`; nothing while the app reports none.
export function PlaceChip({
  session,
  say,
  claims,
  look = SHIPPED_CONTROL,
}: {
  session: string | undefined;
  say?: (text: string) => void;
  /// The queue and draft the page holds, read at the pick.
  claims?: () => PlaceClaims;
  look?: PlaceControlLook;
}) {
  const on = useExperimentSwitch(CLOUD_TOGGLE_SWITCH);
  const { place } = useHeaderState();
  const actions = useMemo(() => (session ? placeActions(session, say, claims) : undefined), [session, say, claims]);
  if (!on || !place || !actions) return null;
  return <PlaceControl place={place} look={look} onMode={actions.setMode} />;
}

/// The chat's move over its composer; nothing while it has none. A move for another chat draws nothing.
export function MoveDock({
  session,
  say,
  claims,
  look = SHIPPED_MOVE,
}: {
  session: string | undefined;
  say?: (text: string) => void;
  /// The queue and draft the page holds, read at a Retry.
  claims?: () => PlaceClaims;
  look?: MoveProgressLook;
}) {
  const { place } = useHeaderState();
  const actions = useMemo(() => (session ? placeActions(session, say, claims) : undefined), [session, say, claims]);
  const on = useExperimentSwitch(CLOUD_TOGGLE_SWITCH);
  const move = place?.move;
  if (!on || !move || !actions || (move.session && session && move.session !== session)) return null;
  return <MoveProgress move={move} look={look} onCancel={actions.cancel} onRetry={actions.retry} />;
}

/// The actions the app runs today: a move's Cancel and Retry, and Run on This Mac (the place's `local`). Raise
/// limit, Pause one and Upgrade have no app action yet, so the line does not draw them.
const OFFERED: readonly StatusActionId[] = ["cancel", "retry", "run_on_mac"];

/// RFD 0080's status line beside the place button: `place.status` (Rust `cloud_computer_status_live`) in words,
/// nothing while the chat simply runs where it is, or while the status is another chat's. It ticks once a second
/// only while it counts seconds.
export function ComputerStatusLine({
  session,
  say,
  claims,
}: {
  session: string | undefined;
  say?: (text: string) => void;
  /// The queue and draft the page holds, read at a Retry or a Run on This Mac.
  claims?: () => PlaceClaims;
}) {
  const on = useExperimentSwitch(CLOUD_TOGGLE_SWITCH);
  const { place } = useHeaderState();
  const actions = useMemo(() => (session ? placeActions(session, say, claims) : undefined), [session, say, claims]);
  const status = place?.status;
  const ticking = on && status !== undefined && statusTicks(status);
  const [nowMs, setNowMs] = useState(() => Date.now());
  useEffect(() => {
    if (!ticking) return;
    setNowMs(Date.now());
    const timer = setInterval(() => setNowMs(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [ticking]);
  if (!on || !status || !actions || (session && status.session_id !== session)) return null;
  const run = (id: StatusActionId) => {
    if (id === "cancel") actions.cancel();
    else if (id === "retry") actions.retry();
    else if (id === "run_on_mac") actions.setMode("local");
  };
  return <AutoStatusLine status={status} nowMs={nowMs} offered={OFFERED} onAction={run} />;
}

/// RFD 0080 piece 4 over the composer: what AutoSize did to the chat's computer (`place.autosize`), the newest row
/// drawn and the rest folded behind "N earlier". A held row's Upgrade asks for the plan (`cloud.plan.subscribe`, the
/// pricing card's call; the app opens checkout) and says a refusal in `say`. Nothing while Settings > Experiments'
/// Cloud Toggle is off or there is no row.
export function AutoSizeDock({ say }: { say?: (text: string) => void }) {
  const on = useExperimentSwitch(CLOUD_TOGGLE_SWITCH);
  const { place } = useHeaderState();
  const rows = place?.autosize;
  if (!on || !rows || rows.length === 0) return null;
  const upgrade = (plan: string) => {
    void callNative("cloud.plan.subscribe", { plan }).catch((error: unknown) =>
      say?.(errorMessage(error).trim() || translate("cloudStart.plans.subscribeFailed")),
    );
  };
  return (
    <div className="autosize-dock">
      <AutoSizeFold rows={rows} onUpgrade={upgrade} />
    </div>
  );
}
