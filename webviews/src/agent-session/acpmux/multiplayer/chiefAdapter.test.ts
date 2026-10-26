// l10n-allow-file: test fixtures (made-up people), not shipped UI.
// Home's people as shared chat faces: people only, never the reader, and a typer counts as here.
import { expect, test } from "bun:test";
import type { HomeParticipant } from "../../../pages/home-channels/types";
import { chiefAuthor, chiefPresence } from "./chiefAdapter";

const person = (id: string, name: string, kind: HomeParticipant["kind"] = "human", chief = false): HomeParticipant => ({
  id,
  name,
  kind,
  chief,
});
const people = new Map(
  [person("me", "Me"), person("ana", "Ana Ruiz"), person("sam", "Sam Okafor"), person("chief", "Chief", "agent", true)].map(
    (p) => [p.id, p] as const,
  ),
);

test("a message's author is another person, never the reader or the Chief", () => {
  expect(chiefAuthor({ author: "ana" }, people, "me")).toEqual({ id: "ana", name: "Ana Ruiz" });
  expect(chiefAuthor({ author: "me" }, people, "me")).toBeUndefined();
  expect(chiefAuthor({ author: "chief" }, people, "me")).toBeUndefined();
  expect(chiefAuthor({ author: "unknown" }, people, "me")).toBeUndefined();
});

test("presence: typers are here too, the reader and agents are not", () => {
  const presence = chiefPresence(people, "me", ["ana", "chief", "me"], ["sam", "ana"]);
  expect(presence.typing.map((p) => p.id)).toEqual(["ana"]);
  expect(presence.viewing.map((p) => p.id)).toEqual(["sam", "ana"]);
  expect(chiefPresence(people, "me", [])).toEqual({ viewing: [], typing: [] });
});
