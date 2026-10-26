// A first-class ACP dispatch operation. Dispatch, steer, brief listing and report calls get a
// compact coordination row; they never fall through to ToolRow, where a shell command or file
// diff would make the coordinator's protocol activity look like ad hoc terminal work.
import { useId, useMemo } from "react";
import type { AcpmuxActivity } from "../model";
import { useFindReveal } from "./chatFind";
import { ChevronRight, Envelope, Spinner, ToolGroup } from "./icons";
import { CopyButton } from "./CopyButton";
import { useTranscriptDisclosure } from "./transcriptDisclosure";
import { useT, type Translate } from "../i18n";
import type { DispatchCall } from "./dispatchCalls";
import { messagePreview } from "./AgentMessageRow";
import "./DispatchCard.css";

export function DispatchCard({ item, call }: { item: AcpmuxActivity; call: DispatchCall }) {
  const t = useT();
  const detailsId = useId();
  const [open, setOpen] = useTranscriptDisclosure(`dispatch:${item.tool?.id ?? item.text}`);
  useFindReveal(
    useMemo(() => [item], [item]),
    () => setOpen(true),
  );
  const tool = item.tool;
  const running = call.status === "running" || tool?.status === "pending" || tool?.status === "in_progress";
  const target = call.to ?? call.sessionId ?? call.host;
  const destination = target && call.host && target !== call.host ? `${target} · ${call.host}` : target;
  const preview = messagePreview(call.text ?? call.summary ?? "");
  const title = call.title ? `'${call.title}'` : preview ? `'${preview}'` : t("message.unknown");
  const line = lineLabel(t, call, title, destination);
  const briefId = call.reportBriefId ?? call.briefId;
  const anchor = briefId ? briefAnchor(briefId) : undefined;
  // l10n-allow: clipboard format is machine-readable context, not rendered pane copy.
  const copyText = [
    call.title && `Title: ${call.title}`,
    call.text && `Brief: ${call.text}`,
    call.summary && call.summary !== call.text && `Report: ${call.summary}`,
    call.from && `From: ${call.from}`,
    destination && `To: ${destination}`,
    call.stopCondition && `Stop condition: ${call.stopCondition}`,
  ]
    .filter(Boolean)
    .join("\n");
  return (
    <div
      className={`cv-dispatch cv-dispatch--${call.kind}`}
      id={call.kind === "dispatch" && anchor ? anchor : undefined}
      data-dispatch-kind={call.kind}
      data-brief-id={briefId}
      data-from={call.from}
      data-status={call.status}
    >
      <button
        type="button"
        className={`cv-tool cv-dispatch__line is-toggle${running ? " is-live" : " is-strong"}`}
        aria-expanded={open}
        aria-controls={open ? detailsId : undefined}
        aria-label={line}
        onClick={() => setOpen((value) => !value)}
      >
        <span className="cv-tool__icon">
          {running ? <Spinner size={16} /> : call.kind === "report" ? <Envelope /> : <ToolGroup />}
        </span>
        <span className="cv-tool__text">{line}</span>
        <ChevronRight
          size={14}
          strokeWidth={1.2}
          className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`}
        />
      </button>
      {call.kind === "report" && anchor && (
        <a
          className="cv-dispatch__link"
          href={`#${anchor}`}
          aria-label={t("message.label", {
            from: call.from ?? t("message.self"),
            to: call.title ?? call.briefId ?? t("message.unknown"),
          })}
        >
          {call.title ?? call.briefId ?? t("message.unknown")}
        </a>
      )}
      {open && (
        <div id={detailsId} className="cv-dispatch__body selectable">
          {call.kind === "report" && (anchor || call.title) && (
            <div className="cv-dispatch__brief-link">
              {anchor ? <a href={`#${anchor}`}>{call.title ?? call.briefId ?? t("message.unknown")}</a> : call.title}
            </div>
          )}
          {call.text && <div className="cv-dispatch__text">{call.text}</div>}
          {call.summary && call.summary !== call.text && <div className="cv-dispatch__text">{call.summary}</div>}
          {(call.from || destination || call.stopCondition || call.briefId) && (
            <div className="cv-dispatch__meta">
              {(call.from || destination) && (
                <span>
                  {t("message.label", {
                    from: call.from ?? t("message.self"),
                    to: destination ?? t("message.unknown"),
                  })}
                </span>
              )}
              {call.stopCondition && <span>{call.stopCondition}</span>}
              {call.briefId && <span>{call.briefId}</span>}
            </div>
          )}
          {copyText && <CopyButton text={copyText} label={t("turn.copy")} className="cv-iconbtn cv-iconbtn--compact" />}
        </div>
      )}
    </div>
  );
}

export function lineLabel(t: Translate, call: DispatchCall, title: string, destination: string | undefined): string {
  const target = destination ? ` → ${destination}` : "";
  switch (call.kind) {
    case "dispatch":
      return t("message.sentTo", { to: `${title}${target}` });
    case "steer":
      return `${t("subsession.sent", { name: destination ?? t("message.unknown"), text: title })}${statusLabel(t, call.status)}`;
    case "report":
      return `${t("message.label", {
        from: call.from ?? t("message.self"),
        to: call.title ?? call.briefId ?? t("message.unknown"),
      })}${statusLabel(t, call.status)}`;
    case "briefs":
      return t("tools.mcp.list", {
        target: call.summary ?? (call.count === undefined ? t("message.unknown") : call.count),
      });
  }
}

function statusLabel(t: Translate, status: string | undefined): string {
  if (!status) return "";
  const label =
    status === "running"
      ? t("tools.runningUnnamed")
      : status === "failed"
        ? t("tools.failed")
        : status === "merged"
          ? t("summary.pr.merged")
          : status === "reported" || status === "steered"
            ? t("message.sent")
            : "";
  return label ? ` · ${label}` : "";
}

export function briefAnchor(id: string): string {
  return `brief-${id.replace(/[^a-zA-Z0-9_-]/g, "-")}`;
}
