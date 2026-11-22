// The team invitation email cmux sends through Resend. Plain text first, a
// minimal HTML twin second, no tracking, one link. The download line is there
// because most invitees have never installed cmux.
import { Resend } from "resend";
import { env } from "../../app/env";

export const CMUX_DOWNLOAD_URL = "https://cmux.com/download";
export const DEFAULT_TEAM_INVITE_FROM_EMAIL = "invites@cmux.com";

export type TeamInviteEmail = {
  readonly from: string;
  readonly to: string[];
  readonly subject: string;
  readonly text: string;
  readonly html: string;
  readonly headers: Readonly<Record<string, string>>;
};

export type TeamInviteEmailInput = {
  readonly to: string;
  readonly teamName: string;
  /** The inviter as the team knows them; null falls back to "A teammate". */
  readonly inviterName: string | null;
  readonly role: "admin" | "member";
  readonly acceptUrl: string;
  readonly expiresAt: Date;
  readonly downloadUrl?: string;
};

export type TeamInviteMailer = {
  /** Resolves on delivery to Resend; rejects when the email did not go out. */
  send(input: TeamInviteEmailInput): Promise<void>;
};

/** One line of display text for a subject or greeting: no control characters, bounded length. */
function displayText(value: string | null | undefined, fallback: string, max = 80): string {
  const cleaned = (value ?? "").replace(/[\p{Cc}\p{Cf}]/gu, " ").replace(/\s+/g, " ").trim();
  if (!cleaned) return fallback;
  return cleaned.length > max ? `${cleaned.slice(0, max - 1)}…` : cleaned;
}

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[char]!));
}

export function buildTeamInviteEmail(params: TeamInviteEmailInput & { readonly from: string }): TeamInviteEmail {
  const inviter = displayText(params.inviterName, "A teammate");
  const teamName = displayText(params.teamName, "a cmux team", 120);
  const download = params.downloadUrl ?? CMUX_DOWNLOAD_URL;
  const expires = params.expiresAt.toISOString().slice(0, 10);
  const roleLine = params.role === "admin" ? " as an admin" : "";
  const text = [
    `${inviter} invited you to ${teamName} on cmux${roleLine}.`,
    "",
    `Accept: ${params.acceptUrl}`,
    "",
    "Members share the team's Cloud machines. Your own Mac stays private.",
    "",
    `New to cmux? Download it for Mac at ${download}, sign in with this address (${params.to}), then open the link above.`,
    "",
    `The link expires on ${expires}. If you were not expecting this, ignore this email.`,
  ].join("\n");
  const html = [
    `<p>${escapeHtml(inviter)} invited you to <strong>${escapeHtml(teamName)}</strong> on cmux${roleLine}.</p>`,
    `<p><a href="${escapeHtml(params.acceptUrl)}">Accept the invitation</a></p>`,
    "<p>Members share the team's Cloud machines. Your own Mac stays private.</p>",
    `<p>New to cmux? <a href="${escapeHtml(download)}">Download it for Mac</a>, sign in with this address (${escapeHtml(params.to)}), then open the link above.</p>`,
    `<p style="color:#666">The link expires on ${expires}. If you were not expecting this, ignore this email.</p>`,
  ].join("\n");
  return {
    from: params.from,
    to: [params.to],
    subject: `${inviter} invited you to ${teamName} on cmux`,
    text,
    html,
    // Transactional mail, one message per invitation. The token stays in the
    // body only: no header, log line or subject carries it.
    headers: { "Auto-Submitted": "auto-generated" },
  };
}

export type TeamInviteMailConfig = { readonly resendApiKey: string; readonly fromEmail: string };

/** Null until RESEND_API_KEY is set; without it an invite is refused, not silently unsent. */
export function resolveTeamInviteMailConfig(): TeamInviteMailConfig | null {
  const resendApiKey = env.RESEND_API_KEY;
  if (!resendApiKey) return null;
  return { resendApiKey, fromEmail: env.CMUX_TEAM_INVITE_FROM_EMAIL || DEFAULT_TEAM_INVITE_FROM_EMAIL };
}

export class TeamInviteMailUnavailable extends Error {
  override readonly name = "TeamInviteMailUnavailable";
}

export const resendTeamInviteMailer: TeamInviteMailer = {
  async send(input) {
    const config = resolveTeamInviteMailConfig();
    if (!config) throw new TeamInviteMailUnavailable("RESEND_API_KEY is not configured");
    const resend = new Resend(config.resendApiKey);
    const payload = buildTeamInviteEmail({ ...input, from: `cmux <${config.fromEmail}>` });
    const { error } = await resend.emails.send(payload);
    if (error) throw new Error(`resend: ${error.name}: ${error.message}`);
  },
};
