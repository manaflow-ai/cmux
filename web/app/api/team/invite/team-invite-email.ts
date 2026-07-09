export const DEFAULT_TEAM_INVITE_FROM_EMAIL = "austin@manaflow.ai";
export const TEAM_INVITE_REPLY_TO = "austin@manaflow.ai";
export const TEAM_INVITE_SUBJECT = "Join {team} on cmux";

export type TeamInviteEmail = {
  from: string;
  to: string[];
  replyTo: string;
  subject: string;
  text: string;
  html: string;
  headers: Record<string, string>;
};

function firstName(fullName: string | null | undefined): string {
  const trimmed = (fullName ?? "").trim();
  if (!trimmed) return "there";
  return trimmed.split(/\s+/)[0] ?? "there";
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function subjectForTeam(teamName: string): string {
  return TEAM_INVITE_SUBJECT.replace("{team}", teamName);
}

export function teamInviteThreadRef(invitationId: string): string {
  return `team-invite/${invitationId}`;
}

export function buildTeamInviteEmail(params: {
  from: string;
  to: string;
  teamName: string;
  inviterName: string | null | undefined;
  acceptUrl: string;
  invitationId: string;
}): TeamInviteEmail {
  const inviter = firstName(params.inviterName);
  const teamName = params.teamName.trim() || "cmux Team";
  const text = [
    `Hi there!`,
    "",
    `${inviter} invited you to join ${teamName} on cmux.`,
    "",
    `Accept the invite: ${params.acceptUrl}`,
    "",
    "If you were not expecting this invite, you can ignore this email.",
    "",
    "Best,",
    "The cmux team",
  ].join("\n");
  const escapedTeam = escapeHtml(teamName);
  const escapedInviter = escapeHtml(inviter);
  const escapedUrl = escapeHtml(params.acceptUrl);
  return {
    from: params.from,
    to: [params.to],
    replyTo: TEAM_INVITE_REPLY_TO,
    subject: subjectForTeam(teamName),
    text,
    html: [
      "<!doctype html>",
      '<html><body style="font-family:-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif;line-height:1.5;color:#111">',
      `<p>Hi there!</p>`,
      `<p>${escapedInviter} invited you to join <strong>${escapedTeam}</strong> on cmux.</p>`,
      `<p><a href="${escapedUrl}" style="display:inline-block;border:1px solid #111;padding:8px 12px;color:#111;text-decoration:none">Accept invite</a></p>`,
      `<p>If you were not expecting this invite, you can ignore this email.</p>`,
      `<p>Best,<br>The cmux team</p>`,
      "</body></html>",
    ].join(""),
    headers: { "X-Entity-Ref-ID": teamInviteThreadRef(params.invitationId) },
  };
}
