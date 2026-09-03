import { randomInt } from "node:crypto";

/**
 * Generated publication names read as `laughing-green-elephants` rather than
 * a hex blob: a descriptor, a colour, and a plural animal. Every word is
 * lowercase ASCII letters only, so any combination is a valid DNS label well
 * under 63 characters. Collisions are expected at scale and are handled by the
 * caller retrying against the database's global hostname claim.
 */
const DESCRIPTORS = [
  "amused", "bold", "brave", "breezy", "bright", "calm", "cheerful", "clever",
  "cosmic", "cozy", "curious", "dancing", "daring", "dreamy", "eager", "fearless",
  "friendly", "gentle", "gleeful", "graceful", "happy", "hopeful", "humble", "jolly",
  "joyful", "kind", "laughing", "lively", "lucky", "merry", "mighty", "nimble",
  "patient", "peaceful", "playful", "proud", "quick", "quiet", "roaming", "sailing",
  "singing", "sleepy", "smiling", "snowy", "sparkling", "speedy", "steady", "sunny",
  "swift", "thoughtful", "tidy", "tranquil", "wandering", "whistling", "wise", "zesty",
] as const;

const COLORS = [
  "amber", "azure", "blue", "bronze", "coral", "crimson", "cyan", "emerald",
  "golden", "green", "indigo", "ivory", "jade", "lavender", "lilac", "magenta",
  "maroon", "olive", "orange", "pink", "purple", "ruby", "silver", "teal",
  "violet", "yellow",
] as const;

const ANIMALS = [
  "badgers", "beavers", "bison", "camels", "cheetahs", "cranes", "dolphins", "eagles",
  "elephants", "falcons", "ferrets", "finches", "foxes", "gazelles", "geckos", "giraffes",
  "hedgehogs", "herons", "jaguars", "kangaroos", "koalas", "lemurs", "leopards", "lions",
  "llamas", "lynxes", "meerkats", "moose", "narwhals", "newts", "ocelots", "orcas",
  "ospreys", "otters", "owls", "pandas", "parrots", "pelicans", "penguins", "puffins",
  "quokkas", "rabbits", "ravens", "salmon", "seals", "sparrows", "squirrels", "storks",
  "swans", "tigers", "toucans", "turtles", "walruses", "wombats", "zebras",
] as const;

/** Returns an integer in `[0, max)`; injectable so tests can pin a label. */
export type FriendlyLabelRandom = (max: number) => number;

export const FRIENDLY_LABEL_PATTERN = /^[a-z]+-[a-z]+-[a-z]+$/u;

export function friendlyPublicationLabel(
  random: FriendlyLabelRandom = randomInt,
): string {
  return `${pick(DESCRIPTORS, random)}-${pick(COLORS, random)}-${pick(ANIMALS, random)}`;
}

/** Exposed for tests that assert every word stays DNS-label safe. */
export function friendlyLabelVocabulary(): {
  readonly descriptors: readonly string[];
  readonly colors: readonly string[];
  readonly animals: readonly string[];
} {
  return { descriptors: DESCRIPTORS, colors: COLORS, animals: ANIMALS };
}

function pick(words: readonly string[], random: FriendlyLabelRandom): string {
  const index = random(words.length);
  if (!Number.isInteger(index) || index < 0 || index >= words.length) {
    throw new Error("friendly label random source returned an out-of-range index");
  }
  return words[index]!;
}
