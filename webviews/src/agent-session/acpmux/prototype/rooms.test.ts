import { describe, expect, test } from "bun:test";
import { mockSessions } from "../mockFixture";
import {
  activeRoom,
  browserProfileById,
  openFromHistoryInRooms,
  openMini,
  promoteMini,
  seedRooms,
  stepRoom,
  switchRoom,
} from "./rooms";
import { findOpen, openSessionIds } from "./workspaces";

const link = { url: "upload-retry.cmux-preview.pages.dev/fleet", title: "Fleet uploads: retry preview" };

describe("rooms prototype", () => {
  test("every room's agent tabs are fixture sessions and its profile exists", () => {
    const fixture = new Set(mockSessions.map((session) => session.sessionId));
    for (const room of seedRooms.rooms) {
      for (const id of openSessionIds(room.stack)) expect(fixture.has(id)).toBe(true);
      expect(browserProfileById.has(room.browserProfile)).toBe(true);
    }
  });

  test("switching keeps each room's own stack and selection", () => {
    const atlas = switchRoom(seedRooms, "room-atlas");
    expect(activeRoom(atlas).stack.activeId).toBe("ws-atlas-light");
    expect(activeRoom(switchRoom(atlas, "room-cmux")).stack).toBe(seedRooms.rooms[0]!.stack);
    expect(switchRoom(seedRooms, "room-missing")).toBe(seedRooms);
  });

  test("stepping wraps both ways", () => {
    expect(stepRoom(seedRooms, -1).activeId).toBe("room-home");
    expect(stepRoom(stepRoom(seedRooms, -1), 1).activeId).toBe("room-cmux");
  });

  test("opening a session open in another room jumps to that room", () => {
    const { rooms, jumped } = openFromHistoryInRooms(seedRooms, { sessionId: "mock-prorate" });
    expect(jumped).toBe(true);
    expect(rooms.activeId).toBe("room-billing");
    expect(activeRoom(rooms).stack.activeId).toBe("ws-prorate");
  });

  test("a closed session is restored in the current room", () => {
    const atlas = switchRoom(seedRooms, "room-atlas");
    const { rooms, jumped } = openFromHistoryInRooms(atlas, { sessionId: "mock-ci-cache" });
    expect(jumped).toBe(false);
    expect(rooms.activeId).toBe("room-atlas");
    expect(findOpen(activeRoom(rooms).stack, "mock-ci-cache")).toBeDefined();
  });
});

describe("mini window prototype", () => {
  test("takes the source workspace's profile, else its room's", () => {
    const fromTerminal = openMini(
      seedRooms,
      link,
      { kind: "terminal", label: "stripe listen" },
      {
        roomId: "room-billing",
        workspaceId: "ws-webhooks",
      },
    );
    expect(fromTerminal.browserProfile).toBe("work");
    expect(fromTerminal.workspaceId).toBe("ws-webhooks");

    const own = {
      ...seedRooms,
      rooms: seedRooms.rooms.map((room) =>
        room.id !== "room-cmux"
          ? room
          : {
              ...room,
              stack: {
                ...room.stack,
                workspaces: room.stack.workspaces.map((each) =>
                  each.id === "ws-uploader" ? { ...each, browserProfile: "personal" } : each,
                ),
              },
            },
      ),
    };
    expect(openMini(own, link, { kind: "app", label: "Slack" }).browserProfile).toBe("personal");
  });

  test("a link from another app belongs to the current room and workspace", () => {
    const atlas = switchRoom(seedRooms, "room-atlas");
    const mini = openMini(atlas, link, { kind: "app", label: "Slack" });
    expect(mini).toMatchObject({ roomId: "room-atlas", workspaceId: "ws-atlas-light", browserProfile: "atlas" });
  });

  test("promoting adds one tab after the active tab of its workspace, keeping the profile, and shows it", () => {
    const mini = openMini(seedRooms, link, { kind: "terminal", label: "upload-retry" });
    // The user switched rooms while the mini window was open: promoting goes back to where the link came from.
    const elsewhere = switchRoom(seedRooms, "room-home");
    const { rooms, tabId } = promoteMini(elsewhere, mini);
    expect(rooms.activeId).toBe("room-cmux");
    const uploader = activeRoom(rooms).stack.workspaces.find((each) => each.id === "ws-uploader")!;
    expect(activeRoom(rooms).stack.activeId).toBe("ws-uploader");
    expect(uploader.activeTabId).toBe(tabId);
    expect(uploader.tabs.map((tab) => tab.id)).toEqual(["agent-mock-session", tabId, "t-uploader", "b-uploader"]);
    expect(uploader.tabs[1]).toMatchObject({ kind: "browser", url: link.url, browserProfile: "work" });
    expect(promoteMini(rooms, mini).tabId).not.toBe(tabId);
  });
});
