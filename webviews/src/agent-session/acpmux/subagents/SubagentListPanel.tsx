import { useState, type ComponentProps } from "react";
import { useT } from "../i18n";
import { SubagentStatusList } from "../summary/SubagentStatusList";

export const SUBAGENT_LIST_REVEAL = "subagents:list";

/** Only a native reveal turns a destination tab into the full subagent list. */
export function useSubagentList(call: (method: string, params: Record<string, unknown>) => Promise<unknown>) {
  const [shown, setShown] = useState(false);
  return {
    shown,
    show: () => void call("chat.subagentList", {}).catch(() => undefined),
    reveal: (value: string) => {
      const list = value === SUBAGENT_LIST_REVEAL;
      setShown(list);
      return list;
    },
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
