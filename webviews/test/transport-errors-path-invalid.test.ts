// A Codex chat after a reboot (Leo's NIGHTLY, 2026-11-25) read "Couldn't start Codex: The app refused
// this request." with `transport.path_invalid` under Details: a dead end, with no folder named and no
// way out. The refusal now has its own words, names the folder that is gone (the relay's `detail`, a
// native reply's `details.path`, reason `path.missing`), and the failed start card offers Choose Folder.
import { expect, test } from "bun:test";
import { translate } from "../src/agent-session/acpmux/i18n";
import { NativeError } from "../src/agent-session/acpmux/nativeError";
import { startRefusalAction } from "../src/agent-session/acpmux/startRefusal";
import { errorMessage, missingFolder, startErrorMessage } from "../src/agent-session/acpmux/transportErrors";

const relay = Object.assign(new Error("Refused by the cmux host"), {
  code: "transport.path_invalid",
  reason: "path.missing",
  detail: "/private/var/folders/xy/T/leo-workspace",
  method: "session/new",
});
const native = new NativeError({
  code: "transport.path_invalid",
  userMessage: "The folder /tmp/gone no longer exists. Pick another folder.",
  details: { reason: "path.missing", path: "/tmp/gone" },
});
const bare = Object.assign(new Error("Refused by the cmux host"), { code: "transport.path_invalid" });

test("a folder that is gone is named, from the relay and from a native reply", () => {
  expect(missingFolder(relay)).toBe("/private/var/folders/xy/T/leo-workspace");
  expect(missingFolder(native)).toBe("/tmp/gone");
  expect(startErrorMessage(relay)).toBe(
    translate("transport.pathMissing", { path: "/private/var/folders/xy/T/leo-workspace" }),
  );
  expect(errorMessage(native)).toBe(translate("transport.pathMissing", { path: "/tmp/gone" }));
  expect(errorMessage(native)).toContain("/tmp/gone");
});

test("a path refusal without a folder still has its own words, never the generic refusal", () => {
  expect(missingFolder(bare)).toBeUndefined();
  expect(errorMessage(bare)).toBe(translate("transport.pathInvalid"));
  expect(errorMessage(bare)).not.toBe(translate("transport.refused"));
});

test("the failed start card offers Choose Folder for it", () => {
  expect(startRefusalAction("transport.path_invalid")).toBe("chooseFolder");
});
