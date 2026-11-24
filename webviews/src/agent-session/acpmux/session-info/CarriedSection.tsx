// Session Info's Carried memory: what other machines propose to add to the person's carried
// instructions and memory first, each proposal with its device, its time and its files (a file's diff
// opens under it), Accept and Drop on each and, past one proposal, Accept all and Drop all; then the
// files already carried here, each with its kind and size. Accept and Drop go to acpmux on the click
// (`_acpmux/agent_home_resolve`, person-only); a settled proposal leaves the list at once, and one
// acpmux refused stays with Try again. The model and the read: carriedSectionModel.ts.
import { useState } from "react";
import { Button } from "../../../ui/Button";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { fileSizeLabel } from "../fileAttachmentModel";
import { relativeTime } from "../conversation/relativeTime";
import { tooltipProps } from "../shortcuts";
import {
  parseResolution,
  type AgentHome,
  type CarriedEntry,
  type CarriedProposal,
  type CarriedResolution,
  type ResolveCarried,
} from "./carriedSectionModel";

const ROW_ICON = rowIconSize(12);

const KIND_ICON = { instructions: "file.text", memory: "file" } as const;

/// The folded header's value: "2 waiting · 14 files", "Off" when nothing follows the person here.
export function carriedSummary(
  t: ReturnType<typeof useT>,
  home: AgentHome | undefined,
  failed: boolean,
): string | undefined {
  if (!home) return failed ? t("carried.failed") : undefined;
  if (!home.configured) return t("carried.off");
  const parts: string[] = [];
  if (home.proposals.length > 0) parts.push(t("summary.subagents.waiting", { n: home.proposals.length }));
  parts.push(t("carried.files", { n: home.carried.length }));
  return parts.join(" · ");
}

type Pending = { state: "busy" | "failed"; reason?: string };

export function CarriedSection({
  home,
  failed = false,
  onResolve,
  onSettled,
  locale,
  now = Date.now(),
  openDiffs,
}: {
  home?: AgentHome;
  failed?: boolean;
  /// `_acpmux/agent_home_resolve`; without it the proposals list with no buttons.
  onResolve?: ResolveCarried;
  /// What acpmux settled, as it answers (the list drops those at once and reads again).
  onSettled?: (resolution: CarriedResolution) => void;
  locale?: string;
  now?: number;
  /// Gallery: the entries ("proposal id\u0000path") drawn with their diff open.
  openDiffs?: readonly string[];
}) {
  const t = useT();
  const [pending, setPending] = useState<Record<string, Pending>>({});
  if (!home) return failed ? <p className="acpmux-session-info-note">{t("carried.failed")}</p> : null;
  if (!home.configured) return null;
  const resolve = (accept: string[], drop: string[]) => {
    if (!onResolve) return;
    const ids = [...accept, ...drop];
    // Sent before anything else on the click: acpmux takes it only on a person's gesture.
    const sent = onResolve({ accept, drop });
    setPending((last) => ({ ...last, ...Object.fromEntries(ids.map((id) => [id, { state: "busy" as const }])) }));
    Promise.resolve(sent).then(
      (reply) => {
        const resolution = parseResolution(reply);
        const refused = new Map(resolution.refused.map((refusal) => [refusal.id, refusal.reason]));
        setPending((last) => {
          const next = { ...last };
          for (const id of ids)
            if (refused.has(id)) next[id] = { state: "failed", reason: refused.get(id) };
            else delete next[id];
          return next;
        });
        onSettled?.(resolution);
      },
      (error: unknown) =>
        setPending((last) => ({
          ...last,
          ...Object.fromEntries(
            ids.map((id) => [
              id,
              { state: "failed" as const, reason: error instanceof Error ? error.message : undefined },
            ]),
          ),
        })),
    );
  };
  const open = home.proposals
    .filter((proposal) => pending[proposal.id]?.state !== "busy")
    .map((proposal) => proposal.id);
  return (
    <ul className="acpmux-session-info-list" data-carried>
      {home.proposals.length > 0 && <li className="acpmux-session-info-note">{t("carried.proposed")}</li>}
      {home.proposals.map((proposal) => (
        <ProposalRows
          key={proposal.id}
          proposal={proposal}
          pending={pending[proposal.id]}
          onAccept={onResolve ? () => resolve([proposal.id], []) : undefined}
          onDrop={onResolve ? () => resolve([], [proposal.id]) : undefined}
          locale={locale}
          now={now}
          openDiffs={openDiffs}
        />
      ))}
      {onResolve && home.proposals.length > 1 && (
        <li className="acpmux-session-info-row" data-carried-batch>
          <span className="acpmux-session-info-row__end">
            <Button size="sm" variant="ghost" disabled={open.length === 0} onClick={() => resolve(open, [])}>
              {t("carried.acceptAll")}
            </Button>
            <Button size="sm" variant="ghost" disabled={open.length === 0} onClick={() => resolve([], open)}>
              {t("carried.dropAll")}
            </Button>
          </span>
        </li>
      )}
      {home.carried.length > 0 && <li className="acpmux-session-info-note">{t("carried.carried")}</li>}
      {home.carried.map((file) => (
        <li key={file.path} className="acpmux-session-info-row" data-carried-file={file.path}>
          <Icon name={KIND_ICON[file.kind]} size={ROW_ICON} row />
          <span className="acpmux-session-info-row__name">{file.path}</span>
          <span className="acpmux-session-info-row__detail">{t(`carried.kind.${file.kind}`)}</span>
          <span className="acpmux-session-info-row__end">{fileSizeLabel(file.bytes, locale ?? "en")}</span>
        </li>
      ))}
    </ul>
  );
}

function ProposalRows({
  proposal,
  pending,
  onAccept,
  onDrop,
  locale,
  now,
  openDiffs,
}: {
  proposal: CarriedProposal;
  pending?: Pending;
  onAccept?: () => void;
  onDrop?: () => void;
  locale?: string;
  now: number;
  openDiffs?: readonly string[];
}) {
  const t = useT();
  const busy = pending?.state === "busy";
  const failed = pending?.state === "failed";
  return (
    <>
      <li className="acpmux-session-info-row" data-carried-proposal={proposal.id}>
        <Icon name="devices.paired" size={ROW_ICON} row />
        <span className="acpmux-session-info-row__name">{proposal.device}</span>
        {proposal.at !== null && (
          <span className="acpmux-session-info-row__detail">{relativeTime(proposal.at, now, locale)}</span>
        )}
        {onAccept && onDrop && (
          <span className="acpmux-session-info-row__end" data-state={failed ? "failed" : undefined}>
            <Button
              size="sm"
              variant="ghost"
              disabled={busy}
              onClick={onAccept}
              {...(failed && pending?.reason ? tooltipProps(pending.reason, undefined) : {})}
            >
              {t(failed ? "carried.retry" : "carried.accept")}
            </Button>
            <Button size="sm" variant="ghost" disabled={busy} onClick={onDrop}>
              {t("carried.drop")}
            </Button>
          </span>
        )}
      </li>
      {proposal.entries.map((entry) => (
        <EntryRows
          key={entry.path}
          entry={entry}
          initiallyOpen={openDiffs?.includes(`${proposal.id}\u0000${entry.path}`) ?? false}
        />
      ))}
    </>
  );
}

function EntryRows({ entry, initiallyOpen }: { entry: CarriedEntry; initiallyOpen: boolean }) {
  const t = useT();
  const [open, setOpen] = useState(initiallyOpen);
  const diff = entry.diff;
  return (
    <>
      <li
        className="acpmux-session-info-row acpmux-carried-entry"
        data-carried-entry={entry.path}
        data-change={entry.change}
      >
        <Icon name={KIND_ICON[entry.kind]} size={ROW_ICON} row />
        <span className="acpmux-session-info-row__name">{entry.path}</span>
        <span className="acpmux-session-info-row__detail">{t(`carried.change.${entry.change}`)}</span>
        {diff && (
          <button
            type="button"
            className="acpmux-session-info-link acpmux-session-info-row__end"
            aria-expanded={open}
            onClick={() => setOpen(!open)}
          >
            {t(open ? "carried.hideDiff" : "carried.showDiff")}
          </button>
        )}
      </li>
      {diff && open && (
        <li className="acpmux-carried-diff" data-carried-diff={entry.path}>
          <pre>
            {diff.split("\n").map((line, index) => (
              <span
                key={index}
                className={
                  line.startsWith("+") ? "acpmux-diff-add" : line.startsWith("-") ? "acpmux-diff-del" : undefined
                }
              >
                {line}
                {"\n"}
              </span>
            ))}
          </pre>
        </li>
      )}
    </>
  );
}
