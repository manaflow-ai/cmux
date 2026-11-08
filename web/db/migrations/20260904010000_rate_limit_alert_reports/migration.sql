CREATE TABLE "rate_limit_alert_reports" (
  "alert_key" text PRIMARY KEY NOT NULL,
  "reported_at" timestamp with time zone DEFAULT now() NOT NULL
);
