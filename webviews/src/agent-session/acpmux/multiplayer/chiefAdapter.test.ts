// l10n-allow-file: test fixtures (made-up people), not shipped UI.
// Home's people as shared chat faces: people only, never the reader, and a typer counts as here.
import { expect, test } from "bun:test";
import type { HomeParticipant } from "../../../pages/home-channels/types";
import { chiefParticipant, chiefPresence } from "./chiefAdapter";

const person = (id: string, name: string, kind: HomeParticipant["kind"] = "human", chief = false): HomeParticipant => ({
  id,
  name,
  kind,
  chief,
});
const people = new Map(
  [
    person("me", "Me"),
    person("ana", "Ana Ruiz"),
    person("sam", "Sam Okafor"),
    person("chief", "Chief", "agent", true),
  ].map((p) => [p.id, p] as const),
);

test("presence: typers are here too, the reader and agents are not", () => {
  const presence = chiefPresence(people, "me", ["ana", "chief", "me"], ["sam", "ana"]);
  expect(presence.typing.map((p) => p.id)).toEqual(["ana"]);
  expect(presence.viewing.map((p) => p.id)).toEqual(["sam", "ana"]);
  expect(chiefPresence(people, "me", [])).toEqual({ viewing: [], typing: [] });
  // Someone who is not a member of this conversation never draws.
  expect(chiefPresence(people, "me", ["zoe"], ["zoe"])).toEqual({ viewing: [], typing: [] });
});

test("a Home name is cleaned and bounded like an acpmux one", () => {
  const long = new Map([["p", person("p", `\u202E${"n".repeat(200)}`)]]);
  expect(chiefParticipant(long.get("p"))?.name).toBe("n".repeat(64));
  expect(chiefParticipant(people.get("chief"))).toBeUndefined();
});
