// l10n-allow-file: bench fixture names, not shipped UI.
// The real Passwords page over N saved logins (`#n=10000`, two a site), for
// bench/passwords-page-visible-only.bench.ts: a stand-in app that answers every list with a fresh copy
// of all N and lets the bench change one login. `benchRowRenders` counts the logins that rendered since
// its last mark, read from the props React holds on each mounted row's own node, so the page carries
// no counter. (test/support/mountedRowRenders.ts reads the nearest component above the row instead;
// the rows before this change were inline in the page, so that component was the page itself.)
import "../../src/pages/shared/desktop";
import "../../src/pages/shared/pageBase.css";
import "../../src/pages/passwords/styles.css";
import { createRoot } from "react-dom/client";
import { createStrings } from "../../src/pages/shared/i18n";
import table from "../../src/pages/passwords/generated/strings.json";
import { PasswordsPage } from "../../src/pages/passwords/PasswordsPage";
import { MockPasswordsProvider, sampleData } from "../../src/pages/passwords/mockProvider";
import { PasswordsStore } from "../../src/pages/passwords/store";
import { PasswordOps, type SavedPassword } from "../../src/pages/passwords/types";

declare global {
  interface Window {
    benchReady: boolean;
    benchRowRenders: { mark(): void; since(): number };
    /** Changes the `index`th login's username (keeping its place) and has the page read the lists again. */
    benchChangeOne(index: number): void | Promise<void>;
  }
}

const n = Number(new URLSearchParams(location.hash.slice(1)).get("n") ?? 1000);
const NOW = Date.UTC(2026, 10, 18, 12);

class ManyLogins extends MockPasswordsProvider {
  override async call<R>(op: string, params: unknown): Promise<R> {
    const reply = await super.call<R>(op, params);
    return op === PasswordOps.list ? structuredClone(reply) : reply;
  }
}

const data = sampleData();
data.passwords.default = Array.from({ length: n }, (_, index): SavedPassword => ({
  id: `p${index}`,
  site: `site${String(Math.floor(index / 2)).padStart(5, "0")}.example`,
  url: `https://site${index}.example/`,
  username: `person${index}@example.com`,
  created: NOW - 90 * 86_400_000,
  last_used: NOW - index * 60_000,
  times_used: index,
  weak: index % 7 === 0,
  reused: false,
}));
const provider = new ManyLogins(data);
const store = new PasswordsStore(provider);
const root = document.getElementById("root")!;
const strings = createStrings(table, ["en"]);
createRoot(root).render(<PasswordsPage store={store} strings={strings} />);

/** React's props object on a node: the same object until the element that made the node renders again. */
const hostProps = (node: Element) => {
  const key = Object.keys(node).find((name) => name.startsWith("__reactProps$"));
  return key ? (node as unknown as Record<string, unknown>)[key] : undefined;
};
const rows = () => document.querySelectorAll(".pw-site .pw-row");
let seen = new Set<unknown>();
window.benchRowRenders = {
  mark() {
    seen = new Set([...rows()].map(hostProps));
  },
  since() {
    return [...rows()].filter((row) => !seen.has(hostProps(row))).length;
  },
};
window.benchChangeOne = async (index) => {
  const logins = data.passwords.default!;
  logins[index] = { ...logins[index]!, username: `person${index}.changed${Date.now()}@example.com` };
  await store.reload();
};
void store.start().then(() => {
  window.benchReady = true;
});
