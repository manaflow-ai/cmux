import { expect, test } from "bun:test";
import { loadsWithoutClick } from "../src/agent-session/acpmux/chips/ReplyImage";
import type { ReplyPolicy } from "../src/agent-session/acpmux/chips/linkStore";

// Which reply images load without a click under agentPane.images.remote = click: only https images
// whose host name is exactly one the host named (GitHub's), never a lookalike, http, another port or
// a URL with user info. Leo 2026-10-23: "i feel like this is a bit lame idk".
const click: ReplyPolicy = {
  outsideRoots: "confirm",
  remoteImages: "click",
  clickFreeImageHosts: ["github.com", "raw.githubusercontent.com"],
};

test("GitHub images load without a click", () => {
  for (const src of [
    "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/24546/before-dark.png",
    "https://RAW.GITHUBUSERCONTENT.COM/manaflow-ai/cmux/pr-media/24546/after-dark.png",
    "https://raw.githubusercontent.com:443/o/r/main/a.png",
    "https://github.com/manaflow-ai/cmux/raw/pr-media/1/a.png",
  ])
    expect(loadsWithoutClick(src, click)).toBe(true);
});

test("an unknown host, a lookalike, http, another port or user info still waits for a click", () => {
  for (const src of [
    "https://images.example.com/a.png",
    "https://raw.githubusercontent.com.evil.example/a.png",
    "https://evilraw.githubusercontent.com/a.png",
    "https://camo.githubusercontent.com/a.png",
    "https://gist.github.com/a.png",
    "https://github.com.evil.example/a.png",
    "https://evil.example/raw.githubusercontent.com/a.png",
    "https://evil.example/?u=https://github.com/a.png",
    "https://evil.example#@raw.githubusercontent.com/a.png",
    "https://raw.githubusercontent.com./a.png",
    "https://raw.githubusercontent.com:8443/a.png",
    "http://raw.githubusercontent.com/a.png",
    "https://user:pass@raw.githubusercontent.com/a.png",
    "https://user@github.com/a.png",
    "/tmp/shots/a.png",
    "not a url",
  ])
    expect(loadsWithoutClick(src, click)).toBe(false);
});

test("only under click, and only for sites the host named", () => {
  const github = "https://raw.githubusercontent.com/o/r/main/a.png";
  expect(loadsWithoutClick(github, { ...click, remoteImages: "never" })).toBe(false);
  expect(loadsWithoutClick(github, { ...click, remoteImages: "always" })).toBe(false); // always loads anyway
  expect(loadsWithoutClick(github, { ...click, clickFreeImageHosts: [] })).toBe(false); // an older host
  expect(loadsWithoutClick(github, { ...click, clickFreeImageHosts: "raw.githubusercontent.com" as never })).toBe(
    false,
  );
});
