// l10n-allow-file: gallery fixtures (a sample repository's tour), not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { StartTourTask } from "./TourCard";
import type { Tour } from "./tourModel";

type Props = { tour?: Tour; onStart?: StartTourTask };

const tour: Tour = {
  head: "3f9c2e1a7b",
  summary:
    "atlas-web is the dashboard for the Atlas tile server: a React app that draws map layers and lets teams publish styles.",
  modules: [
    { path: "./src/map/", about: "The map canvas, layers and the tile cache" },
    { path: "./src/styles/", about: "Style editor and the publish flow" },
    { path: "./src/api/client.ts", about: "Typed client for the tile server's REST API" },
    { path: "./server/", about: "Dev proxy and auth for local runs" },
    { path: "./e2e/", about: "Playwright tests of the publish flow" },
  ],
  run: [
    { command: "pnpm install", about: "Once per checkout" },
    { command: "pnpm dev", about: "App on localhost:5173 with the dev proxy" },
    { command: "pnpm test", about: "Unit tests" },
  ],
  tasks: [
    {
      title: "Add a zoom level badge to the map",
      prompt:
        "Show the current zoom level in the bottom-left corner of the map canvas (src/map/MapCanvas.tsx), updating as the user zooms. Add a unit test.",
    },
    {
      title: "Cache style thumbnails",
      prompt:
        "Style thumbnails in src/styles/StyleList.tsx are fetched on every render. Cache them by style id and version, and drop the cache entry when a style is republished.",
    },
    {
      title: "Type the tile server errors",
      prompt:
        "src/api/client.ts throws plain Errors. Add a typed ApiError with the status and the server's code, and use it at the three call sites that check status codes.",
    },
  ],
};

const never: StartTourTask = () => new Promise(() => undefined);
const fails: StartTourTask = () => Promise.reject(new Error("atlas-web has uncommitted changes in a worktree"));

const startFirst: Play = async (ctx) => {
  await ctx.click({ selector: ".acpmux-tour-start" });
};

export default componentEntry<Props>({
  id: "agent-pane.repo-tour-card",
  title: "Repo tour card",
  area: "Agent pane",
  covers: ["agent-session/acpmux/repoTour/TourCard.tsx#TourCard"],
  load: () => import("./TourCard").then((module) => module.TourCard),
  styles: () => import("../styles.css"),
  widths: { narrow: 360, normal: 640, wide: 900 },
  height: 560,
  variants: {
    tour: {
      note: "A reply's ```cmux-tour fence: what it is, modules as path chips, how to run it, three first tasks with Start.",
      props: { tour, onStart: never },
    },
    writing: {
      note: "The fence is still streaming: one quiet line in the card's frame, never half-parsed JSON.",
      props: {},
    },
    starting: {
      note: "Start pressed: the button reads Starting… while the worktree and chat are made.",
      props: { tour, onStart: never },
      play: startFirst,
    },
    failed: {
      note: "Start failed: the host's reason under the task; Start can be pressed again.",
      props: { tour, onStart: fails },
      play: startFirst,
    },
    "read-only": {
      note: "A shared or remote transcript has no Start: the tour reads, nothing runs.",
      props: { tour: { ...tour, head: undefined } },
    },
    sparse: {
      note: "A small repository: no run commands, two modules.",
      props: {
        tour: {
          summary: "A single-file CLI that renames photos by EXIF date.",
          modules: tour.modules.slice(0, 2),
          run: [],
          tasks: tour.tasks.slice(0, 1),
        },
        onStart: never,
      },
    },
  },
});
