// A string catalog as the web reads it: a `<Table>.xcstrings` file, or a `<Table>.xcstrings.d/` directory of one
// file per key (`<key>.xcstrings`, each a catalog of that one key; scripts/cmux-next/string_catalogs.py), so two
// pull requests that each add a string add two files and never conflict. Both read as one
// {sourceLanguage, strings, version} object.
import fs from "node:fs";
import path from "node:path";

/** The files a catalog is made of: the file itself, or a directory's entry files in key order. */
export function catalogFiles(file) {
  if (!file.endsWith(".xcstrings.d")) return [file];
  return fs
    .readdirSync(file)
    .filter((name) => name.endsWith(".xcstrings"))
    .sort()
    .map((name) => path.join(file, name));
}

/** The catalog at `file` (a path, absolute or from the working directory), a directory merged into one table. */
export function readCatalog(file) {
  if (!file.endsWith(".xcstrings.d")) return JSON.parse(fs.readFileSync(file, "utf8"));
  const table = { sourceLanguage: "en", strings: {}, version: "1.0" };
  for (const entry of catalogFiles(file)) {
    const one = JSON.parse(fs.readFileSync(entry, "utf8"));
    table.sourceLanguage = one.sourceLanguage;
    table.version = one.version;
    Object.assign(table.strings, one.strings);
  }
  return table;
}
