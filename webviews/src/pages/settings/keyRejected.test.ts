import { expect, test } from "bun:test";
import "./testCatalog";
import { userMessage } from "../shared/userMessage";
import { SETTINGS_SENTENCES } from "./ops";

// A pasted API key the provider refused shows the host's sentence under Settings > Models, not the
// generic one, so a wrong key is said at the paste instead of at the first chat turn.
test("a key the provider refused shows the host's sentence", () => {
  const refusal = { code: "cmux.models.key_rejected", message: "Key rejected by OpenAI" };
  expect(userMessage(refusal, SETTINGS_SENTENCES)).toBe("Key rejected by OpenAI");
  expect(userMessage({ code: "cmux.models.failed", message: "raw" }, SETTINGS_SENTENCES)).not.toBe("raw");
});
