// l10n-allow-file: test fixtures (a sample repository's tour).
// The first-open repo tour (repoTour/): when a new chat offers it, the prompt it sends, the
// ```cmux-tour fence a reply draws as a card, and the sent bubble that reads as one line.
import { afterEach, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { Markdown } from "../src/agent-session/acpmux/conversation/Markdown";
import { MessageScopeContext } from "../src/agent-session/acpmux/chips/messageScope";
import { TranscriptReadOnly } from "../src/agent-session/acpmux/conversation/readOnly";
import { TourStartContext } from "../src/agent-session/acpmux/repoTour/TourBlock";
import { TourCard } from "../src/agent-session/acpmux/repoTour/TourCard";
import {
  chipPath,
  dismissTour,
  isTourDismissed,
  offersTour,
  parseTour,
  tourBubbleText,
  TOUR_ASK,
  TOUR_FENCE,
  TOUR_PROMPT,
} from "../src/agent-session/acpmux/repoTour/tourModel";

const tourJson = JSON.stringify({
  head: "3f9c2e1a7b",
  summary: "atlas-web is the dashboard for the Atlas tile server.",
  modules: [
    { path: "src/map/", about: "The map canvas" },
    { path: "./src/api/client.ts", about: "The API client" },
  ],
  run: [{ command: "pnpm dev", about: "Dev server" }],
  tasks: [
    { title: "Add a zoom badge", prompt: "Show the zoom level on the map." },
    { title: "Cache thumbnails", prompt: "Cache style thumbnails by id." },
    { title: "Type API errors", prompt: "Add a typed ApiError." },
    { title: "A fourth task", prompt: "Never drawn: a tour has three." },
  ],
});

afterEach(() => globalThis.localStorage?.clear());

test("the prompt asks for one cmux-tour fence and caches it by HEAD under the git common folder", () => {
  expect(TOUR_PROMPT.startsWith(`${TOUR_ASK}\n`)).toBe(true);
  expect(TOUR_PROMPT).toContain("```" + TOUR_FENCE);
  expect(TOUR_PROMPT).toContain("git rev-parse --git-common-dir");
  expect(TOUR_PROMPT).toContain("<common-dir>/cmux-tour/<HEAD>.md");
  // Read only: the prompt never asks the agent to change the project.
  expect(TOUR_PROMPT).toContain("change, create or delete no file except the one cache file");
  expect(TOUR_PROMPT).toContain("Run no install, build or test");
});

test("a closed fence's JSON reads as a tour: paths chip from the folder, three tasks at most", () => {
  const tour = parseTour("cmux-tour", tourJson)!;
  expect(tour.head).toBe("3f9c2e1a7b");
  expect(tour.modules.map((module) => module.path)).toEqual(["./src/map/", "./src/api/client.ts"]);
  expect(tour.run).toEqual([{ command: "pnpm dev", about: "Dev server" }]);
  expect(tour.tasks.map((task) => task.title)).toEqual(["Add a zoom badge", "Cache thumbnails", "Type API errors"]);
});

test("anything that is not the promised tour is not one, and draws as the code it is", () => {
  expect(parseTour("json", tourJson)).toBeUndefined();
  expect(parseTour("cmux-tour", "{not json")).toBeUndefined();
  expect(parseTour("cmux-tour", "[]")).toBeUndefined();
  expect(parseTour("cmux-tour", JSON.stringify({ modules: [] }))).toBeUndefined();
  // A head that is not a sha is dropped, the tour kept.
  expect(parseTour("cmux-tour", JSON.stringify({ summary: "x", head: "rm -rf" }))?.head).toBeUndefined();
});

test("chipPath leads a bare relative path with ./ and leaves the rest as written", () => {
  expect(chipPath("src/app.ts")).toBe("./src/app.ts");
  expect(chipPath("./src/")).toBe("./src/");
  expect(chipPath("/abs/x.ts")).toBe("/abs/x.ts");
  expect(chipPath("~/x.ts")).toBe("~/x.ts");
});

const base = {
  cwd: "/Users/you/src/atlas-web",
  local: true,
  listed: true,
  sessions: [{ sessionId: "s-other", cwd: "/Users/you/src/relay" }],
  sessionId: "s-this",
  dismissed: () => false,
};

test("a new chat offers the tour only in a project folder no other chat on this Mac has used", () => {
  expect(offersTour(base)).toBe(true);
  // This chat's own entry never makes its folder seen.
  expect(offersTour({ ...base, sessions: [...base.sessions, { sessionId: "s-this", cwd: base.cwd }] })).toBe(true);
  // Another chat used it (a trailing slash is the same folder).
  expect(offersTour({ ...base, sessions: [{ sessionId: "s-old", cwd: `${base.cwd}/` }] })).toBe(false);
  // A peer's or Cloud chat in a folder of the same path is not this Mac's.
  expect(offersTour({ ...base, sessions: [{ sessionId: "s-peer", cwd: base.cwd, peer: "gpu-box" }] })).toBe(true);
  expect(offersTour({ ...base, sessions: [{ sessionId: "s-cloud", cwd: base.cwd, hostKind: "cloud" }] })).toBe(true);
});

test("no offer before the daemon listed its chats, off this Mac, outside a project, or once dismissed", () => {
  expect(offersTour({ ...base, listed: false })).toBe(false);
  expect(offersTour({ ...base, local: false })).toBe(false);
  expect(offersTour({ ...base, cwd: undefined })).toBe(false);
  expect(offersTour({ ...base, cwd: "/Users/you" })).toBe(false);
  expect(offersTour({ ...base, cwd: "/" })).toBe(false);
  expect(offersTour({ ...base, cwd: "/Users/you/Library/Application Support/cmux/agent-home/abc" })).toBe(false);
  expect(offersTour({ ...base, dismissed: (folder) => folder === base.cwd })).toBe(false);
});

test("Not now is kept per folder", () => {
  if (!globalThis.localStorage) return;
  expect(isTourDismissed("/Users/you/src/atlas-web")).toBe(false);
  dismissTour("/Users/you/src/atlas-web/");
  expect(isTourDismissed("/Users/you/src/atlas-web")).toBe(true);
  expect(isTourDismissed("/Users/you/src/relay")).toBe(false);
});

test("the sent tour prompt reads as its first line; any other prompt is left alone", () => {
  expect(tourBubbleText(TOUR_PROMPT)).toBe(TOUR_ASK);
  expect(tourBubbleText(TOUR_ASK)).toBeUndefined();
  expect(tourBubbleText("Give me a short tour of this repository.\nand also fix the build")).toBeUndefined();
});

test("a reply's closed cmux-tour fence draws as the tour card, its paths as chips", () => {
  const html = renderToStaticMarkup(<Markdown>{"Here is the tour.\n\n```cmux-tour\n" + tourJson + "\n```"}</Markdown>);
  expect(html).toContain("acpmux-tour");
  expect(html).toContain("atlas-web is the dashboard");
  expect(html).toContain("Add a zoom badge");
  expect(html).not.toContain("A fourth task");
  // Not the fence's raw JSON.
  expect(html).not.toContain("&quot;summary&quot;");
});

test("a streaming fence is the card's pending line, and a closed fence that is not a tour stays code", () => {
  const streaming = renderToStaticMarkup(<Markdown>{'```cmux-tour\n{"summary": "atl'}</Markdown>);
  expect(streaming).toContain("data-pending");
  expect(streaming).not.toContain("atl&quot;");
  // A streaming reply draws an open fence as streaming code; a tour fence is still the pending card.
  const live = renderToStaticMarkup(<Markdown streaming>{'Here it is.\n\n```cmux-tour\n{"summary": "atl'}</Markdown>);
  expect(live).toContain("data-pending");
  expect(live).not.toContain("atl&quot;");
  const broken = renderToStaticMarkup(<Markdown>{"```cmux-tour\nnot a tour\n```"}</Markdown>);
  expect(broken).not.toContain("acpmux-tour");
  expect(broken).toContain("not a tour");
});

test("Start shows only with a start action; a tour with none reads without buttons", () => {
  const tour = parseTour("cmux-tour", tourJson)!;
  expect(renderToStaticMarkup(<TourCard tour={tour} onStart={() => Promise.resolve()} />)).toContain(
    "acpmux-tour-start",
  );
  expect(renderToStaticMarkup(<TourCard tour={tour} />)).not.toContain("acpmux-tour-start");
});

test("Start is only on this chat's own reply, never on a tour inside another agent's message", () => {
  const reply = "```cmux-tour\n" + tourJson + "\n```";
  const start = () => Promise.resolve();
  const own = renderToStaticMarkup(
    <TourStartContext.Provider value={start}>
      <Markdown>{reply}</Markdown>
    </TourStartContext.Provider>,
  );
  expect(own).toContain("acpmux-tour-start");
  for (const scope of [{}, { host: "gpu-box" }]) {
    const relayed = renderToStaticMarkup(
      <TourStartContext.Provider value={start}>
        <MessageScopeContext.Provider value={scope}>
          <Markdown>{reply}</Markdown>
        </MessageScopeContext.Provider>
      </TourStartContext.Provider>,
    );
    expect(relayed).toContain("Add a zoom badge");
    expect(relayed).not.toContain("acpmux-tour-start");
  }
  const shared = renderToStaticMarkup(
    <TourStartContext.Provider value={start}>
      <TranscriptReadOnly.Provider value>
        <Markdown>{reply}</Markdown>
      </TranscriptReadOnly.Provider>
    </TourStartContext.Provider>,
  );
  expect(shared).not.toContain("acpmux-tour-start");
});
