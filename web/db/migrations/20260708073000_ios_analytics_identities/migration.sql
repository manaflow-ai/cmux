CREATE TABLE "ios_analytics_identities" (
  "user_id" text NOT NULL,
  "anonymous_id" text NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);

CREATE UNIQUE INDEX "ios_analytics_identities_user_anonymous_unique"
  ON "ios_analytics_identities" ("user_id", "anonymous_id");
CREATE INDEX "ios_analytics_identities_user_idx"
  ON "ios_analytics_identities" ("user_id");
