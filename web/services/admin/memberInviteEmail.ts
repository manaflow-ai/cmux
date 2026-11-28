// Admin invitation email. Plain text, sent through Resend with the same key
// and sender configuration as the other transactional mail.

import { Resend } from "resend";

import { env } from "../../app/env";
import { DEFAULT_FROM_EMAIL } from "../../app/api/stripe/founders-welcome/welcome-email";

export const ADMIN_APP_URL = "https://cmux-admin.vercel.app";
export const ADMIN_INVITE_SUBJECT = "You have been invited to cmux admin";

export type AdminMemberInviteEmail = {
  readonly from: string;
  readonly to: string[];
  readonly subject: string;
  readonly text: string;
};

export type AdminInviteEmailConfig = {
  readonly resendApiKey: string;
  readonly fromEmail: string;
};

export type AdminInviteSender = (input: {
  readonly to: string;
  readonly inviterEmail: string | null;
}) => Promise<{ sent: boolean }>;

export function buildAdminMemberInviteEmail(params: {
  readonly from: string;
  readonly to: string;
  readonly inviterEmail: string | null;
}): AdminMemberInviteEmail {
  const inviter = params.inviterEmail ?? "a cmux admin";
  return {
    from: params.from,
    to: [params.to],
    subject: ADMIN_INVITE_SUBJECT,
    text: [
      `${inviter} invited you to cmux admin.`,
      "",
      `Open ${ADMIN_APP_URL} and sign in with this email address (${params.to}).`,
      "Access is tied to the invited address, so another account will not work.",
    ].join("\n"),
  };
}

/** Null until RESEND_API_KEY is set; the invite is still recorded without mail. */
export function resolveAdminInviteEmailConfig(): AdminInviteEmailConfig | null {
  const resendApiKey = env.RESEND_API_KEY;
  if (!resendApiKey) return null;
  return {
    resendApiKey,
    fromEmail: env.CMUX_FEEDBACK_FROM_EMAIL || DEFAULT_FROM_EMAIL,
  };
}

export const sendAdminMemberInviteEmail: AdminInviteSender = async (input) => {
  const config = resolveAdminInviteEmailConfig();
  if (!config) return { sent: false };
  const resend = new Resend(config.resendApiKey);
  const payload = buildAdminMemberInviteEmail({
    from: `cmux <${config.fromEmail}>`,
    to: input.to,
    inviterEmail: input.inviterEmail,
  });
  // The member row is already written when this runs, so a transport failure
  // is reported as "not sent", never as a failed invite.
  try {
    const { error } = await resend.emails.send(payload);
    if (error) {
      console.error("admin.members.invite_email_failed", { to: input.to, error });
      return { sent: false };
    }
    return { sent: true };
  } catch (error) {
    console.error("admin.members.invite_email_failed", {
      to: input.to,
      message: error instanceof Error ? error.message : String(error),
    });
    return { sent: false };
  }
};
