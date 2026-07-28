"use client";

import { useState } from "react";

type Platform = "unix" | "windows";

const commands: Record<Platform, string> = {
  unix: "curl -fsSL https://cmux.com/tui/install.sh | sh",
  windows:
    'powershell -c "irm https://cmux.com/tui/install.ps1 | iex"',
};

export function TuiInstallTabs({
  unixLabel,
  windowsLabel,
  tabListLabel,
  unixNote,
  windowsNote,
}: {
  unixLabel: string;
  windowsLabel: string;
  tabListLabel: string;
  unixNote: string;
  windowsNote: string;
}) {
  const [platform, setPlatform] = useState<Platform>("unix");
  const tabs: { id: Platform; label: string }[] = [
    { id: "unix", label: unixLabel },
    { id: "windows", label: windowsLabel },
  ];

  return (
    <div className="not-prose mt-4">
      <div
        role="tablist"
        aria-label={tabListLabel}
        className="flex border-b border-border text-[13px]"
      >
        {tabs.map((tab) => {
          const selected = platform === tab.id;
          return (
            <button
              key={tab.id}
              id={`install-tab-${tab.id}`}
              type="button"
              role="tab"
              aria-selected={selected}
              aria-controls={`install-panel-${tab.id}`}
              tabIndex={selected ? 0 : -1}
              onClick={() => setPlatform(tab.id)}
              onKeyDown={(event) => {
                if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") {
                  return;
                }
                event.preventDefault();
                const nextPlatform =
                  platform === "unix" ? "windows" : "unix";
                setPlatform(nextPlatform);
                event.currentTarget.parentElement
                  ?.querySelector<HTMLButtonElement>(
                    `#install-tab-${nextPlatform}`,
                  )
                  ?.focus();
              }}
              className={`-mb-px border-b px-3 py-2 transition-colors ${
                selected
                  ? "border-foreground text-foreground"
                  : "border-transparent text-muted hover:text-foreground"
              }`}
            >
              {tab.label}
            </button>
          );
        })}
      </div>
      <div
        id={`install-panel-${platform}`}
        role="tabpanel"
        aria-labelledby={`install-tab-${platform}`}
      >
        <pre className="overflow-x-auto rounded-b-lg bg-code-bg px-4 py-4 font-mono text-[13px] leading-6">
          <code>{commands[platform]}</code>
        </pre>
        <p className="mt-2 text-xs leading-relaxed text-muted">
          {platform === "unix" ? unixNote : windowsNote}
        </p>
      </div>
    </div>
  );
}
