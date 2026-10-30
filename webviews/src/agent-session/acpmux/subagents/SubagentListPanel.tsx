import { useCallback, useState, type ComponentProps } from "react";
import { useT } from "../i18n";
import { SubagentStatusList } from "../summary/SubagentStatusList";
import { nativePaneResult, type SubagentPaneResult } from "./subagentPanes";

export const SUBAGENT_LIST_REVEAL = "subagents:list";

/** Only a native reveal turns a destination tab into the full subagent list. `show` asks the app for
 * that tab; on "refused" (no app, or no pane opened) the caller lists them in place instead. */
export function useSubagentList(call: (method: string, params: Record<string, unknown>) => Promise<unknown>) {
  const [shown, setShown] = useState(false);
  const show = useCallback((): Promise<SubagentPaneResult> => nativePaneResult(call("chat.subagentList", {})), [call]);
  const hide = useCallback(() => setShown(false), []);
  const reveal = useCallback((value: string) => {
    const list = value === SUBAGENT_LIST_REVEAL;
    setShown(list);
    return list;
  }, []);
  return {
    shown,
    show,
    hide,
    reveal,
  };
}

export function SubagentListPanel(props: ComponentProps<typeof SubagentStatusList>) {
  const t = useT();
  return (
    <section className="acpmux-main" aria-label={t("summary.subagents")}>
      <div className="acpmux-artifact-bar">
        <span className="acpmux-artifact-title">{t("summary.subagents")}</span>
      </div>
      <div className="acpmux-artifact-body">
        <SubagentStatusList {...props} />
      </div>
    </section>
  );
}
