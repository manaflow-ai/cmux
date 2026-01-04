import { z } from "zod";

// Convex is server-only, so we use direct Zod validation instead of t3-oss/env-core
// which is designed for client/server distinction in frameworks like Next.js
const envSchema = z.object({
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
  OPENAI_API_KEY: z.string().min(1).optional(),
  ANTHROPIC_API_KEY: z.string().min(1).optional(),
  MORPH_API_KEY: z.string().min(1).optional(),
  CMUX_IS_STAGING: z.string().optional(),
  CONVEX_IS_PRODUCTION: z.string().optional(),
});

// Convert empty strings to undefined before parsing
function preprocessEnv(rawEnv: NodeJS.ProcessEnv): Record<string, string | undefined> {
  const result: Record<string, string | undefined> = {};
  for (const key of Object.keys(envSchema.shape)) {
    const value = rawEnv[key];
    result[key] = value === "" ? undefined : value;
  }
  return result;
}

export const env = envSchema.parse(preprocessEnv(process.env));
