import { useContext } from "react";
import { useT } from "../i18n";
import { TurnActionsContext } from "../conversation/turnActions";
import "./tripwires.css";

export type TripwireVerdict = "none" | "backed" | "failed";

export type Tripwire = {
  name: string;
  path: string;
  verdict: TripwireVerdict;
  toolCallId?: string;
  command?: string;
};

export type TripwireLook = "dots" | "underline" | "rows";

type Props = {
  items: readonly Tripwire[];
  compact?: boolean;
  look?: TripwireLook;
  /** Optional bridge for the header, which is rendered outside the transcript action context. */
  onShowCall?: (toolCallId: string) => boolean;
};

const MAX_TRIPWIRES = 8;

function statusText(t: ReturnType<typeof useT>, item: Tripwire): string {
  const command = item.command ?? item.path;
  return item.verdict === "backed"
    ? t("tripwire.passed", { name: item.name, path: item.path, command })
    : item.verdict === "failed"
      ? t("tripwire.failed", { name: item.name, path: item.path, command })
      : t("tripwire.pending", { name: item.name, path: item.path });
}

function ariaText(t: ReturnType<typeof useT>, item: Tripwire): string {
  return statusText(t, item);
}

function TripwireItem({
  item,
  t,
  look,
  showCall,
}: {
  item: Tripwire;
  t: ReturnType<typeof useT>;
  look: TripwireLook;
  showCall?: (toolCallId: string) => boolean;
}) {
  const label = ariaText(t, item);
  const className = `acpmux-tripwire acpmux-tripwire--${item.verdict} acpmux-tripwire--${look}`;
  const content = (
    <>
      <span className="acpmux-tripwire-dot" aria-hidden="true" />
      <span className="acpmux-tripwire-name">{item.name}</span>
      {look === "rows" && <span className="acpmux-tripwire-path">{item.path}</span>}
    </>
  );
  if (!item.toolCallId || !showCall) {
    return (
      <span className={className} data-tripwire-verdict={item.verdict} title={label} aria-label={label}>
        {content}
      </span>
    );
  }
  return (
    <a
      className={className}
      data-tripwire-verdict={item.verdict}
      href={`#tool-${item.toolCallId}`}
      title={label}
      aria-label={label}
      onClick={(event) => {
        event.preventDefault();
        showCall(item.toolCallId!);
      }}
    >
      {content}
    </a>
  );
}

/** A quiet, fixed-height progress strip for the checks an approved plan promised. */
export function TripwireStatus({ items, compact = true, look = "dots", onShowCall }: Props) {
  const t = useT();
  const { showCall: contextShowCall } = useContext(TurnActionsContext);
  const navigateToCall = onShowCall ?? contextShowCall;
  const shown = items.slice(0, MAX_TRIPWIRES);
  if (shown.length === 0) return null;
  const unresolved = items.filter((item) => item.verdict !== "backed").length;
  const label = t("tripwire.summary", { count: items.length, unresolved });
  return (
    <div
      className={`acpmux-tripwire-status${compact ? " acpmux-tripwire-status--compact" : ""}`}
      data-tripwire-count={shown.length}
      data-tripwire-total={items.length}
      data-tripwire-unresolved={unresolved}
      data-tripwire-complete={unresolved === 0 ? "true" : "false"}
      aria-label={label}
      role="status"
    >
      {shown.map((item) => (
        <TripwireItem key={`${item.path}:${item.name}`} item={item} t={t} look={look} showCall={navigateToCall} />
      ))}
    </div>
  );
}

/** Closing recap treatment. It keeps every check visible and explicitly marks unfinished work. */
export function TripwireRecap(props: Props) {
  return <TripwireStatus {...props} compact={false} look={props.look ?? "rows"} />;
}
