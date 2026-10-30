// The agent chat's feature tips (leo-workspace design/feature-tips.md): the controls a tip may point
// at in this page, the app's tip records (`tips.state`), and the one host App mounts in a chat.
import { FeatureTipHost, type FeatureTipHostProps } from "../../ui/featureTips/FeatureTipHost";
import type { TipAnchor } from "../../ui/featureTips/controller";
import type { FeatureTipEntry, TipRecords } from "../../ui/featureTips/policy";
import { storageLaunchStore, type LaunchStore, type TipHost } from "../../ui/featureTips/store";
import catalog from "../../ui/featureTips/tips.generated.json";
import { useFeatureTipsOn } from "./chatDisplay";
import { useT } from "./i18n";
import { postNative } from "./native";

/** The controls of the chat a highlight's `tip:` line may name. */
export const PANE_TIP_ANCHORS: Readonly<Record<string, TipAnchor>> = {
  /** The header's Browser button (header/headerQuickTools.ts). */
  "agent.browser": { selector: '.acpmux-header-tools [data-quick-action="browser"]', side: "bottom" },
  /** The header's Inspector or Summary toggle (header/PanelToggle.tsx). */
  "agent.inspector": { selector: ".acpmux-header-tools .acpmux-header-panel-toggle", side: "bottom" },
  /** The composer (ComposerBox.tsx), for a feature typed there (/btw). */
  "composer.prompt": { selector: ".acpmux-composer-box", side: "top" },
};

/** The tips whose control this page has. */
export const PANE_TIPS: readonly FeatureTipEntry[] = (catalog as FeatureTipEntry[]).filter(
  (tip) => tip.anchor in PANE_TIP_ANCHORS,
);

function call<T>(method: string, params: Record<string, unknown>): Promise<T> {
  const direct = window.cmuxAcpmuxActions?.[method];
  return direct ? (direct(params) as Promise<T>) : postNative<T>(method, params);
}

const records = (reply: unknown): TipRecords => {
  const states = (reply as { states?: unknown } | null)?.states;
  if (!states || typeof states !== "object" || Array.isArray(states)) throw new Error("tips.state: no records");
  return Object.fromEntries(
    Object.entries(states).filter((entry): entry is [string, string] => typeof entry[1] === "string"),
  );
};

/** `tips.state {}` reads the records; `{id, state}` keeps one. An older app refuses both: no tips. */
export const paneTipHost: TipHost = {
  read: () => call<unknown>("tips.state", {}).then(records),
  write: (id, state) => call<unknown>("tips.state", { id, state }).then(records),
};

const launch = typeof window === "undefined" ? undefined : storageLaunchStore(safeStorage(), window);

function safeStorage(): Storage | undefined {
  try {
    return window.localStorage;
  } catch {
    return undefined;
  }
}

/** A draft in the composer counts as typing: the person is mid-thought. */
export function composerHasDraft(doc: Document = document): boolean {
  const field = doc.querySelector(".acpmux-composer-box .ProseMirror");
  if (field && (field.textContent ?? "").trim() !== "") return true;
  return [...doc.querySelectorAll<HTMLTextAreaElement>(".acpmux-composer-box textarea")].some(
    (area) => area.value.trim() !== "",
  );
}

/** The chat's tips: mounted once per chat page (App.tsx), drawn in a portal. The gallery passes its
 *  own records, launch store and schedule; the app uses the defaults. */
export function PaneFeatureTips({
  streaming,
  host = paneTipHost,
  launchStore = launch,
  schedule,
}: {
  streaming: boolean;
  host?: TipHost;
  launchStore?: LaunchStore;
  schedule?: FeatureTipHostProps["schedule"];
}) {
  const enabled = useFeatureTipsOn();
  const t = useT();
  if (!launchStore || PANE_TIPS.length === 0) return null;
  return (
    <FeatureTipHost
      tips={PANE_TIPS}
      anchors={PANE_TIP_ANCHORS}
      enabled={enabled}
      streaming={streaming}
      typing={composerHasDraft}
      host={host}
      launch={launchStore}
      labels={{ new: t("featureTip.new"), close: t("featureTip.close") }}
      look="glass"
      schedule={schedule}
    />
  );
}
