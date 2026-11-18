// The Tasks page's small marks: status, priority, attention, assignee and labels. Status and label
// colors are Ghostty palette indices drawn from the terminal theme (`--tasks-ansi-N`, palette.ts), so
// Tasks always matches the person's theme; few words, glyphs carry status, priority and people.
import { Icon } from "../../agent-session/acpmux/icons/Icon";
import { AgentMark } from "../../agent-session/shared/AgentMark";
import { shortName, stableId } from "./model";
import type { Attention, Category, Label, Principal, AgentRef, Priority } from "./types";
import type { Strings } from "../shared/i18n";

export const ansi = (index: number) => `var(--tasks-ansi-${index}, var(--page-text-2))`;

const STATUS_ICONS: Record<Category, string> = {
  triage: "task.status.triage",
  backlog: "task.status.backlog",
  unstarted: "task.status.todo",
  started: "task.status.started",
  completed: "task.status.done",
  canceled: "task.status.canceled",
};

/** Status as the pack's task status icon in the status's palette color. */
export function StatusMark({ category, color, title }: { category: Category; color: number; title?: string }) {
  return (
    <span
      className={`tasks-status-mark${category === "canceled" ? " canceled" : ""}`}
      style={{ color: ansi(color) }}
      title={title}
    >
      <Icon name={STATUS_ICONS[category]} size={12} />
    </span>
  );
}

/** A filled circle in the current color (drawn, so its size is not a layout length). */
export function Dot({ size, color, title }: { size: number; color?: string; title?: string }) {
  return (
    <svg
      className="tasks-dot"
      width={size}
      height={size}
      viewBox="0 0 2 2"
      style={color ? { color } : undefined}
      role={title ? "img" : undefined}
      aria-label={title}
      aria-hidden={title ? undefined : "true"}
    >
      {title ? <title>{title}</title> : null}
      <circle cx="1" cy="1" r="1" fill="currentColor" />
    </svg>
  );
}

/** Priority as signal bars; urgent is a filled square with "!". */
export function PriorityMark({ priority }: { priority: Priority | undefined }) {
  if (!priority || priority === "none")
    return <svg className="tasks-priority" width={12} height={12} aria-hidden="true" />;
  if (priority === "urgent") {
    return (
      <svg className="tasks-priority urgent" width={12} height={12} viewBox="0 0 12 12" aria-hidden="true">
        <rect width="12" height="12" rx="3" />
        <rect className="mark" x="5.25" y="2.5" width="1.5" height="4.5" rx="0.75" />
        <rect className="mark" x="5.25" y="8.25" width="1.5" height="1.5" rx="0.75" />
      </svg>
    );
  }
  const filled = priority === "high" ? 3 : priority === "medium" ? 2 : 1;
  return (
    <svg className="tasks-priority bars" width={12} height={12} viewBox="0 0 12 12" aria-hidden="true">
      {[0, 1, 2].map((bar) => (
        <rect
          key={bar}
          className={bar < filled ? "on" : undefined}
          x={1.25 + bar * 3.5}
          y={11 - (4 + bar * 3)}
          width="2.5"
          height={4 + bar * 3}
          rx="1"
        />
      ))}
    </svg>
  );
}

/** A plan's progress: a thin track filled to `done` of `total`. */
export function Progress({ done, total }: { done: number; total: number }) {
  const width = (100 * done) / Math.max(total, 1);
  return (
    <svg
      className="tasks-progress"
      width="100%"
      height={3}
      viewBox="0 0 100 3"
      preserveAspectRatio="none"
      aria-hidden="true"
    >
      <rect className="track" width="100" height="3" />
      <rect className="fill" width={width} height="3" />
    </svg>
  );
}

export function attentionLabel(attention: Attention, strings: Strings): string {
  switch (attention) {
    case "needs_input":
      return strings.t("inbox.needsInput");
    case "failed":
      return strings.t("inbox.failed");
    case "review":
      return strings.t("inbox.review");
  }
}

/** Why a task needs attention, as a colored dot. */
export function AttentionDot({ attention, strings }: { attention: Attention | null | undefined; strings: Strings }) {
  if (!attention) return null;
  return (
    <span className={`tasks-attention ${attention}`}>
      {/* icon-scale-allow: a status dot, not an icon; it sits in a 12 px row slot */}
      <Dot size={7} title={attentionLabel(attention, strings)} />
    </span>
  );
}

/** A person's initial, or an agent's mark. */
export function AssigneeBadge({
  assignee,
  delegate,
  strings,
  size = 18,
}: {
  assignee: Principal | null | undefined;
  delegate: AgentRef | null | undefined;
  strings: Strings;
  size?: number;
}) {
  if (delegate) {
    return (
      <span className="tasks-assignee agent" style={{ width: size, height: size }} title={delegate.harness}>
        <AgentMark agent={delegate.harness} size={Math.round(size * 0.62)} />
      </span>
    );
  }
  const id = stableId(assignee);
  if (id) {
    const name = shortName(id);
    return (
      <span className="tasks-assignee person" style={{ width: size, height: size, fontSize: size * 0.5 }} title={name}>
        {name.slice(0, 1).toUpperCase()}
      </span>
    );
  }
  return (
    <span
      className="tasks-assignee nobody"
      style={{ width: size, height: size }}
      title={strings.t("detail.unassigned")}
    />
  );
}

/** Labels as colored dots; names on hover. */
export function LabelDots({ labels }: { labels: readonly Label[] }) {
  if (!labels.length) return null;
  return (
    <span className="tasks-label-dots">
      {labels.map((label) => (
        // icon-scale-allow: a label color dot, not an icon
        <Dot key={label.id} size={6} color={ansi(label.color)} title={label.name} />
      ))}
    </span>
  );
}

/** Labels as small text chips (board cards, detail). */
export function LabelChips({ labels }: { labels: readonly Label[] }) {
  if (!labels.length) return null;
  return (
    <span className="tasks-label-chips">
      {labels.map((label) => (
        <span key={label.id} className="tasks-label-chip">
          {/* icon-scale-allow: a label color dot inside a caption chip, not an icon */}
          <Dot size={5} color={ansi(label.color)} />
          {label.name}
        </span>
      ))}
    </span>
  );
}
