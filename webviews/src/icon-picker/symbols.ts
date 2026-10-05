// SF Symbol names as searchable picker items. The host sends the names the running OS draws
// (`cmux.iconPicker.symbols`); the page never bundles symbol images (they are rendered by the host
// per visible cell through `symbolImageURL`). Words come from the dotted name: "person.crop.circle"
// matches "person", "crop" and "circle".
import type { Searchable } from "./search";

export interface SymbolItem extends Searchable {
  readonly name: string;
}

export function symbolItems(names: readonly string[]): SymbolItem[] {
  return names.map((name, index) => {
    const words = name.split(".");
    return {
      index,
      name,
      nameText: `\n${words.join(" ")}\n${name}`,
      searchText: `\n${words.join("\n")}\n${name}`,
    };
  });
}
