// "Who else is working on these files" (whoElseCalls.ts) as one compact card in place of raw Bash
// or MCP output: a line saying how many other sessions touch the files, then one row per session
// with its name as a link chip that opens its chat, its harness and machine, branch and pull
// request, what it edited or read in common and how long ago. Leo, 2026-11-05: "I kind of like
// this where like Claude sometimes decides to look up who else is working on stuff potentially".
import { useContext, useId, useMemo } from "react";
import type { AcpmuxActivity } from "../model";
import { useT, type Translate } from "../i18n";
import { SubsessionContext } from "../subagents/subsessions";
import { AgentTag } from "./AgentTag";
import { useFindReveal } from "./chatFind";
import { ChevronRight, ToolGroup } from "./icons";
import { openSessionAttributes } from "./menuParts";
import { useTranscriptReadOnly } from "./readOnly";
import { resolveSessionRef } from "./sessionRefs";
import { useTranscriptDisclosure } from "./transcriptDisclosureModel";
import { pullLabel, type WhoElseCall, type WhoElseSession } from "./whoElseCalls";
import "./WhoElseCard.css";
import { whatText } from "./whoElseCardModel";
import { signed } from "../../../ui/Typography";

/// Rows shown before "N more" opens the rest.
const ROWS_SHOWN = 5;
export function WhoElseCard({ item, call }: { item: AcpmuxActivity; call: WhoElseCall }) {
  const t = useT();
  const listId = useId();
  const [open, setOpen] = useTranscriptDisclosure(`who-else:${item.tool?.id ?? item.text}`);
  useFindReveal(
    useMemo(() => [item], [item]),
    () => setOpen(true),
  );
  const answer = call.answer;
  const sessions = answer?.sessions ?? [];
  // Sessions acpmux left out of its answer (past its row cap) count in the line, but no row can
  // show them: "N more" opens only the rows the answer holds, and a note names the rest.
  const omitted = answer?.more ?? 0;
  const total = sessions.length + omitted;
  const line = call.pending
    ? t("whoElse.looking")
    : total === 0
      ? t("whoElse.none")
      : t(total === 1 ? "whoElse.one" : "whoElse.many", { count: String(total) });
  const shown = open ? sessions : sessions.slice(0, ROWS_SHOWN);
  const hidden = sessions.length - shown.length;
  return (
    <div className="cv-who-else" data-who-else="" data-count={sessions.length}>
      <div className={`cv-tool cv-who-else__line${call.pending ? " is-live" : " is-strong"}`}>
        <span className="cv-tool__icon">
          <ToolGroup />
        </span>
        <span className="cv-tool__text">{line}</span>
      </div>
      {shown.length > 0 && (
        <ul id={listId} className="cv-who-else__rows">
          {shown.map((s) => (
            <WhoElseRow key={`${s.host ?? ""}/${s.sessionId}`} session={s} />
          ))}
        </ul>
      )}
      {hidden > 0 && !open && (
        <button
          type="button"
          className="cv-who-else__more"
          aria-expanded={false}
          aria-controls={listId}
          onClick={() => setOpen(true)}
        >
          {/* One flex item, so the button's gap never parts the sign from its number. */}
          <span>{signed(t("whoElse.more", { count: String(hidden) }))}</span>
          <ChevronRight size={12} className="cv-tool__chevron cv-rotor" />
        </button>
      )}
      {omitted > 0 && (hidden === 0 || open) && (
        <div className="cv-who-else__note">{t("whoElse.omitted", { count: String(omitted) })}</div>
      )}
      {answer && answer.unreached.length > 0 && (
        <div className="cv-who-else__note">{t("whoElse.unreached", { hosts: answer.unreached.join(", ") })}</div>
      )}
    </div>
  );
}

function WhoElseRow({ session: s }: { session: WhoElseSession }) {
  const t = useT();
  const subsessions = useContext(SubsessionContext);
  const readOnly = useTranscriptReadOnly();
  const openChat = subsessions?.openSender ?? subsessions?.open;
  const canOpen = !readOnly && openChat !== undefined;
  // A session here opens by its id; a peer's by `HOST/NAME`, which the daemon resolves.
  const onOpen = canOpen
    ? () => {
        if (!s.host && s.sessionId) return openChat(s.sessionId);
        void resolveSessionRef(s.ref).then((target) => {
          if (target) openChat(target.sessionId);
          else subsessions?.senderMissing?.(s.ref);
        });
      }
    : undefined;
  const name = s.host ? `${s.host}/${s.name}` : s.name;
  const title = s.host ? t("subagents.openOnHost", { name: s.name, host: s.host }) : t("subagents.open", { name });
  const where = [s.harness, s.branch].filter(Boolean).join(" · ");
  return (
    <li className="cv-who-else__row" data-live={s.live ? "" : undefined}>
      <div className="cv-who-else__head">
        <span className={`cv-who-else__dot${s.live ? " is-live" : ""}`} aria-hidden="true" />
        <AgentTag
          name={name}
          title={title}
          ariaLabel={title}
          onClick={onOpen}
          attributes={
            !s.host && s.sessionId
              ? openSessionAttributes(s.sessionId, subsessions?.openSender !== undefined)
              : undefined
          }
        />
        {where && <span className="cv-who-else__where">{where}</span>}
        {s.pullRequests.slice(0, 2).map((url) => (
          <a key={url} className="cv-who-else__pr" href={url} rel="noreferrer" target="_blank">
            {pullLabel(url)}
          </a>
        ))}
        <span className="cv-who-else__ago">{agoText(t, s.agoMs)}</span>
      </div>
      <div className="cv-who-else__what">{signed(whatText(t, s))}</div>
    </li>
  );
}

function agoText(t: Translate, ms: number): string {
  const minutes = Math.floor(ms / 60_000);
  if (minutes < 1) return t("whoElse.now");
  if (minutes < 60) return t("whoElse.minutes", { count: String(minutes) });
  if (minutes < 48 * 60) return t("whoElse.hours", { count: String(Math.floor(minutes / 60)) });
  return t("whoElse.days", { count: String(Math.floor(minutes / 1440)) });
}
