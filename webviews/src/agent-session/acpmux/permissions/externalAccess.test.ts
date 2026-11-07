// l10n-allow-file: protocol fixtures, not shipped UI.
import { expect, test } from "bun:test";
import type { ExternalAccess } from "../model";
import { externalAccessFromRequest } from "./externalAccess";

const access: ExternalAccess = {
  kind: "files_and_folders",
  target: "/Users/you/Documents/report.txt",
  operation: "read_text_file",
  platform: "macos",
};
const request = (value: unknown) => ({
  toolCall: { _meta: { acpmux: { externalAccess: value } } },
});

test("external OS access carries its exact target and operation", () => {
  expect(externalAccessFromRequest(request(access))).toEqual(access);
  expect(externalAccessFromRequest(request({ ...access, kind: "full_disk_access" }))?.kind).toBe("full_disk_access");
});

test("tool error text and malformed external markers do not create access cards", () => {
  for (const value of [
    null,
    {},
    "EPERM",
    { toolCall: { description: "Data Access Blocked" } },
    request({ ...access, target: "https://example.com" }),
    request({ ...access, platform: "linux" }),
    request({ ...access, kind: "arbitrary" }),
    request({ ...access, operation: "execute" }),
  ]) {
    expect(externalAccessFromRequest(value)).toBeUndefined();
  }
});
