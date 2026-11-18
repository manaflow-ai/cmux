import { useCallback } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { useLabelClock } from "../clock";
import { usePaneLanguage } from "../i18n";
import { Tooltip } from "../../../ui/Tooltip";
import { timeHoverDate } from "./timeHoverDate.experiment";
import { timeHoverWording } from "./timeHoverWording.experiment";
import type { ReactNode } from "react";
import { type TimeToken, timestampHoverLabel, nextTimestampHover } from "./timeHoverModel";

export function TimeHover({ token }: { token: TimeToken }): ReactNode {
  const { messageAt } = token;
  const wording = experimentArm(timeHoverWording);
  const date = experimentArm(timeHoverDate);
  const next = useCallback(
    (at: number, now: number) => nextTimestampHover(at, now, messageAt, wording, date),
    [messageAt, wording, date],
  );
  const now = useLabelClock(token.at, next);
  const locale = usePaneLanguage();
  const label = timestampHoverLabel(token.at, now, locale, messageAt, wording, date);
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
