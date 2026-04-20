import { createEnv } from "@t3-oss/env-nextjs";
import { z } from "zod";

// Trim at the runtimeEnv source so every consumer — including paths that
// run when validation is skipped (VERCEL_ENV === "preview") — sees clean
// values. A trailing newline in Vercel env vars has tripped Stack Auth's
// UUID parser and malformed the stack-refresh-<project-id> cookie key.
const trimEnv = (value: string | undefined): string | undefined =>
  typeof value === "string" ? value.trim() : value;

export const env = createEnv({
  server: {
    RESEND_API_KEY: z.string().min(1),
    CMUX_FEEDBACK_FROM_EMAIL: z.string().email(),
    CMUX_FEEDBACK_RATE_LIMIT_ID: z.string().min(1),
    STACK_SECRET_SERVER_KEY: z.string().min(1),
  },
  client: {
    NEXT_PUBLIC_STACK_PROJECT_ID: z.string().min(1),
    NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY: z.string().min(1),
  },
  runtimeEnv: {
    RESEND_API_KEY: trimEnv(process.env.RESEND_API_KEY),
    CMUX_FEEDBACK_FROM_EMAIL: trimEnv(process.env.CMUX_FEEDBACK_FROM_EMAIL),
    CMUX_FEEDBACK_RATE_LIMIT_ID: trimEnv(process.env.CMUX_FEEDBACK_RATE_LIMIT_ID),
    NEXT_PUBLIC_STACK_PROJECT_ID: trimEnv(process.env.NEXT_PUBLIC_STACK_PROJECT_ID),
    NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY: trimEnv(process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY),
    STACK_SECRET_SERVER_KEY: trimEnv(process.env.STACK_SECRET_SERVER_KEY),
  },
  skipValidation:
    process.env.SKIP_ENV_VALIDATION === "1" ||
    process.env.VERCEL_ENV === "preview",
});
