// `home.server` (choice_or_url): cmux Cloud ("hosted") or {"selfHosted": "<http(s) origin>"}, checked
// on the page like Swift `SettingDescriptor.accepts` and cmux-config.
import { expect, test } from "bun:test";
import type { SchemaRow } from "./schema";
import { validate } from "./validate";

const row = {
  key: "home.server",
  path: ["home", "server"],
  section: "home",
  group: { text: "Messages Server", key: "settings.group.messagesServer" },
  title: { text: "Server", key: "settings.home.server" },
  help: null,
  summary: null,
  kind: "choice_or_url",
  choices: [{ value: "hosted", title: { text: "cmux Cloud", key: "settings.choice.homeServer.hosted" } }],
  url_key: "selfHosted",
  default: "hosted",
  default_label: null,
  keywords: [],
  agent_settable: false,
  kept_on_reset_all: false,
  consumers: ["cmux-next"],
  page_hidden: false,
  validation: "portable",
  accepts: [],
  refuses: [],
} as unknown as SchemaRow;

test("a choice or a self-hosted origin is valid", () => {
  for (const value of [
    "hosted",
    { selfHosted: "http://mini.tail1234.ts.net:7320" },
    { selfHosted: "http://mini.tail1234.ts.net:7320/" },
    { selfHosted: "https://100.101.102.103" },
  ])
    expect(validate(row, value)).toBeNull();
});

test("anything else is refused", () => {
  for (const value of [
    "selfHosted",
    1,
    true,
    null,
    { selfHosted: "ftp://mini.tail1234.ts.net" },
    { selfHosted: "http://mini.tail1234.ts.net/path" },
    { selfHosted: "http://mini.tail1234.ts.net?x=1" },
    { selfHosted: "http://user@mini.tail1234.ts.net" },
    { selfHosted: "not a url" },
    { selfHosted: 7320 },
    { other: "http://mini.tail1234.ts.net" },
    { selfHosted: "http://mini.tail1234.ts.net", extra: "x" },
  ])
    expect(validate(row, value)).not.toBeNull();
});
