"use client";

import { useState } from "react";

type Platform = "unix" | "windows";

const commands: Record<Platform, string> = {
  unix: "curl -fsSL https://cmux.com/tui/install.sh | sh",
  windows:
    'powershell -c "irm https://cmux.com/tui/install.ps1 | iex"',
};

function HighlightedCommand({ platform }: { platform: Platform }) {
  if (platform === "unix") {
    return (
      <>
        <span className="text-[#6F42C1] dark:text-[#B392F0]">curl</span>
        <span className="text-[#005CC5] dark:text-[#79B8FF]"> -fsSL</span>
        <span className="text-[#032F62] dark:text-[#9ECBFF]">
          {" https://cmux.com/tui/install.sh"}
        </span>
        <span className="text-[#D73A49] dark:text-[#F97583]"> |</span>
        <span className="text-[#6F42C1] dark:text-[#B392F0]"> sh</span>
      </>
    );
  }

  return (
    <>
      <span>powershell </span>
      <span className="text-[#D73A49] dark:text-[#F97583]">-</span>
      <span>c </span>
      <span className="text-[#032F62] dark:text-[#9ECBFF]">
        {'"irm https://cmux.com/tui/install.ps1 | iex"'}
      </span>
    </>
  );
}

export function TuiInstallTabs({
  unixLabel,
  windowsLabel,
  tabListLabel,
  unixNote,
  windowsNote,
  viewScriptLabel,
  copyLabel,
  copiedLabel,
}: {
  unixLabel: string;
  windowsLabel: string;
  tabListLabel: string;
  unixNote: string;
  windowsNote: string;
  viewScriptLabel: string;
  copyLabel: string;
  copiedLabel: string;
}) {
  const [platform, setPlatform] = useState<Platform>("unix");
  const [copied, setCopied] = useState(false);
  const tabs: { id: Platform; label: string }[] = [
    { id: "unix", label: unixLabel },
    { id: "windows", label: windowsLabel },
  ];
  const scriptHref =
    platform === "unix" ? "/tui/install.sh" : "/tui/install.ps1";

  return (
    <div className="not-prose mt-4">
      <div
        role="tablist"
        aria-label={tabListLabel}
        className="flex items-end text-[13px] sm:text-[15px]"
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
              onClick={() => {
                setPlatform(tab.id);
                setCopied(false);
              }}
              onKeyDown={(event) => {
                if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") {
                  return;
                }
                event.preventDefault();
                const nextPlatform =
                  platform === "unix" ? "windows" : "unix";
                setPlatform(nextPlatform);
                setCopied(false);
                event.currentTarget.parentElement
                  ?.querySelector<HTMLButtonElement>(
                    `#install-tab-${nextPlatform}`,
                  )
                  ?.focus();
              }}
              className={`whitespace-nowrap rounded-t-md border px-3 py-2.5 transition-colors sm:px-4 ${
                selected
                  ? "relative z-10 border-border border-b-code-bg bg-code-bg text-foreground"
                  : "border-transparent text-muted hover:text-foreground"
              }`}
            >
              {tab.label}
            </button>
          );
        })}
        <a
          href={scriptHref}
          target="_blank"
          rel="noreferrer"
          className="mb-px ml-1 whitespace-nowrap px-1 py-2.5 text-muted transition-colors hover:text-foreground sm:ml-3 sm:px-2"
        >
          {viewScriptLabel}
        </a>
      </div>
      <div
        id={`install-panel-${platform}`}
        role="tabpanel"
        aria-labelledby={`install-tab-${platform}`}
      >
        <div className="-mt-px flex items-center gap-3 rounded-b-lg rounded-tr-lg border border-border bg-code-bg px-4 py-4">
          <span aria-hidden className="font-mono text-muted">
            $
          </span>
          <pre className="min-w-0 flex-1 overflow-x-auto font-mono text-[13px] leading-6">
            <code>
              <HighlightedCommand platform={platform} />
            </code>
          </pre>
          <button
            type="button"
            aria-label={copied ? copiedLabel : copyLabel}
            title={copied ? copiedLabel : copyLabel}
            onClick={() => {
              void navigator.clipboard.writeText(commands[platform]).then(() => {
                setCopied(true);
                window.setTimeout(() => setCopied(false), 1500);
              });
            }}
            className="shrink-0 rounded p-1 text-muted transition-colors hover:text-foreground"
          >
            {copied ? (
              <span className="text-xs">{copiedLabel}</span>
            ) : (
              <svg
                aria-hidden
                viewBox="0 0 24 24"
                className="size-4"
                fill="none"
                stroke="currentColor"
                strokeWidth="1.75"
              >
                <rect x="8" y="8" width="11" height="11" rx="2" />
                <path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2" />
              </svg>
            )}
          </button>
        </div>
        <p className="mt-2 text-xs leading-relaxed text-muted">
          {platform === "unix" ? unixNote : windowsNote}
        </p>
      </div>
    </div>
  );
}
