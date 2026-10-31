import { expect, test } from "bun:test";
import { browseFailureMessage } from "./BrowseFailure";
import { translate } from "./i18n";

test("localizes unsupported and empty native browse failures", () => {
  expect(browseFailureMessage({ code: "unsupported", message: "Unsupported method" })).toBe(
    translate("project.unavailable"),
  );
  expect(browseFailureMessage(new Error(""))).toBe(translate("project.unavailable"));
});

test("preserves the host's actionable localized folder refusal", () => {
  const error = Object.assign(new Error("Restart the background service, then choose the folder again."), {
    code: "folder.unavailable",
  });
  expect(browseFailureMessage(error)).toBe(error.message);
});
