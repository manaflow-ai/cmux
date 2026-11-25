import { type Translate } from "../i18n";
import { type DispatchCall } from "./dispatchCalls";

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
