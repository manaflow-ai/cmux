/**
 * Stack Auth webhook signatures (Stack delivers through Svix): the shared
 * check in libs/svix-webhook (the cmux-next API Worker uses the same module),
 * with the Worker secret kept Redacted up to the call. The signed content is
 * `${svix-id}.${svix-timestamp}.${raw body}`; a timestamp more than 5 minutes
 * from the Worker's clock is refused, and the delivery id makes a retry
 * within the window a no-op.
 */
import { Redacted } from "effect";
import { signSvixContent, SVIX_TOLERANCE_SECONDS, verifySvixSignature, type SvixSignatureCheck } from "../../../../libs/svix-webhook/src/svix.ts";

export const WEBHOOK_TOLERANCE_SECONDS = SVIX_TOLERANCE_SECONDS;

export type WebhookSignatureCheck = SvixSignatureCheck;

/** The base64 signature for `content` under `secret`; null when the secret is not a valid key. */
export const signWebhookContent = (secret: Redacted.Redacted<string>, content: string): Promise<string | null> =>
  signSvixContent(Redacted.value(secret), content);

export const verifyWebhookSignature = (
  secret: Redacted.Redacted<string>,
  headers: Headers,
  body: string,
  nowMs: number,
): Promise<WebhookSignatureCheck> => verifySvixSignature(Redacted.value(secret), headers, body, nowMs);
