import { expect, test } from "bun:test";
import { loadsWithoutClick } from "../src/agent-session/acpmux/chips/ReplyImage";
import type { ReplyPolicy } from "../src/agent-session/acpmux/chips/linkStore";

// Which reply images load without a click under agentPane.images.remote = click: only images
// written exactly https://<a host the host named>/…, never a lookalike, http, a port, user info or
// another spelling the host's own parser could read differently. Leo 2026-10-23: "i feel like this
// is a bit lame idk".
const click: ReplyPolicy = {
  outsideRoots: "confirm",
  remoteImages: "click",
  clickFreeImageHosts: ["raw.githubusercontent.com"],
};

test("a PR's media on raw.githubusercontent.com loads without a click", () => {
  for (const src of [
    "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/24546/before-dark.png",
    "https://raw.githubusercontent.com/manaflow-ai/cmux/pr-media/24546/after-dark.png",
    "https://raw.githubusercontent.com/o/r/main/a.png",
  ])
    expect(loadsWithoutClick(src, click)).toBe(true);
});

test("an unknown host, a lookalike, http, a port, user info or an odd spelling still waits for a click", () => {
  for (const src of [
    "https://images.example.com/a.png",
    // github.com stays behind the click: a release asset's download count shows its owner each fetch.
    "https://github.com/attacker/repo/releases/download/v1/pixel.png",
    "https://github.com/o/r/raw/main/a.png",
    "https://raw.githubusercontent.com.evil.example/a.png",
    "https://evilraw.githubusercontent.com/a.png",
    "https://camo.githubusercontent.com/a.png",
    "https://media.githubusercontent.com/media/o/r/main/a.png",
    "https://evil.example/raw.githubusercontent.com/a.png",
    "https://evil.example/?u=https://raw.githubusercontent.com/a.png",
    "https://evil.example#@raw.githubusercontent.com/a.png",
    "https://raw.githubusercontent.com./a.png",
    "https://raw.githubusercontent.com:443/a.png",
    "https://raw.githubusercontent.com:8443/a.png",
    "https://RAW.githubusercontent.com/a.png",
    "https://raw.githubusercontent%2Ecom/a.png",
    "https://raw.githubusercontent.com\\@evil.example/a.png",
    "https:\\\\raw.githubusercontent.com/a.png",
    " https://raw.githubusercontent.com/a.png",
    "https://raw.githubusercontent.com",
    "https://raw.githubusercontent.com?a.png",
    "http://raw.githubusercontent.com/a.png",
    "https://user:pass@raw.githubusercontent.com/a.png",
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
