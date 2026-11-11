// Under a prompt sent with `acpmux send` from a harness or an app, where it came from: a sender chip
// ("Claude desktop · <chat>") that opens the sending chat when acpmux knows it, and says whether
// acpmux confirmed it or the sender only reported it (sentFromHarness.ts). The chip is the transcript's
// sender chip (AgentTag around SenderIdentityLabel), not one of its own.
import { useEffect } from "react";
import { useT } from "../i18n";
import { SenderIdentityLabel } from "../SenderIdentityLabel";
import type { SenderIdentity } from "../senderIdentity";
import { openSenderChat } from "../rows/rowActions";
import { AgentTag } from "./AgentTag";
import { openSessionAttributes } from "./menuParts";
import { useTranscriptReadOnly } from "./readOnly";
import { useSessionRef } from "./sessionRefModel";
import { resolveSessionRef, sessionRefsResolve, whenIdle } from "./sessionRefs";
import type { SentFrom } from "./sentFromHarness";

export function SentFromLine({ from, host }: { from: SentFrom; host?: string }) {
  const t = useT();
  const readOnly = useTranscriptReadOnly();
  // The harness's own session id names the chat when acpmux runs or adopted it (`agentSessionId`).
  const query = !readOnly && sessionRefsResolve() ? from.sessionId : undefined;
  const target = useSessionRef(query, false);
  useEffect(
    () => (query && target === undefined ? whenIdle(() => void resolveSessionRef(query)) : undefined),
    [query, target],
  );
  const name = target?.name ? `${from.label} · ${target.name}` : from.label;
  const identity: SenderIdentity = {
    name,
    // A claim the daemon did not confirm draws no harness's mark: the chip names the found program.
    ...(!from.claimedLabel && { harness: from.harness }),
    known: !!target,
    ...((host ?? target?.host) && { host: host ?? target?.host }),
  };
  const how = from.confirmed
    ? t("sentFrom.checked", { app: from.checked?.app ?? from.label })
    : from.claimedLabel
      ? t("message.claimedNotProven", { name: from.claimedLabel })
      : t("sentFrom.selfReported");
  const title = [t("sentFrom.title", { name: from.label }), how, from.checked?.signedBy].filter(Boolean).join("\n");
  const label = <SenderIdentityLabel identity={identity} describe={false} />;
  return (
    <div className="cv-user__status cv-user__sent-from" data-confirmed={from.confirmed ? "" : undefined}>
      {target?.sessionId ? (
        <AgentTag
          name={label}
          title={title}
          ariaLabel={t("subagents.open", { name })}
          attributes={openSessionAttributes(target.sessionId, true)}
          onClick={() => openSenderChat(target.sessionId)}
        />
      ) : (
        <AgentTag name={label} title={title} />
      )}
      {!from.confirmed && <span className="cv-user__sent-from-note">{t("sentFrom.selfReportedShort")}</span>}
    </div>
  );
}
