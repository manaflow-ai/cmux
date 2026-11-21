// The agent chat's feature tips (leo-workspace design/feature-tips.md): the controls a tip may point
// at in this page, the app's tip records (`tips.state`), and the one host App mounts in a chat.
import { FeatureTipHost, type FeatureTipHostProps } from "../../ui/featureTips/FeatureTipHost";

import type { TipHost } from "../../ui/featureTips/store";

import { useFeatureTipsOn } from "./chatDisplay";
import { useT } from "./i18n";
import { PANE_TIP_ANCHORS, PANE_TIPS, paneTipHost, composerHasDraft } from "./featureTipsModel";
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
