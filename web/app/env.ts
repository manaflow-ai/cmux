import { createEnv } from "@t3-oss/env-nextjs";
import { z } from "zod";

export const env = createEnv({
  server: {
    RESEND_API_KEY: z.string().min(1),
    CMUX_FEEDBACK_FROM_EMAIL: z.string().email(),
    CMUX_FEEDBACK_RATE_LIMIT_ID: z.string().min(1),
  },
  runtimeEnv: {
    RESEND_API_KEY: process.env.RESEND_API_KEY,
    CMUX_FEEDBACK_FROM_EMAIL: process.env.CMUX_FEEDBACK_FROM_EMAIL,
    CMUX_FEEDBACK_RATE_LIMIT_ID: process.env.CMUX_FEEDBACK_RATE_LIMIT_ID,
  },
  skipValidation:
    process.env.SKIP_ENV_VALIDATION === "1" ||
    process.env.VERCEL_ENV === "preview",
});
