// l10n-allow-file: test fixtures (made-up people), not shipped UI.
// The shared chat's readers: an author only from the daemon's `person_message` provenance, an
// answerer only from a person `answeredBy`, presence without the reader, and pictures only inline.
import { expect, test } from "bun:test";
import { answeredBy, chatPresence, displayName, initials, promptAuthor } from "./participants";

test("a prompt's author comes only from person_message provenance", () => {
  const msg = {
    _meta: { provenance: { kind: "person_message", from: "tailnet:ana@example.com", fromName: "Ana Ruiz" } },
  };
  expect(promptAuthor(msg)).toEqual({ id: "tailnet:ana@example.com", name: "Ana Ruiz" });
  expect(
    promptAuthor({ _meta: { provenance: { kind: "agent_message", from: "x", fromName: "Lane" } } }),
  ).toBeUndefined();
  expect(promptAuthor({})).toBeUndefined();
  expect(promptAuthor({ _meta: { provenance: { kind: "person_message", fromName: "No id" } } })).toBeUndefined();
});

test("a name falls back to the id, is trimmed and bounded", () => {
  expect(promptAuthor({ _meta: { provenance: { kind: "person_message", from: "tailnet:sam" } } })?.name).toBe(
    "tailnet:sam",
  );
  const long = "x".repeat(200);
  expect(answeredBy({ id: "p", name: long })?.name.length).toBe(64);
});

test("only an inline picture is kept", () => {
  expect(answeredBy({ id: "p", name: "P", avatar: "https://example.com/a.png" })?.avatar).toBeUndefined();
  expect(answeredBy({ id: "p", name: "P", avatar: "data:image/png;base64,AAAA" })?.avatar).toBe(
    "data:image/png;base64,AAAA",
  );
});

test("an answer by a session or a device names no person", () => {
  expect(answeredBy({ session: "acp:1", name: "Lane" })).toBeUndefined();
  expect(answeredBy({ device: "phone", feedItem: "f1" })).toBeUndefined();
  expect(answeredBy(null)).toBeUndefined();
  expect(answeredBy({ id: "tailnet:mei", name: "Mei Lin" })).toEqual({ id: "tailnet:mei", name: "Mei Lin" });
});

test("presence leaves the reader out, and a typer is also viewing", () => {
  const presence = chatPresence({
    participants: [
      { id: "owner", name: "Me", viewing: true },
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
  // A teammate's pane leaves itself out by its own id; the owner then shows as "owner".
  const theirs = chatPresence(
    {
      participants: [
        { id: "owner", name: "Leo", viewing: true },
        { id: "ana", name: "Ana", viewing: true },
      ],
    },
    "ana",
  );
  expect(theirs.viewing.map((p) => p.id)).toEqual(["owner"]);
});

test("initials take whole graphemes", () => {
  expect(initials("Ana Ruiz")).toBe("AR");
  expect(initials("mei")).toBe("ME");
  expect(initials("Élodie Ünal")).toBe("ÉÜ");
  // One letter for a small face is a whole grapheme, never half a surrogate pair.
  expect(initials("𠮷田", 1)).toBe("𠮷");
  expect(initials("😀 Tester", 1)).toBe("😀");
  expect(initials("👩‍💻 Dev", 1)).toBe("👩‍💻");
});

test("a name loses hidden characters and is bounded; an id is kept whole", () => {
  expect(displayName("Ana\u202Ezurz\u200B Ruiz\n")).toBe("Anazurz Ruiz");
  expect(displayName("\u202E\u200B")).toBeUndefined();
  // Unicode tags (U+E0001, U+E0020 to U+E007F) draw nothing but would ride along in the label.
  expect(displayName("Ana\u{E0041} Ruiz\u{E0001}\u{E007F}")).toBe("Ana Ruiz");
  expect(displayName("\u00AD\u061C\u180E\uFEFF\u2066\uFFFB")).toBeUndefined();
  const long = `tailnet:${"a".repeat(80)}`;
  const presence = chatPresence(
    {
      participants: [
        { id: long, name: "Me", viewing: true },
        { id: `${long}b`, name: "Other", viewing: true },
      ],
    },
    long,
  );
  expect(presence.viewing.map((p) => p.id)).toEqual([`${long}b`]);
  expect(answeredBy({ id: "x".repeat(300), name: "Too long" })).toBeUndefined();
});
