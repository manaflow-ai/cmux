import type { Metadata } from "next";
import { LandingCTA } from "../landing-ui";

export const metadata: Metadata = {
  title: "cmux is built on Ghostty (libghostty) — cmux",
  description:
    "cmux uses libghostty, the engine behind Ghostty, for GPU-accelerated terminal rendering, then adds workspaces, vertical tabs, notifications, and a socket API for multitasking and AI coding agents.",
  alternates: { canonical: "https://cmux.com/built-on-ghostty" },
};

export default function BuiltOnGhosttyPage() {
  return (
    <>
      <h1>cmux is built on Ghostty</h1>
      <p>
        cmux is not a fork of Ghostty. It embeds{" "}
        <a
          href="https://github.com/ghostty-org/ghostty"
          className="underline underline-offset-2"
        >
          libghostty
        </a>
        , the library at the core of the Ghostty terminal, for GPU-accelerated
        rendering, the same way an app uses WebKit for web views. Ghostty is a
        standalone terminal; cmux is a different application built on top of its
        rendering engine.
      </p>

      <h2>What cmux adds on top</h2>
      <p>
        libghostty gives cmux a fast, accurate terminal. cmux builds an
        application around it for multitasking, organization, and
        programmability:
      </p>
      <ul>
        <li>
          Workspaces in a vertical sidebar, each showing its git branch, working
          directory, ports, and the latest line of agent output.
        </li>
        <li>Notification rings when a pane needs your attention.</li>
        <li>Vertical tabs and split panes that scale to dozens of sessions.</li>
        <li>
          A CLI and Unix socket API to script workspaces, panes, input, and an
          in-app browser.
        </li>
      </ul>

      <h2>Why libghostty</h2>
      <p>
        Reusing libghostty means cmux inherits Ghostty&apos;s rendering quality
        and performance instead of reimplementing a terminal, and stays focused
        on the workspace, organization, and automation layer that sits above the
        terminal grid. Your existing{" "}
        <code>~/.config/ghostty/config</code> for themes, fonts, and colors is
        read directly.
      </p>

      <LandingCTA
        related={[
          { href: "/best-terminal-for-mac", label: "Best terminal for Mac" },
          { href: "/docs/configuration", label: "Configuration (Ghostty config)" },
          { href: "/docs/getting-started", label: "Get started with cmux" },
        ]}
      />
    </>
  );
}
