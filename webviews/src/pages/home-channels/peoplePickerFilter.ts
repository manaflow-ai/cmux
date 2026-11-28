import type { HomeParticipant } from "./types";

/// The picker's rows: the picked ones first in pick order, then the rest matching `needle`. `picked`
/// is looked up through a Set, so a long directory costs O(people + picked), not O(people * picked).
export function shownPeople(
  people: readonly HomeParticipant[],
  picked: ReadonlySet<string>,
  order: readonly string[],
  needle: string,
): HomeParticipant[] {
  const byId = new Map(people.map((person) => [person.id, person]));
  const first = order.flatMap((id) => (byId.has(id) ? [byId.get(id)!] : []));
  const rest = people.filter((person) => !picked.has(person.id));
  return [...first, ...rest.filter((person) => !needle || person.name.toLocaleLowerCase().includes(needle))];
}
