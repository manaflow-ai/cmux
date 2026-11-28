import {
  adjectives,
  animals,
  colors,
  uniqueNamesGenerator,
} from "unique-names-generator";

/**
 * Generated publication names read as `laughing-green-elephant` rather than a
 * hex blob: one adjective, one colour, and one animal from the
 * `unique-names-generator` dictionaries. The dictionaries are filtered to
 * lowercase ASCII words at load time so every label is DNS-safe even if the
 * package adds a word with a space or an apostrophe later. Collisions are
 * expected at scale and are handled by the caller retrying against the
 * database's global hostname claim.
 */
const DNS_LABEL_WORD = /^[a-z]+$/u;

const DICTIONARIES = [adjectives, colors, animals].map((words) =>
  words.filter((word) => DNS_LABEL_WORD.test(word)),
);

export const FRIENDLY_LABEL_PATTERN = /^[a-z]+-[a-z]+-[a-z]+$/u;

/** A `seed` pins the label for tests; production callers leave it unset. */
export function friendlyPublicationLabel(seed?: number | string): string {
  return uniqueNamesGenerator({
    dictionaries: DICTIONARIES,
    separator: "-",
    style: "lowerCase",
    length: DICTIONARIES.length,
    ...(seed === undefined ? {} : { seed }),
  });
}

/** Exposed for tests that assert the vocabulary stays DNS-label safe. */
export function friendlyLabelVocabulary(): readonly (readonly string[])[] {
  return DICTIONARIES;
}
