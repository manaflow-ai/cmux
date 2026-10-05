// An in-memory `cmux.changelog.*` provider for the browser dev loop (`/changelog/?mock`) and tests.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { ACTION_RUN, ChangelogOps, type ListResult, type ReleaseNotes } from "./types";

export const sampleNotes: ReleaseNotes[] = [
  {
    build: "3720357958802",
    shortVersion: "1.0.0-nightly.3720357958802",
    date: "2026-10-05",
    highlights: [
      {
        id: "update-card",
        title: "Updates you barely notice",
        body: "Updates download in the background.\n\nWhen one is ready, one click restarts into it and every terminal keeps running.",
        action: { id: "palette.checkForUpdates", title: "Try it" },
      },
    ],
    changes: ["updates: R114 install gate", "sidebar: card stack above the spaces dots"],
  },
  {
    build: "3720357958801",
    shortVersion: "1.0.0-nightly.3720357958801",
    date: "2026-10-04",
    highlights: [],
    changes: ["browser: faster tab restore"],
  },
];

export class MockChangelogProvider implements PageClient {
  readonly ran: string[] = [];
  constructor(private readonly notes: ReleaseNotes[] = sampleNotes, private readonly current = notes[0]?.build ?? "") {}

  async call<R>(op: string, params: unknown): Promise<R> {
    const p = (params ?? {}) as Record<string, unknown>;
    if (op === ChangelogOps.list) {
      const result: ListResult = {
        current: this.current,
        builds: this.notes.map((n) => ({ build: n.build, shortVersion: n.shortVersion, date: n.date, highlights: n.highlights.length })),
      };
      return result as R;
    }
    if (op === ChangelogOps.get) {
      const found = this.notes.find((n) => n.build === p.build);
      if (!found) throw pageError("cmux.changelog.not_found", "No verified notes for this build", true);
      return found as R;
    }
    if (op === ACTION_RUN) {
      this.ran.push(String(p.action));
      return {} as R;
    }
    throw pageError("cmux.operation.unsupported", op);
  }

  async subscribe(): Promise<() => void> {
    return () => undefined;
  }

  handle(_op: string, _handler: PageHandler): () => void {
    return () => undefined;
  }
}
