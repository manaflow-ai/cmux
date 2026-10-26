// l10n-allow-file: test fixtures (made-up people), not shipped UI.
// The shared chat's readers: an author only from the daemon's `person_message` provenance, an
// answerer only from a person `answeredBy`, presence without the reader, and pictures only inline.
import { expect, test } from "bun:test";
import { answeredBy, chatPresence, initials, promptAuthor } from "./participants";

test("a prompt's author comes only from person_message provenance", () => {
  const msg = { _meta: { provenance: { kind: "person_message", from: "tailnet:ana@example.com", fromName: "Ana Ruiz" } } };
  expect(promptAuthor(msg)).toEqual({ id: "tailnet:ana@example.com", name: "Ana Ruiz" });
  expect(promptAuthor({ _meta: { provenance: { kind: "agent_message", from: "x", fromName: "Lane" } } })).toBeUndefined();
  expect(promptAuthor({})).toBeUndefined();
  expect(promptAuthor({ _meta: { provenance: { kind: "person_message", fromName: "No id" } } })).toBeUndefined();
});

test("a name falls back to the id, is trimmed and bounded", () => {
  expect(promptAuthor({ _meta: { provenance: { kind: "person_message", from: "tailnet:sam" } } })?.name).toBe("tailnet:sam");
  const long = "x".repeat(200);
  expect(answeredBy({ person: "p", name: long })?.name.length).toBe(64);
});

test("only an inline picture is kept", () => {
  expect(answeredBy({ person: "p", name: "P", avatar: "https://example.com/a.png" })?.avatar).toBeUndefined();
  expect(answeredBy({ person: "p", name: "P", avatar: "data:image/png;base64,AAAA" })?.avatar).toBe(
    "data:image/png;base64,AAAA",
  );
});

test("an answer by a session or a device names no person", () => {
  expect(answeredBy({ session: "acp:1", name: "Lane" })).toBeUndefined();
  expect(answeredBy({ device: "phone" })).toBeUndefined();
  expect(answeredBy({ person: "tailnet:mei", name: "Mei Lin" })).toEqual({ id: "tailnet:mei", name: "Mei Lin" });
});

test("presence leaves the reader out, and a typer is also viewing", () => {
  const presence = chatPresence({
    participants: [
      { id: "me", name: "Me", viewing: true, self: true },
      { id: "ana", name: "Ana", viewing: true },
      { id: "sam", name: "Sam", typing: true },
      { id: "ana", name: "Ana again", viewing: true },
      { id: "gone", name: "Gone" },
      null,
    ],
  });
  expect(presence.viewing.map((p) => p.id)).toEqual(["ana", "sam"]);
  expect(presence.typing.map((p) => p.id)).toEqual(["sam"]);
  expect(chatPresence(undefined)).toEqual({ viewing: [], typing: [] });
});

test("initials take whole graphemes", () => {
  expect(initials("Ana Ruiz")).toBe("AR");
  expect(initials("mei")).toBe("ME");
  expect(initials("Élodie Ünal")).toBe("ÉÜ");
});
