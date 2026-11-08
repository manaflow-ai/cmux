CREATE TABLE "coderouter_session_accounts" (
  "team_id" text NOT NULL,
  "provider" text NOT NULL,
  "session_key" text NOT NULL,
  "account_id" uuid NOT NULL
    REFERENCES "coderouter_accounts" ("id") ON DELETE CASCADE,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "last_seen_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "coderouter_session_accounts_pkey"
    PRIMARY KEY ("team_id", "provider", "session_key"),
  CONSTRAINT "coderouter_session_accounts_provider_check"
    CHECK ("provider" IN ('codex', 'opencode-go'))
);

CREATE INDEX "coderouter_session_accounts_account_idx"
  ON "coderouter_session_accounts" ("account_id");

CREATE INDEX "coderouter_session_accounts_last_seen_idx"
  ON "coderouter_session_accounts" ("last_seen_at");
