import { randomInt } from "node:crypto";

/**
 * Three-word machine names (`sleepy-teal-otter`). The slug is generated once
 * per machine at create, never changes, and is unique among the owner's live
 * machines. `displayName` stays the free-text label people rename, and the
 * provider id remains the machine address for API and CLI operations.
 *
 * The grammar is deliberately narrow (lowercase ASCII words joined by single
 * hyphens) so the slug is safe in URLs, hostnames, shell arguments, and file
 * names without escaping.
 */
export const VM_SLUG_PATTERN = /^[a-z]+-[a-z]+-[a-z]+(?:-[a-z0-9]{4})?$/;

export function isVmSlug(value: unknown): value is string {
  return typeof value === "string" && VM_SLUG_PATTERN.test(value);
}

/** Words that read badly next to any other word in the lists. Kept here so a
 * list edit that reintroduces one fails the test instead of shipping. */
export const VM_SLUG_BANNED_WORDS: ReadonlySet<string> = new Set([
  "dead", "dumb", "fat", "lazy", "ugly", "sick", "mad", "evil", "dirty", "crazy",
  "stupid", "wet", "hairy", "naked", "bloody", "cursed", "toxic", "rabid",
]);

export const VM_SLUG_ADJECTIVES: readonly string[] = [
  "agile", "ancient", "artful", "bashful", "bold", "bouncy", "brave",
  "breezy", "bright", "brisk", "bubbly", "calm", "cheeky", "cheery", "chilly",
  "chirpy", "clever", "cosmic", "cozy", "crisp", "curious", "dainty", "dapper",
  "daring", "dashing", "dreamy", "eager", "early", "easy", "elegant", "fancy",
  "fearless", "fluffy", "fuzzy", "gentle", "giddy", "gleeful", "glossy", "golden",
  "graceful", "groovy", "happy", "hardy", "hasty", "hearty", "humble", "hungry",
  "jaunty", "jolly", "jovial", "keen", "kind", "lively", "lofty", "loyal",
  "lucky", "lunar", "mellow", "merry", "mighty", "misty", "modest", "nimble",
  "noble", "nifty", "peppy", "perky", "playful", "plucky", "polite", "proud",
  "puffy", "quiet", "quick", "quirky", "rapid", "rosy", "rustic", "shiny",
  "silky", "sleepy", "slick", "smart", "snappy", "sneaky", "snug", "soft",
  "solar", "sparkly", "speedy", "spry", "steady", "sturdy", "sunny", "swift",
  "tidy", "tiny", "toasty", "tranquil", "trusty", "velvet", "vivid", "wandering",
  "warm", "whimsical", "wild", "wise", "witty", "zany", "zesty", "zippy",
];

export const VM_SLUG_COLORS: readonly string[] = [
  "amber", "aqua", "azure", "beige", "blue", "bronze", "cerulean", "cherry",
  "cobalt", "coral", "cream", "crimson", "cyan", "emerald", "fuchsia", "gold",
  "green", "indigo", "ivory", "jade", "lavender", "lemon", "lilac", "lime",
  "magenta", "maroon", "mauve", "mint", "navy", "ochre", "olive", "orange",
  "peach", "pearl", "pink", "plum", "purple", "red", "rose", "ruby", "saffron",
  "sage", "sapphire", "scarlet", "silver", "slate", "tan", "teal", "topaz",
  "violet", "white", "yellow",
];

export const VM_SLUG_ANIMALS: readonly string[] = [
  "alpaca", "ant", "antelope", "armadillo", "axolotl", "badger", "bat", "bear",
  "beaver", "bee", "beetle", "bison", "bobcat", "buffalo", "bunny", "butterfly",
  "camel", "capybara", "cardinal", "caribou", "cat", "chameleon", "cheetah",
  "chickadee", "chinchilla", "chipmunk", "cobra", "condor", "corgi", "cougar",
  "coyote", "crab", "crane", "cricket", "crow", "cuttlefish", "deer", "dingo",
  "dolphin", "donkey", "dove", "dragonfly", "duck", "eagle", "eel", "egret",
  "elephant", "elk", "emu", "falcon", "ferret", "finch", "firefly", "flamingo",
  "fox", "frog", "gazelle", "gecko", "gerbil", "gibbon", "giraffe", "goat",
  "goose", "gopher", "gorilla", "grouse", "gull", "hamster", "hare", "hawk",
  "hedgehog", "heron", "hippo", "hornet", "horse", "hummingbird", "husky",
  "ibex", "ibis", "iguana", "impala", "jackal", "jaguar", "jay", "jellyfish",
  "kangaroo", "kestrel", "kingfisher", "kitten", "kiwi", "koala", "koi",
  "ladybug", "lark", "lemur", "leopard", "lion", "lizard", "llama", "lobster",
  "loon", "lynx", "macaw", "magpie", "manatee", "mantis", "marmot", "meerkat",
  "mink", "mole", "mongoose", "moose", "moth", "mouse", "narwhal", "newt",
  "nightingale", "ocelot", "octopus", "okapi", "oriole", "osprey", "otter",
  "owl", "ox", "oyster", "panda", "panther", "parrot", "peacock", "pelican",
  "penguin", "pheasant", "pigeon", "piglet", "pika", "platypus", "pony",
  "porcupine", "puffin", "puma", "python", "quail", "quokka", "rabbit",
  "raccoon", "raven", "reindeer", "robin", "salamander", "salmon", "sandpiper",
  "seahorse", "seal", "shrimp", "skunk", "sloth", "snail", "sparrow", "squid",
  "squirrel", "starling", "stoat", "stork", "swan", "tapir", "tern",
  "tiger", "toad", "tortoise", "toucan", "trout", "turtle", "urchin", "viper",
  "vole", "wallaby", "walrus", "warbler", "weasel", "whale", "wolf", "wombat",
  "woodpecker", "wren", "yak", "zebra",
];

const SUFFIX_ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789";

export type VmSlugRandom = (upperExclusive: number) => number;

function pick(list: readonly string[], random: VmSlugRandom): string {
  const value = list[random(list.length)];
  if (value === undefined) throw new Error("VM slug word list is empty");
  return value;
}

/** A fresh `adjective-color-animal` slug. `random` is injectable for tests. */
export function generateVmSlug(random: VmSlugRandom = randomInt): string {
  return `${pick(VM_SLUG_ADJECTIVES, random)}-${pick(VM_SLUG_COLORS, random)}-${pick(VM_SLUG_ANIMALS, random)}`;
}

/**
 * The same slug with a short random tail, for the case where every plain
 * candidate collided with a live machine. Still matches VM_SLUG_PATTERN.
 */
export function suffixVmSlug(slug: string, random: VmSlugRandom = randomInt): string {
  let tail = "";
  for (let i = 0; i < 4; i += 1) tail += SUFFIX_ALPHABET[random(SUFFIX_ALPHABET.length)];
  return `${slug}-${tail}`;
}

/** How many plain candidates to try before falling back to a suffixed one. */
export const VM_SLUG_PLAIN_ATTEMPTS = 8;
/** Maximum suffixed candidates to probe before failing the transaction. */
export const VM_SLUG_SUFFIX_ATTEMPTS = 64;

/**
 * Picks a slug no live machine in the scope already uses. `isTaken` answers
 * for one candidate; the caller serializes concurrent creates in the scope
 * (the create transaction holds the per-team advisory lock), so a candidate
 * that is free here is free at insert. After VM_SLUG_PLAIN_ATTEMPTS misses a
 * suffixed candidate is returned; the unique index remains the backstop.
 */
export async function allocateVmSlug(
  isTaken: (candidate: string) => Promise<boolean>,
  random: VmSlugRandom = randomInt,
): Promise<string> {
  let plain = "";
  for (let attempt = 0; attempt < VM_SLUG_PLAIN_ATTEMPTS; attempt += 1) {
    plain = generateVmSlug(random);
    if (!(await isTaken(plain))) return plain;
  }
  for (let attempt = 0; attempt < VM_SLUG_SUFFIX_ATTEMPTS; attempt += 1) {
    const candidate = suffixVmSlug(plain, random);
    if (!(await isTaken(candidate))) return candidate;
  }
  throw new Error("Unable to allocate a unique VM slug");
}
