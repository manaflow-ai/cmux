// Login code delivery through the Cloudflare Email Service `send_email` binding.
import type { Env } from "./env";
import { HttpError } from "./http";

export async function sendCode(env: Env, to: string, code: string): Promise<void> {
  if (!env.SEND_EMAIL) throw new HttpError(503, "email_unavailable", "email delivery is not configured");
  const text = `Your cmux sign-in code is ${code}\n\nIt expires in 10 minutes. If you did not request it, ignore this email.`;
  try {
    await env.SEND_EMAIL.send({
      to,
      from: env.EMAIL_FROM,
      subject: `${code} is your cmux sign-in code`,
      text,
    });
  } catch (err) {
    console.error("send_email failed", (err as Error).message);
    throw new HttpError(503, "email_unavailable", "could not send the sign-in email");
  }
}
