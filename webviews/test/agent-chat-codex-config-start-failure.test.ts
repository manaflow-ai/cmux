// Codex parity dogfood (2026-11-20): a Codex whose config.toml does not parse fails its start with
// "failed to load configuration: PATH:LINE:COL: <toml error>". The card and the chat's notice said only
// "Codex couldn't start.", with the file and the fix hidden under Details (and nowhere in the notice).
// They name the file Codex refused, as a turn whose workspace config fails to load already does.
import { expect, test } from "bun:test";
import { failureKind } from "../src/agent-session/acpmux/failureCopy";
import { translatorFor } from "../src/agent-session/acpmux/i18n";
import { startFailureNotice, startFailureView } from "../src/agent-session/acpmux/startFailure";

const t = translatorFor("en");
const raw = "failed to load configuration: /Users/l/.codex/config.toml:1:16: unclosed array, expected `]`";

test("a Codex config.toml that does not parse is a Codex settings failure", () => {
  expect(failureKind(raw, { name: "Codex", harness: "codex" })).toBe("codex-config");
});

test("the start card names the file Codex refused, not a bare couldn't start", () => {
  const view = startFailureView(t, { harness: "codex", name: "Codex", error: raw });
  expect(view.sentence).toBe("Codex couldn’t load its settings: /Users/l/.codex/config.toml is invalid. Fix that file, then retry.");
  expect(view.detail).toBe(raw);
  expect(view.unexplained).toBeUndefined();
});

test("the sessionless start's notice says the same", () => {
  const error = Object.assign(new Error(raw), { code: "runtime" });
  expect(startFailureNotice(t, "codex", error)).toBe(
    "Codex couldn’t load its settings: /Users/l/.codex/config.toml is invalid. Fix that file, then retry.",
  );
});
