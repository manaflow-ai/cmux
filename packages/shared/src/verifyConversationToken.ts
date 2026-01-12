import { jwtVerify } from "jose";
import { z } from "zod";

const ConversationTokenPayloadSchema = z.object({
  conversationId: z.string().min(1),
  teamId: z.string().min(1),
  userId: z.string().min(1).optional(),
});

export type ConversationTokenPayload = z.infer<
  typeof ConversationTokenPayloadSchema
>;

function toKey(secret: string | Uint8Array): Uint8Array {
  return typeof secret === "string" ? new TextEncoder().encode(secret) : secret;
}

export async function verifyConversationToken(
  token: string,
  secret: string | Uint8Array
): Promise<ConversationTokenPayload> {
  const verification = await jwtVerify(token, toKey(secret));
  const parsed = ConversationTokenPayloadSchema.safeParse(verification.payload);

  if (!parsed.success) {
    throw new Error("Invalid CMUX conversation token payload");
  }

  return parsed.data;
}
