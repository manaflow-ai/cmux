// What runs now as its mark and its number, no word (Leo, 2026-11-23: ""running" doesn't need text.
// it can usually just be. you can put symbols for state. and state can fucking only be relevant when
// you may need to investigate/take action."). The subagents' mark is the composer hat's (trayHeadKinds.ts
// SUBAGENT_ICON); hover and VoiceOver still name the count ("3 running"). Waiting, failed and the
// other states that ask something of the person keep their words beside it.
import type { ReactNode } from "react";
import { Icon } from "../icons/Icon";
import type { CountPart } from "./countParts";
import "./LiveCount.css";

export const LIVE_COUNT_ICON = "task.ai";

export function LiveCount({ n, label }: { n: number; label: string }) {
  return (
    <span
      className="acpmux-live-count"
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- an icon and a number with a spoken name, not an image file
      role="img"
      aria-label={label}
      title={label}
    >
      <Icon name={LIVE_COUNT_ICON} size={12} row />
      {n}
    </span>
  );
}

/// The parts, " · " between, as the surface's line drew them before.
export function CountLine({ parts }: { parts: readonly CountPart[] }) {
  const out: ReactNode[] = [];
  parts.forEach((part, index) => {
    if (index > 0) out.push(" · ");
    out.push(
      typeof part === "string" ? (
        <span key={index}>{part}</span>
      ) : (
        <LiveCount key={index} n={part.live} label={part.label} />
      ),
    );
  });
  return <>{out}</>;
}
