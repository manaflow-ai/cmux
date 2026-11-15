// The id an app manifest may have: the manifest schema's own `properties.id.pattern`
// (cmux-tui/crates/cmux-app-host/schema/v2/cmux-app.schema.json), read from the schema, never
// restated. The daemon (cmux-config schema/app_id.rs) and Swift (`NewTabAppSetting.isValidID`) use it too.
import { properties } from "../../../cmux-tui/crates/cmux-app-host/schema/v2/cmux-app.schema.json";

const APP_ID = new RegExp(properties.id.pattern);

/** Whether `value` is an app id (`publisher/name`) an app manifest may have. */
export function isAppID(value: unknown): value is string {
  return typeof value === "string" && APP_ID.test(value);
}
