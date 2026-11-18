// l10n-allow-file: gallery and test fixtures (sample agent surfaces), not shipped UI.
// Handwritten `cmux.ui-surface/1` surfaces, as Rust (cmux-ui-surfaces) would normalize them, until its
// golden files exist (cmux-tui/crates/cmux-ui-surfaces/tests/golden/*.json). The two travel samples
// are the A2UI quickstart's `30-refine-search` and `70-traveler-form` after normalization: basic
// catalog components map to nodes, the travel catalog's own widgets become fallbacks.
import type { UiNode, UiSurface, UiSurfacePending } from "./model";

const surface = (id: string, root: UiNode, extra: Partial<UiSurface> = {}): UiSurface => ({
  schema: "cmux.ui-surface/1",
  surfaceId: id,
  source: { kind: "a2ui", server: "quickstart", tool: "get-time" },
  status: "ready",
  root,
  frame: null,
  pending: null,
  ...extra,
});

const action = (id: string, name: string, privileged = true) => ({ id, name, privileged });

// ---------- approval ----------

export const approvalCompact = surface(
  "approval-compact",
  {
    id: "root",
    type: "approval",
    title: "Restart the staging web server?",
    risk: "low",
    facts: [],
    approve: action("a-approve", "approve"),
    deny: action("a-deny", "deny"),
  },
  { source: { kind: "a2ui", server: "ops", tool: "restart-service" } },
);

export const approvalFull = surface(
  "approval-full",
  {
    id: "root",
    type: "approval",
    title: "Book this flight?",
    detail: "The agent will hold the fare for 20 minutes and charge the saved card when you confirm.",
    risk: "medium",
    facts: [
      { label: "Flight", value: "UA 857 SFO → NRT" },
      { label: "Departs", value: "Fri 12 Dec, 11:05" },
      { label: "Seat", value: "32A (window)" },
      { label: "Fare", value: "$1,148.20" },
    ],
    approve: action("a-book", "book"),
    deny: action("a-skip", "skip"),
  },
  { title: "Flight hold", source: { kind: "a2ui", server: "quickstart", tool: "book-flight" } },
);

export const approvalDanger = surface(
  "approval-danger",
  {
    id: "root",
    type: "approval",
    title: "Delete 3 production databases",
    detail: "This drops the databases and their backups. It cannot be undone.",
    risk: "high",
    facts: [
      { label: "Project", value: "acme-prod" },
      { label: "Databases", value: "orders, users, sessions" },
      { label: "Backups", value: "deleted too" },
    ],
    approve: action("a-drop", "drop_databases"),
    deny: action("a-keep", "keep"),
  },
  { source: { kind: "a2ui", server: "db-admin", tool: "drop", claimed: true } },
);

// ---------- review ----------

export const reviewList = surface("review-list", {
  id: "root",
  type: "review",
  title: "Which fix should I apply?",
  prompt: "Both pass the failing test; they differ in what else they touch.",
  options: [
    { id: "o1", label: "Retry the request once", detail: "Two lines in client.ts; hides a flaky network." },
    { id: "o2", label: "Raise the timeout to 30 s", detail: "One constant; slower failure when the server is down." },
    { id: "o3", label: "Queue and retry with backoff", detail: "New module, 80 lines; the most robust." },
  ],
  submit: action("a-pick", "pick_fix"),
  bind: "/fix",
});

export const reviewChips = surface("review-chips", {
  id: "root",
  type: "review",
  title: "Which cities should the trip cover?",
  multi: true,
  options: ["Tokyo", "Kyoto", "Osaka", "Nara", "Hiroshima", "Sapporo", "Fukuoka"].map((city) => ({
    id: city.toLowerCase(),
    label: city,
  })),
  submit: action("a-cities", "set_cities"),
  bind: "/cities",
});

export const reviewRanked = surface("review-ranked", {
  id: "root",
  type: "review",
  title: "Pick the flights to compare",
  prompt: "Sorted by total travel time.",
  multi: true,
  options: [
    { id: "f1", label: "UA 857 · nonstop · 11h 05m", detail: "$1,148 · departs 11:05 · window seats left" },
    { id: "f2", label: "NH 7 · nonstop · 11h 20m", detail: "$1,212 · departs 13:40" },
    { id: "f3", label: "JL 1 · nonstop · 11h 30m", detail: "$1,098 · departs 16:15" },
    { id: "f4", label: "DL 167 · 1 stop SEA · 14h 10m", detail: "$842 · departs 07:30" },
    { id: "f5", label: "AC 738 · 1 stop YVR · 15h 45m", detail: "$799 · departs 06:00" },
  ],
  submit: action("a-compare", "compare"),
  bind: "/compare",
});

// ---------- the travel quickstart (fallback-heavy) ----------

export const travelerForm = surface(
  "inline-5",
  {
    id: "root",
    type: "stack",
    axis: "v",
    children: [
      { id: "title", type: "text", text: "Who is travelling?", style: "heading" },
      { id: "name", type: "field", label: "Full name (as on passport)", input: "text", bind: "/traveler/name" },
      { id: "email", type: "field", label: "Email", input: "text", bind: "/traveler/email" },
      {
        id: "seat",
        type: "field",
        label: "Seat",
        input: "choice",
        options: [
          { value: "window", label: "Window" },
          { value: "aisle", label: "Aisle" },
        ],
        bind: "/traveler/seat",
      },
      {
        id: "save",
        type: "button",
        label: "Save traveller",
        variant: "primary",
        action: action("a-save", "save_traveler"),
      },
    ],
  },
  {
    source: {
      kind: "a2ui",
      server: "travel",
      tool: "collect-traveler",
      catalogId: "https://travel-a2ui.dev/catalogs/a2ui-travel/catalog.json",
    },
  },
);

export const refineSearch = surface(
  "inline-3",
  {
    id: "root",
    type: "stack",
    axis: "v",
    children: [
      { id: "title", type: "text", text: "Refine", style: "heading" },
      { id: "dates", type: "fallback", text: "DateRangePicker (travel catalog)" },
      { id: "who", type: "fallback", text: "TravelerCounter (travel catalog)" },
      {
        id: "budget",
        type: "field",
        label: "Max fare",
        input: "slider",
        min: 150,
        max: 1500,
        value: 600,
        bind: "/filters/maxPrice",
      },
      {
        id: "stops",
        type: "field",
        label: "Stops",
        input: "choice",
        options: [
          { value: "any", label: "Any" },
          { value: "nonstop", label: "Nonstop only" },
        ],
        bind: "/filters/stops",
      },
      { id: "apply", type: "button", label: "Apply", variant: "primary", action: action("a-apply", "apply_filters") },
    ],
  },
  {
    source: {
      kind: "a2ui",
      server: "travel",
      tool: "refine-search",
      catalogId: "https://travel-a2ui.dev/catalogs/a2ui-travel/catalog.json",
    },
  },
);

// ---------- data ----------

export const tableSurface = surface(
  "table",
  {
    id: "root",
    type: "stack",
    axis: "v",
    children: [
      {
        id: "t",
        type: "table",
        columns: [
          { key: "flight", label: "Flight" },
          { key: "stops", label: "Stops" },
          { key: "time", label: "Time", align: "right" },
          { key: "fare", label: "Fare", align: "right" },
        ],
        rows: [
          ["UA 857", "nonstop", "11h 05m", "$1,148"],
          ["NH 7", "nonstop", "11h 20m", "$1,212"],
          ["JL 1", "nonstop", "11h 30m", "$1,098"],
          ["DL 167", "1 (SEA)", "14h 10m", "$842"],
        ],
      },
      { id: "note", type: "text", text: "Fares include taxes; <b>not</b> bags.", style: "caption" },
    ],
  },
  { title: "Flights SFO → NRT", source: { kind: "a2ui", server: "quickstart", tool: "flight-options" } },
);

export const chartSurface = surface(
  "chart",
  {
    id: "root",
    type: "chart",
    kind: "bar",
    yLabel: "Fare (USD)",
    series: [
      {
        name: "Economy",
        points: [
          { x: "Dec 10", y: 1148 },
          { x: "Dec 11", y: 1020 },
          { x: "Dec 12", y: 980 },
          { x: "Dec 13", y: 1210 },
          { x: "Dec 14", y: 1330 },
        ],
      },
      {
        name: "Premium",
        points: [
          { x: "Dec 10", y: 2140 },
          { x: "Dec 11", y: 1980 },
          { x: "Dec 12", y: 1890 },
          { x: "Dec 13", y: 2210 },
          { x: "Dec 14", y: 2400 },
        ],
      },
    ],
  },
  { title: "Fares by day", source: { kind: "a2ui", server: "quickstart", tool: "fare-chart" } },
);

export const progressSurface = surface(
  "progress",
  {
    id: "root",
    type: "stack",
    axis: "v",
    a11y: { live: "polite", label: "Booking progress" },
    children: [
      { id: "p1", type: "progress", label: "Hold the fare", state: "done", value: 1, max: 1 },
      { id: "p2", type: "progress", label: "Reserve seats", state: "running", value: 2, max: 3 },
      { id: "p3", type: "progress", label: "Send confirmation email", state: "running" },
      { id: "p4", type: "progress", label: "Add to calendar", state: "failed", value: 0, max: 1 },
    ],
  },
  { title: "Booking", source: { kind: "a2ui", server: "quickstart", tool: "book-flight" } },
);

/// Every node type the contract names, in one card.
export const kitchenSink = surface(
  "kitchen-sink",
  {
    id: "root",
    type: "stack",
    axis: "v",
    children: [
      { id: "h", type: "text", text: "Trip summary", style: "heading" },
      { id: "b", type: "text", text: "Five nights in Tokyo, then two in Kyoto.", style: "body" },
      {
        id: "row",
        type: "stack",
        axis: "h",
        children: [
          { id: "i1", type: "icon", name: "time", a11y: { label: "Time" } },
          { id: "c1", type: "text", text: "Updated 2 minutes ago", style: "caption" },
          { id: "i2", type: "icon", name: "sparkle-unknown" },
        ],
      },
      { id: "code", type: "text", text: "PNR: X7Q2LM", style: "code" },
      { id: "d", type: "divider" },
      {
        id: "card",
        type: "card",
        children: [
          { id: "img", type: "image", alt: "Map of the route from Tokyo to Kyoto" },
          {
            id: "list",
            type: "list",
            children: [
              { id: "l1", type: "text", text: "Shinkansen Nozomi, 2h 15m", style: "body" },
              { id: "l2", type: "text", text: "Reserved seats, car 7", style: "body" },
            ],
          },
        ],
      },
      { id: "f-check", type: "field", label: "Add travel insurance", input: "checkbox", value: true, bind: "/ins" },
      { id: "f-date", type: "field", label: "Return date", input: "date", value: "2026-12-19", bind: "/ret" },
      { id: "fb", type: "fallback", text: "Video (basic catalog)" },
      {
        id: "btns",
        type: "stack",
        axis: "h",
        children: [
          {
            id: "b1",
            type: "button",
            label: "Cancel trip",
            variant: "danger",
            action: action("a-cancel", "cancel_trip"),
          },
          { id: "b2", type: "button", label: "Share", variant: "secondary", action: action("a-share", "share") },
          { id: "b3", type: "button", label: "Done", variant: "primary", action: action("a-done", "done", false) },
        ],
      },
    ],
  },
  { title: "Trip", source: { kind: "a2ui", server: "quickstart", tool: "trip-panel" } },
);

export const streamingSurface: UiSurface = {
  ...travelerForm,
  surfaceId: "streaming",
  status: "streaming",
  root: {
    ...(travelerForm.root as Extract<UiNode, { type: "stack" }>),
    children: (travelerForm.root as Extract<UiNode, { type: "stack" }>).children.slice(0, 3),
  },
};

export const errorSurface = surface(
  "error",
  { id: "root", type: "text", text: "Your saved search:", style: "body" },
  {
    status: "error",
    error: "The surface went over its 256 KB cap; the rest was cut.",
    source: { kind: "a2ui", server: "travel", tool: "itinerary" },
  },
);

/// What Rust answers for an action (gallery and tests): the host's own words.
export function pendingFor(actionId: string, values: Record<string, unknown>): UiSurfacePending {
  const sends = Object.entries(values).map(([label, value]) => ({
    label: label.replace(/^\//, ""),
    value: Array.isArray(value) ? value.join(", ") : String(value),
  }));
  const listed = sends.map((send) => `${send.label} = ${send.value}`).join(", ");
  return {
    requestId: `r-${actionId}`,
    actionId,
    summary: listed
      ? `Send "${actionId.replace(/^a-/, "")}" to the agent with: ${listed}`
      : `Send "${actionId.replace(/^a-/, "")}" to the agent`,
    sends,
    target: "agent",
  };
}

export const ALL_FIXTURES = {
  approvalCompact,
  approvalFull,
  approvalDanger,
  reviewList,
  reviewChips,
  reviewRanked,
  travelerForm,
  refineSearch,
  tableSurface,
  chartSurface,
  progressSurface,
  kitchenSink,
  streamingSurface,
  errorSurface,
};
