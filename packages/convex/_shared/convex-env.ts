import { createEnv } from "@t3-oss/env-core";
import { z } from "zod";

export const env = createEnv({
  server: {
    STACK_WEBHOOK_SECRET: z.string().min(1),
    // Stack Admin keys for backfills and server-side operations
    STACK_SECRET_SERVER_KEY: z.string().min(1).optional(),
    STACK_SUPER_SECRET_ADMIN_KEY: z.string().min(1).optional(),
    NEXT_PUBLIC_STACK_PROJECT_ID: z.string().optional(),
    NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY: z.string().optional(),
    GITHUB_APP_WEBHOOK_SECRET: z.string().min(1).optional(),
    INSTALL_STATE_SECRET: z.string().min(1).optional(),
    CMUX_GITHUB_APP_ID: z.string().min(1).optional(),
    CMUX_GITHUB_APP_PRIVATE_KEY: z.string().min(1).optional(),
    BASE_APP_URL: z.string().min(1),
    CMUX_TASK_RUN_JWT_SECRET: z.string().min(1),
  },
  runtimeEnv: process.env,
  emptyStringAsUndefined: true,
});
