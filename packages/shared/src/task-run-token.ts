import { jwtVerify } from "jose";
import { z } from "zod";

const TaskRunTokenPayloadSchema = z.object({
  taskRunId: z.string().min(1),
  teamId: z.string().min(1),
  userId: z.string().min(1),
});

export type TaskRunTokenPayload = z.infer<typeof TaskRunTokenPayloadSchema>;

export async function verifyTaskRunToken(
  token: string,
  secret: string
): Promise<TaskRunTokenPayload> {
  if (!secret) {
    throw new Error("Task run JWT secret is required");
  }
  const encodedSecret = new TextEncoder().encode(secret);
  const verification = await jwtVerify(token, encodedSecret);
  const parsed = TaskRunTokenPayloadSchema.safeParse(verification.payload);
  if (!parsed.success) {
    throw new Error("Invalid CMUX task run token payload");
  }
  return parsed.data;
}
