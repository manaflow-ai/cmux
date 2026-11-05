import { useLabelClock } from "../clock";
import { usePaneLanguage } from "../i18n";

import { Tooltip } from "../../../ui/Tooltip";

import type { ReactNode } from "react";
import { type TimeToken, timestampHoverLabel, nextTimestampHover } from "./timeHoverModel";

export function TimeHover({ token }: { token: TimeToken }): ReactNode {
  const now = useLabelClock(token.at, nextTimestampHover);
  const locale = usePaneLanguage();
  const label = timestampHoverLabel(token.at, now, locale);
  return (
    <Tooltip label={label} side="top">
      <time
        className="cv-time-hover"
        dateTime={new Date(token.at).toISOString()}
        // oxlint-disable-next-line jsx-a11y/no-noninteractive-tabindex -- timestamp tooltips are keyboard-focusable without an action
        tabIndex={0}
        aria-label={`${token.source}, ${label}`}
      >
        {token.source}
      </time>
    </Tooltip>
  );
}
