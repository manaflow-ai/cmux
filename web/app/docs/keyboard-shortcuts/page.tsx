import type { Metadata } from "next";
import { KeyboardShortcuts } from "../../keyboard-shortcuts";

export const metadata: Metadata = {
  title: "Keyboard Shortcuts",
  description:
    "All cmux keyboard shortcuts for workspaces, surfaces, split panes, browser, notifications, find, and window management on macOS.",
};

export default function KeyboardShortcutsPage() {
  return (
    <>
      <h1>Keyboard Shortcuts</h1>
      <p>
        All keyboard shortcuts available in cmux, grouped by category.
      </p>
      <KeyboardShortcuts />
    </>
  );
}
