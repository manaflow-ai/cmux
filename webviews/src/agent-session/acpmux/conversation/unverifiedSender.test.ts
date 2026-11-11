// l10n-allow-file: test fixtures (program and machine names).
import { expect, test } from "bun:test";
import { translatorFor } from "../i18n";
import { identifiedName, identifiedOf, unnamedSender, unverifiedWhy, verifiedByProgram, whyOf } from "./unverifiedSender";

const t = translatorFor("en");

test("an unnamed unverified send is named by what acpmux identified, else as before", () => {
  expect(unnamedSender(t, { program: "outbox_relay.py" })).toBe("outbox_relay.py, via acpmux CLI");
  expect(unnamedSender(t, { app: "Xcode.app" })).toBe("Xcode, via acpmux CLI");
  expect(unnamedSender(t, undefined)).toBe("Unverified sender");
  expect(identifiedName({ program: "glaeda-gh", app: "Xcode.app" })).toBe("glaeda-gh");
});

test("the mark says what was claimed and what was identified, and why", () => {
  expect(unverifiedWhy(t, whyOf({ name: "", identified: { program: "outbox_relay.py" }, host: "cosmic-gray" }))).toBe(
    "Sent by outbox_relay.py via acpmux CLI on cosmic-gray",
  );
  expect(unverifiedWhy(t, whyOf({ name: "glaeda-gh", identified: { program: "stranger.py" } }))).toBe(
    "Claimed to be glaeda-gh, not proven\nSent by stranger.py via acpmux CLI",
  );
  expect(unverifiedWhy(t, whyOf({ name: "coord-deputy" }))).toBe("Claimed to be coord-deputy, not proven");
  expect(unverifiedWhy(t, whyOf({ name: "" }))).toBe("Sender not verified");
});

test("only the daemon's own fields count", () => {
  expect(identifiedOf({ identified: { program: " ", app: 3 } })).toBeUndefined();
  expect(identifiedOf({ identified: "outbox_relay.py" })).toBeUndefined();
  expect(verifiedByProgram({ verified: true, verifiedBy: "program" })).toBe(true);
  expect(verifiedByProgram({ verified: true })).toBe(false);
  expect(verifiedByProgram({ verified: false, verifiedBy: "program" })).toBe(false);
});
