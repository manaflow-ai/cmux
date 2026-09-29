"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import { Menu } from "@base-ui-components/react/menu";
import posthog from "posthog-js";
import { docsHtmlToMarkdown } from "@/app/lib/docs-markdown";

const menuItemClass =
  "flex cursor-default select-none items-start gap-3 rounded-lg px-2.5 py-2 text-foreground no-underline outline-none data-[highlighted]:bg-code-bg";

const iconProps = {
  width: 15,
  height: 15,
  viewBox: "0 0 24 24",
  fill: "none",
  stroke: "currentColor",
  strokeWidth: 2,
  strokeLinecap: "round" as const,
  strokeLinejoin: "round" as const,
  "aria-hidden": true,
};

function CopyIcon() {
  return (
    <svg {...iconProps}>
      <rect x="9" y="9" width="13" height="13" rx="2" />
      <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
    </svg>
  );
}

function ExternalIcon() {
  return (
    <svg {...iconProps} width={12} height={12}>
      <path d="M7 17 17 7M8 7h9v9" />
    </svg>
  );
}

function pageMarkdown(): string {
  const content = document.querySelector<HTMLElement>("[data-docs-page-body]");
  if (!content) return "";
  return docsHtmlToMarkdown(content, window.location.origin);
}

/**
 * Mintlify-style page actions: copy the page as Markdown, or open it in an
 * assistant with a prompt that points at this URL.
 */
export function DocsPageActions() {
  const t = useTranslations("docs.ui");
  const [copied, setCopied] = useState(false);

  async function copyPage() {
    try {
      await navigator.clipboard.writeText(pageMarkdown());
      setCopied(true);
      posthog.capture("cmuxterm_docs_copy_page", { path: window.location.pathname });
      window.setTimeout(() => setCopied(false), 1600);
    } catch {
      setCopied(false);
    }
  }

  function assistantHref(base: string) {
    const url = `${window.location.origin}${window.location.pathname}`;
    return `${base}${encodeURIComponent(t("askPrompt", { url }))}`;
  }

  function openAssistant(base: string, name: string) {
    posthog.capture("cmuxterm_docs_open_in_assistant", {
      assistant: name,
      path: window.location.pathname,
    });
    window.open(assistantHref(base), "_blank", "noopener,noreferrer");
  }

  return (
    <div
      data-pagefind-ignore="all"
      className="inline-flex h-8 shrink-0 items-stretch overflow-hidden rounded-xl border border-border text-[13px] text-foreground"
    >
      <button
        type="button"
        onClick={copyPage}
        className="flex items-center gap-1.5 px-2.5 transition-colors hover:bg-code-bg focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring"
      >
        <CopyIcon />
        {copied ? t("copied") : t("copyPage")}
      </button>
      <Menu.Root>
        <Menu.Trigger
          aria-label={t("pageActions")}
          className="flex w-7 items-center justify-center border-l border-border text-muted transition-colors hover:bg-code-bg hover:text-foreground data-[popup-open]:bg-code-bg focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring"
        >
          <svg {...iconProps} width={13} height={13}>
            <path d="m6 9 6 6 6-6" />
          </svg>
        </Menu.Trigger>
        <Menu.Portal>
          <Menu.Positioner side="bottom" align="end" sideOffset={6} className="z-[1000]">
            <Menu.Popup className="z-[1000] w-72 origin-[var(--transform-origin)] rounded-xl border border-border bg-background p-1.5 text-[13px] shadow-xl shadow-black/10 outline-none transition duration-150 ease-out data-[ending-style]:scale-[0.97] data-[ending-style]:opacity-0 data-[starting-style]:scale-[0.97] data-[starting-style]:opacity-0">
              <Menu.Item onClick={copyPage} className={menuItemClass}>
                <span className="mt-0.5 flex h-7 w-7 shrink-0 items-center justify-center rounded-md border border-border text-muted">
                  <CopyIcon />
                </span>
                <span className="flex flex-col">
                  <span className="font-medium">{t("copyPage")}</span>
                  <span className="text-[12px] text-muted">{t("copyPageDesc")}</span>
                </span>
              </Menu.Item>
              <Menu.Item
                onClick={() => openAssistant("https://chatgpt.com/?hints=search&q=", "chatgpt")}
                className={menuItemClass}
              >
                <span className="mt-0.5 flex h-7 w-7 shrink-0 items-center justify-center rounded-md border border-border text-[11px] font-semibold text-muted">
                  GPT
                </span>
                <span className="flex flex-col">
                  <span className="flex items-center gap-1 font-medium">
                    {t("openInChatGPT")}
                    <ExternalIcon />
                  </span>
                  <span className="text-[12px] text-muted">{t("openInDesc")}</span>
                </span>
              </Menu.Item>
              <Menu.Item
                onClick={() => openAssistant("https://claude.ai/new?q=", "claude")}
                className={menuItemClass}
              >
                <span className="mt-0.5 flex h-7 w-7 shrink-0 items-center justify-center rounded-md border border-border text-muted">
                  <svg {...iconProps}>
                    <path d="M12 3v18M3 12h18M5.6 5.6l12.8 12.8M18.4 5.6 5.6 18.4" />
                  </svg>
                </span>
                <span className="flex flex-col">
                  <span className="flex items-center gap-1 font-medium">
                    {t("openInClaude")}
                    <ExternalIcon />
                  </span>
                  <span className="text-[12px] text-muted">{t("openInDesc")}</span>
                </span>
              </Menu.Item>
            </Menu.Popup>
          </Menu.Positioner>
        </Menu.Portal>
      </Menu.Root>
    </div>
  );
}
