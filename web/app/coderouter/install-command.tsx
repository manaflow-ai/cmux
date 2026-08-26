"use client";

import { useState } from "react";

const command = "curl -fsSL https://cmux.com/coderouter/install.sh | sh";

export function CoderouterInstallCommand() {
  const [copied, setCopied] = useState(false);

  return (
    <div className="mt-8">
      <div className="flex items-center border border-black/15 bg-white">
        <span aria-hidden className="pl-4 font-mono text-sm text-black/35">$</span>
        <pre className="min-w-0 flex-1 overflow-x-auto px-3 py-4 font-mono text-[13px] text-black/75">
          <code>{command}</code>
        </pre>
        <button
          type="button"
          className="mr-2 border border-black/15 px-3 py-2 font-mono text-[11px] text-black/55 hover:border-black/35 hover:text-black"
          onClick={() => {
            void fetch("/api/install-events", {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({
                event: "command_copied",
                product: "coderouter",
                platform: "unix",
                method: "curl",
              }),
              keepalive: true,
            }).catch(() => undefined);
            void navigator.clipboard.writeText(command).then(() => {
              setCopied(true);
              window.setTimeout(() => setCopied(false), 1_500);
            });
          }}
        >
          {copied ? "copied" : "copy"}
        </button>
      </div>
      <div className="mt-3 flex flex-wrap gap-x-5 gap-y-2 font-mono text-[11px] text-black/40">
        <a className="underline underline-offset-4" href="/coderouter/install.sh">
          view script
        </a>
        <span>macOS + Linux</span>
        <span>checksum verified</span>
      </div>
    </div>
  );
}
