// The agent chat's feature tips (leo-workspace design/feature-tips.md): the controls a tip may point
// at in this page, the app's tip records (`tips.state`), and the one host App mounts in a chat.
import { useMemo } from "react";
import { FeatureTipHost, type FeatureTipHostProps } from "../../ui/featureTips/FeatureTipHost";

import type { TipHost } from "../../ui/featureTips/store";

import { useFeatureTipsOn } from "./chatDisplay";
import { useT } from "./i18n";
import { PANE_TIP_ANCHORS, PANE_TIPS, paneTipHost, composerHasDraft } from "./featureTipsModel";
import { experimentArm } from "../../experiments/experiment";
import { composerOutcomeHints } from "./composerOutcomeHints.experiment";
/** The chat's tips: mounted once per chat page (App.tsx), drawn in a portal. The gallery passes its
 *  own records and schedule; the app uses the defaults. */
export function PaneFeatureTips({
  streaming,
  host = paneTipHost,
  schedule,
}: {
  streaming: boolean;
  host?: TipHost;
  schedule?: FeatureTipHostProps["schedule"];
}) {
  const enabled = useFeatureTipsOn();
  const t = useT();
  if (PANE_TIPS.length === 0) return null;
  return (
    <FeatureTipHost
      tips={PANE_TIPS}
      anchors={PANE_TIP_ANCHORS}
      enabled={enabled}
      streaming={streaming}
      typing={composerHasDraft}
      host={host}
      labels={{ new: t("featureTip.new"), close: t("featureTip.close") }}
      look="glass"
      schedule={schedule}
    />
  );
}

/** The composer outcome hints' `tip` arm (composerOutcomeHints.experiment.ts; Leo 2026-11-22 09:50Z:
 *  "this is good as tips"): one tip above the composer saying what / and @ do, on the same scheduler,
 *  records and 14-day budget as every feature tip (once per install, never over typing or a turn).
 *  Outside that arm it draws nothing and arms no timer. Shipping it for everyone would be a What's New
 *  highlight with `tip: composer.prompt` instead (design/feature-tips.md), not this hand-made entry. */
export const COMPOSER_HINTS_TIP_ID = "composer-outcome-hints";

export function ComposerHintsTip({
  streaming,
  host = paneTipHost,
  schedule,
}: {
  streaming: boolean;
  host?: TipHost;
  schedule?: FeatureTipHostProps["schedule"];
}) {
  const enabled = useFeatureTipsOn();
  const t = useT();
  const title = t("composer.hintsTipTitle");
  const body = t("composer.hintsTipBody");
  const tips = useMemo(() => [{ id: COMPOSER_HINTS_TIP_ID, anchor: "composer.prompt", title, body }], [title, body]);
  if (experimentArm(composerOutcomeHints) !== "tip") return null;
  return (
    <FeatureTipHost
      tips={tips}
      anchors={PANE_TIP_ANCHORS}
      enabled={enabled}
      streaming={streaming}
      typing={composerHasDraft}
      host={host}
      labels={{ new: t("featureTip.new"), close: t("featureTip.close") }}
      look="glass"
      schedule={schedule}
    />
  );
}
