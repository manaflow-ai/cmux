import type { Metadata } from "next";
import { useTranslations } from "next-intl";
import { KeyboardShortcuts } from "../../keyboard-shortcuts";

export const metadata: Metadata = {
  title: "Keyboard Shortcuts",
  description:
    "All cmux keyboard shortcuts for workspaces, surfaces, split panes, browser, notifications, find, and window management on macOS.",
};

export default function KeyboardShortcutsPage() {
  const t = useTranslations("docs.keyboardShortcuts");

  return (
    <>
      <h1>{t("title")}</h1>
      <p>{t("description")}</p>
      <KeyboardShortcuts />
    </>
  );
}
