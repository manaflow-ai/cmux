// `tabs.newTabApp` names an app by id: the page accepts exactly the ids an app manifest may have
// (cmux-app.schema.json `properties.id.pattern`), like Swift `SettingDescriptor.accepts` and cmux-config.
import { expect, test } from "bun:test";
import { rowsByKey } from "./schema";
import { validate } from "./validate";

const found = rowsByKey.get("tabs.newTabApp");
if (!found) throw new Error("tabs.newTabApp is a row");
const row = found;

test("tabs.newTabApp accepts manifest app ids", () => {
  for (const id of ["local/web-pane", "local/showcase-newtab", "manaflow-ai/launcher", "0x/a-b"])
    expect(validate(row, id)).toBeNull();
});

test("tabs.newTabApp refuses what no manifest id can be", () => {
  for (const id of ["Foo/Bar", "local/Web", "foo/bar/baz", "foo", "/bar", "foo/", "-foo/bar", "a b/c", "", 1])
    expect(validate(row, id)).not.toBeNull();
});
