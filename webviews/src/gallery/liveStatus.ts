// What the gallery shows about its own source: the commit it serves and, on a live dev server, the
// compile errors outside the shell (dev-server/galleryLive.ts). A static build has its commit only
// (virtual:cmux-gallery/revision, read at build time). A live server also answers
// `<base>__cmux_gallery/status` and pushes `cmux-gallery:status` when the commit or an error
// changes, so the shell's SHA, its age and the error banner follow the checkout.
import revision from "virtual:cmux-gallery/revision";

/** A compile error the live server kept out of Vite's full-page overlay. */
export type LiveError = {
  /** The failing module, under webviews (`src/agent-session/x.gallery.ts`). */
  file: string;
  /** `entry`: reached only through entry files (their cards show it); `stage`: stage code. */
  kind: "entry" | "stage";
  /** The entry files that import the failing module (itself, for an entry file). */
  entries: string[];
  message: string;
  /** Vite's code frame. */
  frame?: string;
  stack?: string;
  plugin?: string;
  id?: string;
  loc?: { file?: string; line: number; column: number };
};

export type Revision = { sha: string; subject: string; committedAt: number; branch: string };
export type LiveStatus = Revision & { live: boolean; errors: LiveError[] };

let status: LiveStatus = { ...revision, live: false, errors: [] };
const listeners = new Set<() => void>();

function set(next: LiveStatus): void {
  status = next;
  for (const listener of listeners) listener();
}

export const liveStatus = {
  subscribe(listener: () => void): () => void {
    listeners.add(listener);
    return () => listeners.delete(listener);
  },
  get: (): LiveStatus => status,
};

/** The server's compile error for one entry file, if it has one. */
export const entryError = (current: LiveStatus, path: string): LiveError | undefined =>
  current.errors.find((error) => error.entries.includes(path));

/** `3 min`, `2 h`, `4 d`: how long ago a unix time (seconds) was. */
export function ageText(seconds: number, now = Date.now()): string {
  const minutes = Math.max(0, Math.floor((now / 1000 - seconds) / 60));
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes} min`;
  const hours = Math.floor(minutes / 60);
  return hours < 48 ? `${hours} h` : `${Math.floor(hours / 24)} d`;
}

if (import.meta.hot) {
  import.meta.hot.on("cmux-gallery:status", (next: Omit<LiveStatus, "live">) => set({ ...next, live: true }));
  void fetch(`${import.meta.env.BASE_URL}__cmux_gallery/status`, { cache: "no-store" })
    .then((response) => (response.ok ? (response.json() as Promise<Omit<LiveStatus, "live">>) : null))
    .then((next) => next && set({ ...next, live: true }))
    .catch(() => undefined);
}
