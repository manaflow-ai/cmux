// Settings > Updates' Channels card fixture (`cmux.settings.channels.state`): the host's texts as
// the app sends them in English, a Nightly track with a pulled, a held and a promoted build, the
// installed one among them, Dev with every build, the other rings empty until CI publishes
// ring-tagged builds, and the Go Back a Mac on a Dev build sees when it picks Nightly.
import type { ChannelBuild, ChannelSwitch, ChannelsState } from "./ops";

const repo = "https://github.com/manaflow-ai/cmux";
// A build with no canary verdict (`pending`) has no badge.
const titles = { promoted: "Promoted", held: "Held", pulled: "Pulled", pending: null } as const;

function build(
  number: number,
  commit: string,
  health: ChannelBuild["health"],
  extra: Partial<ChannelBuild> = {},
): ChannelBuild {
  return {
    build: String(number),
    version: `1.0.0-nightly.${number}`,
    date: `2026-10-${String(number - 3400).padStart(2, "0")}`,
    commit,
    commit_url: `${repo}/commit/${commit}`,
    compare_url: `${repo}/compare/3c1d9e0a...${commit}`,
    health,
    health_title: titles[health],
    pulled_reason: null,
    installed: false,
    kept: false,
    prs: [{ number: number * 7, url: `${repo}/pull/${number * 7}` }],
    ...extra,
  };
}

const empty = "No builds on this channel yet.";

const nightlyBuilds = [
  build(3422, "a0f2e3d4", "pending"),
  build(3421, "9f1e2d3c", "pulled", { pulled_reason: "Crashes on launch" }),
  build(3420, "8e0d1c2b", "held"),
  build(3419, "3c1d9e0a", "promoted", { installed: true, compare_url: null }),
  build(3418, "2b0c8d9f", "promoted", { kept: true }),
];

/** Picking Nightly on a Dev build Nightly has not reached: restart into the kept Nightly build. */
export const mockGoBack: ChannelSwitch = {
  ring: "nightly",
  build: "3418",
  action: "Go Back to Nightly",
  detail: "Restarts once into 1.0.0-nightly.3418, kept on this Mac. Settings and sessions stay.",
};

export const mockChannels: ChannelsState = {
  title: "Channels",
  installed: "This Mac runs 1.0.0-nightly.3419.",
  daemon: { title: "acpmux daemon", value: "9f1e2d3c (up to date)" },
  switch: null,
  labels: {
    you_are_here: "You Are Here",
    following: "Following",
    kept: "Kept on This Mac",
    compare: "Changes Since Yours",
    commit: "Commit",
    release: "Release Page",
  },
  tracks: [
    { ring: "stable", title: "Stable", followed: false, release_url: null, empty, builds: [] },
    {
      ring: "nightly",
      title: "Nightly",
      followed: true,
      release_url: `${repo}/releases/tag/nightly-next`,
      empty: null,
      builds: nightlyBuilds,
    },
    { ring: "canary", title: "Canary", followed: false, release_url: null, empty, builds: [] },
    { ring: "dev", title: "Dev", followed: false, release_url: null, empty: null, builds: nightlyBuilds },
  ],
};
