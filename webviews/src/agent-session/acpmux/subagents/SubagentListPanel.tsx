import { useState, type ComponentProps } from "react";
import { useT } from "../i18n";
import { Close } from "../conversation/icons";
import { SubagentStatusList } from "../summary/SubagentStatusList";

/** View all shares the document preview's right-side surface and lists every subagent. */
export function useSubagentList(
  session: string | undefined,
  props: ComponentProps<typeof SubagentStatusList>,
  preview?: unknown,
) {
  const [opened, setOpened] = useState<{ session: string | undefined; preview: unknown }>();
  if (opened && (opened.session !== session || opened.preview !== preview)) setOpened(undefined);
  const t = useT();
  const panel =
    opened && opened.session === session ? (
      // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- Escape closes the companion list.
      <aside
        className="acpmux-artifact"
        aria-label={t("summary.subagents")}
        // ui-allow: Escape closes the side panel from its rows.
        onKeyDown={(event) => {
          if (event.key === "Escape") {
            event.preventDefault();
            setOpened(undefined);
          }
        }}
      >
        <div className="acpmux-artifact-bar">
          <span className="acpmux-artifact-title">{t("summary.subagents")}</span>
          <button
            type="button"
            className="cv-iconbtn"
            aria-label={t("artifact.close")}
            onClick={() => setOpened(undefined)}
          >
            <Close size={16} />
          </button>
        </div>
        <div className="acpmux-artifact-body">
          <SubagentStatusList {...props} />
        </div>
      </aside>
    ) : null;
  return { show: () => setOpened({ session, preview }), panel };
}
