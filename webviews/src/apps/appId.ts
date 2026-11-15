// The id an app manifest may have: the manifest schema's own `properties.id.pattern`
// (cmux-tui/crates/cmux-app-host/schema/v2/cmux-app.schema.json), never restated:
// scripts/cmux-next/gen-settings-sources.py copies it into appIdPattern.generated.ts, since the web
// builds see no cmux-tui/. The daemon (cmux-config schema/app_id.rs) and Swift
// (`NewTabAppSetting.isValidID`) use the same pattern.
import { APP_ID_PATTERN } from "./appIdPattern.generated";

const APP_ID = new RegExp(APP_ID_PATTERN);

/** Whether `value` is an app id (`publisher/name`) an app manifest may have. */
export function isAppID(value: unknown): value is string {
  return typeof value === "string" && APP_ID.test(value);
}
