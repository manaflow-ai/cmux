import { describe, expect, test } from "bun:test";
import { isWarmableCwd } from "./warmFolders";

describe("isWarmableCwd (LAUNCH-NO-TCC-PROMPTS)", () => {
  test("refuses the home folder, / and every guarded location, in any case", () => {
    for (const cwd of [
      "/",
      "/Users/me",
      "/Users/me/",
      "/home/me",
      "/Users/me/Desktop",
      "/Users/me/desktop/x",
      "/Users/me/Documents/app",
      "/Users/me/Downloads/x",
      "/Users/me/Pictures/x",
      "/Users/me/Music/x",
      "/Users/me/Movies/x",
      "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/x",
      "/Users/me/Library/CloudStorage/Dropbox/x",
      "/Users/me/Library/Containers/com.apple.Notes",
      "/Users/me/Library/Group Containers/group.x",
      "/Users/me/Library/Mail/x",
      "/Users/me/Library/Messages",
      "/Users/me/Library/Safari",
      "/Users/me/Library/Calendars/x",
      "/Volumes/External/x",
      "/Network/Servers/x",
      "relative/path",
      "/Users/me/code/../Documents",
    ])
      expect([cwd, isWarmableCwd(cwd)]).toEqual([cwd, false]);
  });

  test("allows ordinary project folders", () => {
    for (const cwd of [
      "/Users/me/code/app",
      "/Users/me/Desktopish/app",
      "/Users/me/Library/Application Support/x",
      "/opt/work",
      "/private/tmp/x",
    ])
      expect([cwd, isWarmableCwd(cwd)]).toEqual([cwd, true]);
  });
});
