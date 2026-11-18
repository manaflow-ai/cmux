// Writes look/profile.json from look/src: the settings with the theme and chat stylesheet inlined.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
const here = path.dirname(fileURLToPath(import.meta.url));
const read = (file) => fs.readFileSync(path.join(here, "src", file), "utf8");
const profile = {
  cmuxProfile: 1,
  name: "studio",
  description:
    "studio: true black, a sidebar of chats on three lines (project and time, title, branch), a 46rem chat column, your prompt in a dark pill, a rounded composer with a deep shadow, an indigo primary.",
  settings: JSON.parse(read("settings.json")),
  files: {
    "themes/studio.json": read("theme.json"),
    "agent-pane/theme.css": read("agent-pane.css"),
    "customize/cmux-app.json": fs.readFileSync(path.join(here, "customize", "cmux-app.json"), "utf8"),
    "customize/main.js": fs.readFileSync(path.join(here, "customize", "main.js"), "utf8"),
  },
};
fs.writeFileSync(path.join(here, "profile.json"), `${JSON.stringify(profile, null, 2)}\n`);
