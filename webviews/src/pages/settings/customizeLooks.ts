// The verified looks the Customize checklist lists: every examples/looks/NAME/cmux-setup.json and
// examples/recipes/NAME/cmux-setup.json, read when the page is built (Vite's import.meta.glob), so a
// look or recipe added there shows with no edit here. Under bun's test runner, which has no
// import.meta.glob, the list is empty and tests pass looks to the model themselves.
import index from "../../../../examples/gallery/gallery.json";
import { verifiedLooks, type VerifiedLook } from "./customizeChecklist";

function setups(): Map<string, string> {
  // Vite replaces this call with the files when it builds; bun has no import.meta.glob and throws.
  let files: Record<string, string>;
  try {
    files = import.meta.glob<string>(
      ["../../../../examples/looks/*/cmux-setup.json", "../../../../examples/recipes/*/cmux-setup.json"],
      {
        query: "?raw",
        import: "default",
        eager: true,
      },
    );
  } catch {
    return new Map();
  }
  const out = new Map<string, string>();
  for (const [file, source] of Object.entries(files)) {
    const folder = /examples\/((?:looks|recipes)\/[^/]+)\/cmux-setup\.json$/.exec(file)?.[1];
    if (folder) out.set(folder, source);
  }
  return out;
}

let cached: VerifiedLook[] | undefined;

/** The verified looks, read once. */
export function shippedLooks(): VerifiedLook[] {
  if (cached === undefined) cached = verifiedLooks(index, setups());
  return cached;
}
