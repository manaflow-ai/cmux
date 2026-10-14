// The composer strip's subagents (ComposerStrip.tsx): each running one as a compact chip, its name,
// its status glyph and its time; a click shows it (the chat's `onSubagent`: its own pane right of
// the chat). More than two, or a strip short of room (`collapsed`), show one chip naming how many,
// whose popover lists them; shorter still (`compact`), that chip shows the count alone.
import { formatDuration } from "../conversation/turns";
import { useT, type StringKey } from "../i18n";
import { Icon } from "../icons/Icon";
import { ChevronIcon } from "../ComposerPickers";
import { useLocationPopover } from "../locationPopover";
import { Popover } from "../../../ui/Popover";
import { usePopoverTrigger } from "../../../ui/popoverTrigger";
import { elapsed, useNow } from "../subagents/SubagentGroup";
import type { SubagentStatus } from "../summary/SubagentStatusList";
import type { StripSubagent } from "./subagentPresence";

/// More than this many collapse to one chip.
const SHOWN = 2;

const GLYPH: Record<SubagentStatus, string> = {
  running: "status.running",
  waiting: "status.needsinput",
  done: "status.success",
  failed: "status.error",
};

const STATUS_LABEL: Record<SubagentStatus, StringKey> = {
  running: "subagents.state.running",
  waiting: "subagents.state.waiting",
  done: "subagents.state.completed",
  failed: "subagents.state.failed",
};

export function StripSubagents({
  entries,
  collapsed,
  compact = false,
  onOpen,
}: {
  entries: readonly StripSubagent[];
  collapsed: boolean;
  compact?: boolean;
  onOpen?: (id: string) => void;
}) {
  const t = useT();
  const now = useNow(entries.some((entry) => entry.status === "running" || entry.status === "waiting"));
  if (entries.length === 0) return null;
  const chip = ({ agent, status, leaving }: StripSubagent, inMenu = false, close?: () => void) => {
    const time = formatDuration(elapsed(agent, now));
    return (
      <button
        key={agent.id}
        type="button"
        className={inMenu ? "acpmux-menu-item acpmux-strip-menu-row" : "acpmux-strip-chip acpmux-strip-agent"}
        data-status={status}
        data-subagent={agent.id}
        data-leaving={leaving ? "" : undefined}
        aria-label={`${agent.name}, ${t(STATUS_LABEL[status])}, ${time}`}
        title={agent.task ?? agent.name}
        disabled={!onOpen}
        onClick={() => {
          close?.();
          onOpen?.(agent.id);
        }}
      >
        <span className="acpmux-strip-glyph" data-status={status}>
          <Icon name={GLYPH[status]} size={12} />
        </span>
        <span className="acpmux-strip-label">{agent.name}</span>
        <span className="acpmux-strip-time">{time}</span>
      </button>
    );
  };
  if (!collapsed && entries.length <= SHOWN)
    return <span className="acpmux-strip-agents">{entries.map((entry) => chip(entry))}</span>;
  return <SubagentsMenu entries={entries} chip={chip} compact={compact} />;
}

function SubagentsMenu({
  entries,
  chip,
  compact,
}: {
  entries: readonly StripSubagent[];
  compact: boolean;
  chip: (entry: StripSubagent, inMenu: boolean, close: () => void) => React.ReactNode;
}) {
  const t = useT();
  const { control, anchor, open, setOpen, side } = useLocationPopover();
  const press = usePopoverTrigger(open, setOpen);
  const count = entries.filter((entry) => !entry.leaving).length;
  const status: SubagentStatus = entries.some((entry) => entry.status === "waiting")
    ? "waiting"
    : entries.some((entry) => entry.status === "running")
      ? "running"
      : (entries[0]?.status ?? "done");
  const label = t("subagents.count", { n: count });
  return (
    <span ref={control} className="acpmux-strip-agents">
      <button
        type="button"
        className="acpmux-strip-chip acpmux-strip-agents-summary"
        data-status={status}
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-label={label}
        {...press}
      >
        <span className="acpmux-strip-glyph" data-status={status}>
          <Icon name={GLYPH[status]} size={12} />
        </span>
        <span className="acpmux-strip-label">{compact ? count : label}</span>
        <span className="ui-ghost-icon" aria-hidden="true">
          <ChevronIcon />
        </span>
      </button>
      <Popover
        open={open}
        onOpenChange={setOpen}
        anchor={open ? anchor : null}
        label={t("summary.subagents")}
        className="acpmux-menu acpmux-location-menu acpmux-strip-menu"
        side={side}
        flip={false}
      >
        {entries.map((entry) => chip(entry, true, () => setOpen(false)))}
      </Popover>
    </span>
  );
}
