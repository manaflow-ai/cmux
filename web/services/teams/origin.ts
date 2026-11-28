import { directDevBackendOrigin } from "../../app/lib/direct-dev-backend-origin";
import { locales, type Locale } from "../../i18n/routing";
import { vmRequestLocale } from "../vms/vmErrorMessages";

export const DEFAULT_TEAM_INVITE_ORIGIN = "https://cmux.com";

type Environment = Record<string, string | undefined>;

/**
 * The origin put into invite emails and invite links. Configured origins win;
 * production never trusts the request's Host, so a spoofed host header cannot
 * make Stack mail a cmux-branded link to another site. Only development uses
 * the request origin (or the validated direct dev-backend origin).
 */
export function trustedTeamInviteOrigin(request: Request, environment: Environment = process.env): string {
  const configured = environment.CMUX_TEAM_INVITE_ORIGIN?.trim() || environment.CMUX_APP_ORIGIN?.trim();
  if (configured) return httpOrigin(configured) ?? DEFAULT_TEAM_INVITE_ORIGIN;
  if (environment.VERCEL_ENV === "production" || environment.NODE_ENV === "production") {
    return DEFAULT_TEAM_INVITE_ORIGIN;
  }
  const direct = directDevBackendOrigin(environment)?.origin;
  return direct ?? httpOrigin(request.url) ?? DEFAULT_TEAM_INVITE_ORIGIN;
}

/** Only allow-listed locales reach a URL path; anything else becomes `en`. */
export function safeTeamLocale(value: string | null | undefined): Locale {
  return (locales as readonly string[]).includes(value ?? "") ? value as Locale : "en";
}

export function teamRequestLocale(request: Request): Locale {
  return safeTeamLocale(vmRequestLocale(request));
}

export function teamInviteAcceptUrl(request: Request, environment: Environment = process.env): string {
  const url = new URL(`/${teamRequestLocale(request)}/dashboard/team/accept`, trustedTeamInviteOrigin(request, environment));
  return url.toString();
}

export function teamInviteLinkUrl(
  request: Request,
  token: string,
  environment: Environment = process.env,
): string {
  const path = `/${teamRequestLocale(request)}/join/${encodeURIComponent(token)}`;
  return new URL(path, trustedTeamInviteOrigin(request, environment)).toString();
}

function httpOrigin(value: string): string | null {
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" && url.protocol !== "http:") return null;
    return url.origin;
  } catch {
    return null;
  }
}
