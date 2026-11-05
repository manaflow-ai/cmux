import { useLabelClock } from "../clock";
import { usePaneLanguage } from "../i18n";

import { Tooltip } from "../../../ui/Tooltip";

import type { ReactNode } from "react";
import { type TimeToken, timestampHoverLabel, nextTimestampHover } from "./timeHoverModel";
/// Markdown's destination syntax also carries local paths, which `textLinks` intentionally does
/// not return when their extension or timestamp looks unlike a bare path. Preserve all balanced
/// destinations before inserting the parser's private time markers.
function markdownDestinations(text: string): { start: number; end: number }[] {
  const ranges: { start: number; end: number }[] = [];
  for (let marker = text.indexOf("]("); marker >= 0; marker = text.indexOf("](", marker + 2)) {
    const open = text.lastIndexOf("[", marker);
    if (open < 0 || text.slice(open + 1, marker).includes("]")) continue;
    let depth = 0;
    for (let at = marker + 2; at < text.length; at++) {
      const char = text[at];
      if (char === "(") depth++;
      else if (char === ")") {
        if (depth === 0) {
          ranges.push({ start: marker + 2, end: at });
          break;
        }
        depth--;
      }
    }
  }
  return ranges;
}

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
