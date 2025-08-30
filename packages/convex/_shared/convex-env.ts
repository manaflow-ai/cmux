import { createEnv } from "@t3-oss/env-core";
import { z } from "zod";

export const env = createEnv({
  server: {
    STACK_WEBHOOK_SECRET: z.string().min(1),
    GITHUB_APP_WEBHOOK_SECRET: z.string().min(1).optional(),
    INSTALL_STATE_SECRET: z.string().min(1).optional(),
  },
  runtimeEnv: process.env,
  emptyStringAsUndefined: true,
});
