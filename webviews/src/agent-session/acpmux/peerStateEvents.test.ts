import { expect, test } from "bun:test";
import { PeerStateEvents } from "./peerStateEvents";

test("an event received during a snapshot read wins, and reconnect clears its generation", () => {
  const links = new PeerStateEvents();
  links.configure({ _meta: { acpmux: { features: ["peerStateEvents"] } } });
  const before = links.revision;
  links.changed({ peer: "studio-mac", state: "offline", error: "removed", at: 4 });
  links.snapshot({ peers: [{ name: "studio-mac", state: "connected" }] }, before);
  expect([...links.entries()][0]?.[1]).toMatchObject({
    state: "offline",
    connected: false,
    error: "removed",
  });
  links.configure({ _meta: { acpmux: { features: ["peerStateEvents"] } } });
  links.snapshot({ peers: [{ name: "studio-mac", state: "connected" }] }, links.revision);
  expect([...links.entries()][0]?.[1].state).toBe("connected");
  const oldRead = links.readStarted();
  const newRead = links.readStarted();
  links.snapshot({ peers: [{ name: "studio-mac", state: "connected" }] }, links.revision, newRead);
  expect(links.snapshot({ peers: [{ name: "studio-mac", state: "offline" }] }, links.revision, oldRead)).toBe(false);
  expect([...links.entries()][0]?.[1].state).toBe("connected");
  links.snapshot({ peers: [] }, links.revision);
  expect([...links.entries()]).toEqual([]);
  expect(links.authoritative).toBe(true);
  links.configure({ _meta: { acpmux: { features: [] } } });
  expect(links.authoritative).toBe(false);
  expect(links.changed({ peer: "studio-mac", state: "connected", at: 5 })).toBe(false);
  expect([...links.entries()]).toEqual([]);
});
