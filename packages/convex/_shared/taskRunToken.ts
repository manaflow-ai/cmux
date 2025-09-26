import { jwtVerify } from "jose";
import { z } from "zod";
import { env } from "./convex-env";

const TaskRunTokenPayloadSchema = z.object({
  taskRunId: z.string().min(1),
  teamId: z.string().min(1),
  userId: z.string().min(1),
});

export type TaskRunTokenPayload = z.infer<typeof TaskRunTokenPayloadSchema>;

const taskRunJwtSecret = new TextEncoder().encode(env.CMUX_TASK_RUN_JWT_SECRET);

export async function verifyTaskRunToken(
  token: string
): Promise<TaskRunTokenPayload> {
  const verification = await jwtVerify(token, taskRunJwtSecret);
  const parsed = TaskRunTokenPayloadSchema.safeParse(verification.payload);
  if (!parsed.success) {
    throw new Error("Invalid CMUX task run token payload");
  }
  return parsed.data;
}

