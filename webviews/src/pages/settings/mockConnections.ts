// l10n-allow-file: mock catalog data; the real labels come from cmux-tui cli/mcp_servers.rs.
// The mock Settings > Integrations > Connections: a catalog shaped like `cmux mcp-servers catalog --json` and the
// host's answers to each gesture (SettingsConnections), so the card, its tests and its gallery run
// with no CLI and no platform. Pure data: the gallery imports these fixtures.
import type { ConnectionEntry, ConnectionsCatalog, ConnectionsRun, ConnectionsState } from "./ops";
import { rowsByKey, schema, type SchemaRow } from "./schema";

/** The Labs toggle that lists Slack and Google (ConnectionsPanel `UPCOMING_KEY`). */
export const CONNECTIONS_UPCOMING_LAB = "labs.connectionsUpcoming";

/** Tests and the gallery: the Labs row `labs.connectionsUpcoming` in the page's schema when the
 * checked-in export (settings-schema.json, regenerated on a Mac) does not have it yet, shaped like
 * the other Labs toggles; a no-op once the export lists it. */
export function ensureConnectionsUpcomingLabRow(): void {
  if (rowsByKey.has(CONNECTIONS_UPCOMING_LAB)) return;
  const like = schema.rows.find(
    (row) => row.section === "advanced" && row.kind === "toggle" && row.key.startsWith("labs."),
  );
  if (!like) throw new Error("no Labs toggle to copy");
  const row: SchemaRow = {
    ...structuredClone(like),
    key: CONNECTIONS_UPCOMING_LAB,
    path: ["labs", "connectionsUpcoming"],
    default: false,
    title: { key: "settings.labs.connectionsUpcoming", text: "Upcoming Connections" },
    help: {
      key: "settings.labs.connectionsUpcoming.help",
      text: "Lists Slack and Google in Connections before they can be connected.",
    },
  };
  schema.rows.push(row);
  (rowsByKey as Map<string, SchemaRow>).set(row.key, row);
}

const base = {
  category: null,
  docsUrl: null,
  available: true,
  keyField: false,
  connectionId: null,
  owner: null,
  ownerLabel: null,
  toolCount: null,
  toolsLabel: null,
  statusLabel: null,
  buttonLabel: "Connect",
  state: "connect",
  auth: "dcr",
  loopback: false,
  upcoming: false,
} satisfies Partial<ConnectionEntry>;

const tools = (count: number) => (count === 1 ? "1 tool" : `${count} tools`);

/** A connected entry, as the CLI shapes a `ready` connection. */
export function connected(
  entry: ConnectionEntry,
  id: string,
  count: number,
  owner: "me" | "team" = "me",
): ConnectionEntry {
  return {
    ...entry,
    state: "connected",
    connectionId: id,
    owner,
    ownerLabel: owner === "team" ? "Team" : "Personal",
    toolCount: count,
    toolsLabel: tools(count),
    statusLabel: `Connected · ${tools(count)}`,
    buttonLabel: null,
  };
}

const notSetUp = {
  auth: "client",
  available: false,
  state: "unavailable",
  statusLabel: "Not set up on this deployment yet.",
  buttonLabel: null,
} satisfies Partial<ConnectionEntry>;

/** The platform's catalog in rank order: the top five connect in one tap (Vercel signs in back to a
 * listener on this Mac), then a key server, an unavailable one, and Slack and Google, which list
 * only with labs.connectionsUpcoming on. */
export const MOCK_CATALOG: ConnectionEntry[] = [
  { ...base, name: "linear", title: "Linear", line: "Issues, projects and cycles.", rank: 1, category: "work" },
  { ...base, name: "sentry", title: "Sentry", line: "Errors, issues and releases.", rank: 2, category: "dev" },
  {
    ...base,
    name: "atlassian",
    title: "Atlassian",
    line: "Jira issues and Confluence pages.",
    rank: 3,
    category: "work",
  },
  { ...base, name: "notion", title: "Notion", line: "Pages, databases and comments.", rank: 4, category: "work" },
  {
    ...base,
    name: "vercel",
    title: "Vercel",
    line: "Projects, deployments and logs.",
    rank: 5,
    category: "dev",
    loopback: true,
  },
  {
    ...base,
    name: "github",
    title: "GitHub",
    line: "Repositories, pull requests and issues.",
    rank: 6,
    category: "dev",
  },
  { ...base, name: "exa", title: "Exa", line: "Web search built for agents.", rank: 7, auth: "key", keyField: true },
  { ...base, ...notSetUp, name: "figma", title: "Figma", line: "Design files, comments and components.", rank: 8 },
  {
    ...base,
    ...notSetUp,
    name: "slack",
    title: "Slack",
    line: "Channels, threads and messages.",
    rank: 9,
    category: "work",
    upcoming: true,
  },
  {
    ...base,
    ...notSetUp,
    name: "gmail",
    title: "Gmail",
    line: "Mail, threads and drafts.",
    rank: 10,
    category: "google",
    upcoming: true,
  },
  {
    ...base,
    ...notSetUp,
    name: "google-calendar",
    title: "Google Calendar",
    line: "Events, invites and free time.",
    rank: 11,
    category: "google",
    upcoming: true,
  },
  {
    ...base,
    ...notSetUp,
    name: "google-drive",
    title: "Google Drive",
    line: "Files, Docs and Sheets.",
    rank: 12,
    category: "google",
    upcoming: true,
  },
];

/** The catalog with `linear` connected for the team and `sentry` for the person. */
export function mockConnectionsCatalog(entries: ConnectionEntry[] = defaultEntries()): ConnectionsCatalog {
  return {
    ok: true,
    available: true,
    connected: entries.filter((entry) => entry.connectionId).length,
    entries,
  };
}

function defaultEntries(): ConnectionEntry[] {
  return MOCK_CATALOG.map((entry) => {
    if (entry.name === "linear") return connected(entry, "mcs_mock_linear", 23, "team");
    if (entry.name === "sentry") return connected(entry, "mcs_mock_sentry", 14);
    return entry;
  });
}

export function mockConnectionsState(catalog: ConnectionsCatalog | null = mockConnectionsCatalog()): ConnectionsState {
  return { loading: false, problem: null, catalog, error: null, pending: null };
}

/** The host's answer to one gesture: Connect connects at once (a key, or the mock's sign-in
 * coming straight back); Reconnect and Turn On make it ready; Disconnect removes it. */
export function runMockConnections(state: ConnectionsState, run: ConnectionsRun): ConnectionsState {
  if (run.action === "refresh" || state.catalog?.ok !== true) return state;
  const entries = state.catalog.entries.map((entry): ConnectionEntry => {
    if (run.action === "connect" && entry.name === run.name)
      return connected(entry, `mcs_mock_${entry.name}`, 8, run.owner);
    if (run.action !== "connect" && entry.connectionId === run.id) {
      if (run.action === "remove") {
        const plain = MOCK_CATALOG.find((item) => item.name === entry.name);
        return plain ?? entry;
      }
      return connected(entry, run.id, entry.toolCount ?? 8, entry.owner ?? "me");
    }
    return entry;
  });
  return { ...state, catalog: mockConnectionsCatalog(entries), error: null };
}
