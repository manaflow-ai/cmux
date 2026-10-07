import { describe, expect, test } from "bun:test";
import { mockSessions } from "../mockFixture";
import {
  activeSpace,
  browserProfileById,
  openFromHistoryInSpaces,
  openMini,
  promoteMini,
  seedSpaces,
  stepSpace,
  switchSpace,
} from "./spaces";
import { findOpen, openSessionIds } from "./workspaces";

const link = { url: "upload-retry.cmux-preview.pages.dev/fleet", title: "Fleet uploads: retry preview" };

describe("spaces prototype", () => {
  test("every space's agent tabs are fixture sessions and its profile exists", () => {
    const fixture = new Set(mockSessions.map((session) => session.sessionId));
    for (const space of seedSpaces.spaces) {
      for (const id of openSessionIds(space.stack)) expect(fixture.has(id)).toBe(true);
      expect(browserProfileById.has(space.browserProfile)).toBe(true);
    }
  });

  test("switching keeps each space's own stack and selection", () => {
    const atlas = switchSpace(seedSpaces, "space-atlas");
    expect(activeSpace(atlas).stack.activeId).toBe("ws-atlas-light");
    expect(activeSpace(switchSpace(atlas, "space-cmux")).stack).toBe(seedSpaces.spaces[0]!.stack);
    expect(switchSpace(seedSpaces, "space-missing")).toBe(seedSpaces);
  });

  test("stepping wraps both ways", () => {
    expect(stepSpace(seedSpaces, -1).activeId).toBe("space-home");
    expect(stepSpace(stepSpace(seedSpaces, -1), 1).activeId).toBe("space-cmux");
  });

  test("opening a session open in another space jumps to that space", () => {
    const { spaces, jumped } = openFromHistoryInSpaces(seedSpaces, { sessionId: "mock-prorate" });
    expect(jumped).toBe(true);
    expect(spaces.activeId).toBe("space-billing");
    expect(activeSpace(spaces).stack.activeId).toBe("ws-prorate");
  });

  test("a closed session is restored in the current space", () => {
    const atlas = switchSpace(seedSpaces, "space-atlas");
    const { spaces, jumped } = openFromHistoryInSpaces(atlas, { sessionId: "mock-release-notes" });
    expect(jumped).toBe(false);
    expect(spaces.activeId).toBe("space-atlas");
    expect(findOpen(activeSpace(spaces).stack, "mock-release-notes")).toBeDefined();
  });
});

describe("mini window prototype", () => {
  test("takes the source workspace's profile, else its space's", () => {
    const fromTerminal = openMini(
      seedSpaces,
      link,
      { kind: "terminal", label: "stripe listen" },
      {
        spaceId: "space-billing",
        workspaceId: "ws-webhooks",
      },
    );
    expect(fromTerminal.browserProfile).toBe("work");
    expect(fromTerminal.workspaceId).toBe("ws-webhooks");

    const own = {
      ...seedSpaces,
      spaces: seedSpaces.spaces.map((space) =>
        space.id !== "space-cmux"
          ? space
          : {
              ...space,
              stack: {
                ...space.stack,
                workspaces: space.stack.workspaces.map((each) =>
                  each.id === "ws-uploader" ? { ...each, browserProfile: "personal" } : each,
                ),
              },
            },
      ),
    };
    expect(openMini(own, link, { kind: "app", label: "Slack" }).browserProfile).toBe("personal");
  });

  test("a link from another app belongs to the current space and workspace", () => {
    const atlas = switchSpace(seedSpaces, "space-atlas");
    const mini = openMini(atlas, link, { kind: "app", label: "Slack" });
    expect(mini).toMatchObject({ spaceId: "space-atlas", workspaceId: "ws-atlas-light", browserProfile: "atlas" });
  });

  test("promoting adds one tab after the active tab of its workspace, keeping the profile, and shows it", () => {
    const mini = openMini(seedSpaces, link, { kind: "terminal", label: "upload-retry" });
    // The user switched spaces while the mini window was open: promoting goes back to where the link came from.
    const elsewhere = switchSpace(seedSpaces, "space-home");
    const { spaces, tabId } = promoteMini(elsewhere, mini);
    expect(spaces.activeId).toBe("space-cmux");
    const uploader = activeSpace(spaces).stack.workspaces.find((each) => each.id === "ws-uploader")!;
    expect(activeSpace(spaces).stack.activeId).toBe("ws-uploader");
    expect(uploader.activeTabId).toBe(tabId);
    expect(uploader.tabs.map((tab) => tab.id)).toEqual(["agent-mock-session", tabId, "t-uploader", "b-uploader"]);
    expect(uploader.tabs[1]).toMatchObject({ kind: "browser", url: link.url, browserProfile: "work" });
    expect(promoteMini(spaces, mini).tabId).not.toBe(tabId);
  });
});
