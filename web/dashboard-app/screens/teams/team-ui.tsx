"use client";

import { useTranslations } from "next-intl";
import { useState } from "react";
import { Badge } from "@/dashboard-app/components/settings-ui/feedback";
import { settingsButtonClass } from "@/dashboard-app/components/settings-ui/styles";
import { TeamApiError, type TeamRole, teamErrorCode } from "@/dashboard-app/queries/teams";
import { initialsFor, planLabelKey } from "./team-logic";

export function TeamAvatar({
  name,
  imageUrl,
  size = 32,
}: {
  readonly name: string | null;
  readonly imageUrl: string | null;
  readonly size?: number;
}) {
  const style = { width: size, height: size };
  if (imageUrl) {
    // Team and member images are arbitrary Stack-hosted URLs or data URLs;
    // next/image would need every origin allow-listed.
    // eslint-disable-next-line @next/next/no-img-element
    return <img src={imageUrl} alt="" style={style} className="shrink-0 border border-border object-cover" />;
  }
  return (
    <span
      aria-hidden="true"
      style={style}
      className="inline-flex shrink-0 items-center justify-center border border-border bg-code-bg text-[11px] font-medium text-muted"
    >
      {initialsFor(name)}
    </span>
  );
}

export function PlanBadge({ planId }: { readonly planId: string | null | undefined }) {
  const t = useTranslations("dashboard.teams.plan");
  const key = planLabelKey(planId);
  return <Badge tone={key === "free" ? "muted" : "default"}>{t(key)}</Badge>;
}

export function RoleBadge({ role }: { readonly role: TeamRole }) {
  const t = useTranslations("dashboard.teams.role");
  return <Badge tone={role === "admin" ? "outline" : "muted"}>{t(role)}</Badge>;
}

export function CopyValueButton({ value }: { readonly value: string }) {
  const t = useTranslations("dashboard.teams.common");
  const [copied, setCopied] = useState(false);
  const [failed, setFailed] = useState(false);
  return (
    <button
      type="button"
      className={settingsButtonClass("secondary", "sm")}
      onClick={async () => {
        try {
          await navigator.clipboard.writeText(value);
          setCopied(true);
          setFailed(false);
        } catch {
          setFailed(true);
        }
      }}
    >
      {failed ? t("copyFailed") : copied ? t("copied") : t("copy")}
    </button>
  );
}

export function SectionCard({
  title,
  description,
  children,
  tone = "default",
}: {
  readonly title: string;
  readonly description?: string;
  readonly children: React.ReactNode;
  readonly tone?: "default" | "danger";
}) {
  return (
    <section
      className={`border p-4 ${tone === "danger" ? "border-red-600/40 dark:border-red-400/40" : "border-border"}`}
    >
      <h2 className="text-sm font-medium">{title}</h2>
      {description ? <p className="mt-1 max-w-2xl text-xs text-muted">{description}</p> : null}
      <div className="mt-3">{children}</div>
    </section>
  );
}

/**
 * Turn a Team API failure into display text: a known code gets its own
 * message, else the server's message, else a generic fallback.
 */
export function useTeamErrorText(): (error: unknown) => string {
  const t = useTranslations("dashboard.teams.errors");
  return (error) => {
    const code = teamErrorCode(error);
    if (t.has(code)) return t(code);
    if (error instanceof TeamApiError && error.message) return error.message;
    return t("generic");
  };
}
