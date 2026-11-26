/**
 * `bun scripts/team-key.ts mint --out FILE --id tk-NAME --team TEAM_ID --label KEY=VALUE --max-vms N --max-usd-per-hour USD`:
 * mints a team key (src/auth/team-keys.ts). The key goes only to FILE (mode 0600, refused when FILE exists); stdout is
 * the CMUX_VM_TEAM_KEYS row with its SHA-256, to add to wrangler.jsonc. `hash --in FILE` prints an existing key's
 * hash, for a rotation's second entry. Optional `--max-running-vms N`, `--max-usd-per-day USD` and
 * `--max-usd-per-month USD` add those caps to the row (unset: no limit). Nothing here prints the key.
 */
import { writeFileSync, readFileSync } from "node:fs";
import { Effect } from "effect";
import { generateApiKey, hashApiKey, isApiKeyShaped } from "../src/auth/credentials.ts";
import { parseTeamKeys } from "../src/auth/team-keys.ts";

const USAGE =
  "usage: bun scripts/team-key.ts mint --out FILE --id tk-NAME --team TEAM_ID --label KEY=VALUE --max-vms N --max-usd-per-hour USD\n" +
  "         [--max-running-vms N] [--max-usd-per-day USD] [--max-usd-per-month USD]\n" +
  "       bun scripts/team-key.ts hash --in FILE";

const [command, ...rest] = process.argv.slice(2);
const flags = new Map<string, string>();
for (let index = 0; index < rest.length; index += 2) {
  const flag = rest[index];
  const value = rest[index + 1];
  if (flag === undefined || !flag.startsWith("--") || value === undefined) {
    console.error(USAGE);
    process.exit(2);
  }
  flags.set(flag.slice(2), value);
}
const need = (name: string) => {
  const value = flags.get(name);
  if (value === undefined) {
    console.error(`missing --${name}\n${USAGE}`);
    process.exit(2);
  }
  return value;
};
const optionalCap = (field: string, name: string) => {
  const value = flags.get(name);
  return value === undefined ? {} : { [field]: Number(value) };
};
const sha256 = (key: string) => Effect.runPromise(hashApiKey(key));

if (command === "hash") {
  const key = readFileSync(need("in"), "utf8").trim();
  if (!isApiKeyShaped(key)) {
    console.error("that file does not hold a cmuxvm_sk_ key");
    process.exit(1);
  }
  console.log(await sha256(key));
} else if (command === "mint") {
  const [labelKey, ...labelValue] = need("label").split("=");
  const key = generateApiKey();
  const row = {
    id: need("id"),
    team: need("team"),
    sha256: [await sha256(key)],
    scopes: ["vm:read", "vm:write", "vm:exec"],
    labels: { [labelKey ?? ""]: labelValue.join("=") },
    maxVms: Number(need("max-vms")),
    maxUsdPerHour: Number(need("max-usd-per-hour")),
    ...optionalCap("maxRunningVms", "max-running-vms"),
    ...optionalCap("maxUsdPerDay", "max-usd-per-day"),
    ...optionalCap("maxUsdPerMonth", "max-usd-per-month"),
  };
  // The Worker's own parser: a row it would refuse is never minted.
  if (!parseTeamKeys(JSON.stringify([row])).ok) {
    console.error("the Worker would refuse this row: id tk-[a-z0-9-], VM scopes, one label, maxVms 1..500, maxUsdPerHour (0, 500], maxRunningVms 1..500, maxUsdPerDay (0, 12000], maxUsdPerMonth (0, 372000]");
    process.exit(1);
  }
  writeFileSync(need("out"), `${key}\n`, { mode: 0o600, flag: "wx" });
  console.log(JSON.stringify(row));
} else {
  console.error(USAGE);
  process.exit(2);
}
