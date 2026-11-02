// The agent chat's feature tips (leo-workspace design/feature-tips.md): the controls a tip may point
// at in this page, the app's tip records (`tips.state`), and the one host App mounts in a chat.
import { FeatureTipHost, type FeatureTipHostProps } from "../../ui/featureTips/FeatureTipHost";
import type { TipAnchor } from "../../ui/featureTips/controller";
import type { FeatureTipEntry, TipRecords, TipState } from "../../ui/featureTips/policy";
import type { TipHost } from "../../ui/featureTips/store";
import catalog from "../../ui/featureTips/tips.generated.json";
import { useFeatureTipsOn } from "./chatDisplay";
import { useT } from "./i18n";
import { postNative } from "./native";

/** The controls of the chat a highlight's `tip:` line may name. */
export const PANE_TIP_ANCHORS: Readonly<Record<string, TipAnchor>> = {
  /** The header's Browser button (header/headerQuickTools.ts). */
  "agent.browser": {
    selector: '.acpmux-header-tools [data-quick-action="browser"]',
    side: "bottom",
    feature: "browser",
  },
  /** The header's Session Info or Summary toggle (header/PanelToggle.tsx). */
  "agent.inspector": { selector: ".acpmux-header-tools .acpmux-header-panel-toggle", side: "bottom" },
  /** The composer (ComposerBox.tsx), for a feature typed there (/btw). */
  "composer.prompt": { selector: ".acpmux-composer-box", side: "top" },
};

/** The tips whose control this page has, each with its control's feature. */
export const PANE_TIPS: readonly FeatureTipEntry[] = (catalog as FeatureTipEntry[])
  .filter((tip) => tip.anchor in PANE_TIP_ANCHORS)
  .map((tip) => ({ ...tip, feature: PANE_TIP_ANCHORS[tip.anchor]?.feature }));

function call<T>(method: string, params: Record<string, unknown>): Promise<T> {
  const direct = window.cmuxAcpmuxActions?.[method];
  return direct ? (direct(params) as Promise<T>) : postNative<T>(method, params);
}

const tipState = (reply: unknown): TipState => {
  const { states, used } = (reply ?? {}) as { states?: unknown; used?: unknown };
  if (!states || typeof states !== "object" || Array.isArray(states)) throw new Error("tips.state.noRecords");
  const records: TipRecords = Object.fromEntries(
    Object.entries(states).filter((entry): entry is [string, string] => typeof entry[1] === "string"),
  );
  return { records, used: new Set(Array.isArray(used) ? used.filter((name) => typeof name === "string") : []) };
};

/** `tips.state {}` reads the install's records and used features, `{id, state}` keeps one, and
 *  `{claim, feature}` asks the app to show a tip (`claimed`: once per tip per install, never after a
 *  use of its feature, at most one every 14 days). An older app refuses all three: no tips. */
export const paneTipHost: TipHost = {
  read: () => call<unknown>("tips.state", {}).then(tipState),
  write: (id, state) => call<unknown>("tips.state", { id, state }),
  claim: (id, feature) =>
    call<unknown>("tips.state", feature ? { claim: id, feature } : { claim: id }).then(
      (reply) => (reply as { claimed?: unknown } | null)?.claimed === true,
    ),
};

/** A draft in the composer counts as typing: the person is mid-thought. */
export function composerHasDraft(doc: Document = document): boolean {
  const field = doc.querySelector(".acpmux-composer-box .ProseMirror");
  if (field && (field.textContent ?? "").trim() !== "") return true;
  return [...doc.querySelectorAll<HTMLTextAreaElement>(".acpmux-composer-box textarea")].some(
    (area) => area.value.trim() !== "",
  );
}

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
