// The chat's moment tips (momentTipsModel.ts), behind the moment-tips experiment (off by default)
// and the Settings feature-tips toggle. A second scheduler beside PaneFeatureTips: it asks the app
// at most once per page, and the app's claim keeps all tips to one per 14 days per install.
import { useMemo } from "react";
import { experimentArm } from "../../experiments/experiment";
import { FeatureTipHost, type FeatureTipHostProps } from "../../ui/featureTips/FeatureTipHost";
import type { TipHost } from "../../ui/featureTips/store";

import { useFeatureTipsOn } from "./chatDisplay";
import { useT } from "./i18n";
import { composerHasDraft, paneTipHost } from "./featureTipsModel";
import { MOMENT_TIP_ANCHORS, momentStreaming, momentTips } from "./momentTipsModel";
import { momentTipsExperiment } from "./momentTips.experiment";

export function PaneMomentTips({
  turnWorking,
  waitingOnPerson,
  host = paneTipHost,
  schedule,
  forceOn,
}: {
  turnWorking: boolean;
  waitingOnPerson: boolean;
  host?: TipHost;
  schedule?: FeatureTipHostProps["schedule"];
  /** The gallery's still shows the arm it draws; the app reads the experiment. */
  forceOn?: boolean;
}) {
  const toggle = useFeatureTipsOn();
  const t = useT();
  const tips = useMemo(() => momentTips(t), [t]);
  const on = forceOn ?? experimentArm(momentTipsExperiment) === "on";
  if (!on) return null;
  return (
    <FeatureTipHost
      tips={tips}
      anchors={MOMENT_TIP_ANCHORS}
      enabled={toggle}
      streaming={momentStreaming(turnWorking, waitingOnPerson)}
      typing={composerHasDraft}
      host={host}
      labels={{ new: t("featureTip.new"), close: t("featureTip.close") }}
      look="glass"
      schedule={schedule}
    />
  );
}
