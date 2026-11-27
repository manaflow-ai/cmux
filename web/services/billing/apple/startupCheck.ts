// Reports at server start whether the App Store Server API key is present, so
// a production deployment without it shows up in the logs right away instead
// of at the next Apple cron run. instrumentation.ts calls it once per process.

import { appleServerApiStatus } from "./config";

type Env = Record<string, string | undefined>;

export function reportAppleServerApiAtStartup(env: Env = process.env): void {
  const status = appleServerApiStatus(env);
  if (status.appleServerApi === "configured") return;
  const log = status.required ? console.error : console.warn;
  log("apple_iap.server_api_not_configured", {
    metric: "apple_iap.server_api_not_configured",
    source: "startup",
    production: status.required,
    missingEnv: status.missingEnv,
  });
}
