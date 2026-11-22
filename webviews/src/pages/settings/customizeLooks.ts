// The verified looks the Customize checklist lists: the examples gallery index and each indexed
// look's cmux-setup.json, read when the page is built (Vite's import.meta.glob), so a look added to
// examples/gallery/gallery.json shows with no edit here. Under bun's test runner, which has no
// import.meta.glob, the list is empty and tests pass looks to the model themselves.
import index from "../../../../examples/gallery/gallery.json";
import { verifiedLooks, type VerifiedLook } from "./customizeChecklist";

type Glob = (pattern: string, options: { query: string; import: string; eager: true }) => Record<string, string>;

function setups(): Map<string, string> {
  const glob = (import.meta as unknown as { glob?: Glob }).glob;
  if (typeof glob !== "function") return new Map();
  const files = import.meta.glob<string>("../../../../examples/looks/*/cmux-setup.json", {
    query: "?raw",
    import: "default",
    eager: true,
  });
  const out = new Map<string, string>();
  for (const [file, source] of Object.entries(files)) {
    const folder = /examples\/(looks\/[^/]+)\/cmux-setup\.json$/.exec(file)?.[1];
    if (folder) out.set(folder, source);
  }
  return out;
}

let cached: VerifiedLook[] | null = null;

/** The verified looks, read once. */
export function shippedLooks(): VerifiedLook[] {
  cached ??= verifiedLooks(index, setups());
  return cached;
}
