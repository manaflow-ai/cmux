"use client";

import { Select } from "@base-ui-components/react/select";
import { docsChannelUrl } from "@/app/lib/docs-channel";

type Channel = "release" | "nightly";

function ChannelDot({ channel }: { channel: Channel }) {
  return (
    <span
      aria-hidden
      className={`size-1.5 shrink-0 rounded-full ${
        channel === "release" ? "bg-emerald-500" : "bg-violet-500"
      }`}
    />
  );
}

function ChevronIcon() {
  return (
    <svg aria-hidden width="14" height="14" viewBox="0 0 14 14" fill="none">
      <path
        d="m4 5.5 3 3 3-3"
        stroke="currentColor"
        strokeWidth="1.25"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function CheckIcon() {
  return (
    <svg aria-hidden width="14" height="14" viewBox="0 0 14 14" fill="none">
      <path
        d="m3 7.25 2.5 2.5L11 4.5"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

export function DocsVersionPicker({
  channel,
  releaseLabel,
  nightlyLabel,
}: {
  channel: "release" | "nightly";
  releaseLabel: string;
  nightlyLabel: string;
}) {
  const label = `${releaseLabel} / ${nightlyLabel}`;
  const channels: { value: Channel; label: string }[] = [
    { value: "release", label: releaseLabel },
    { value: "nightly", label: nightlyLabel },
  ];

  return (
    <div className="px-3 pb-4" data-pagefind-ignore="all">
      <Select.Root<Channel>
        items={channels}
        value={channel}
        onValueChange={(value) => {
          if (!value || value === channel) return;
          const { pathname, search, hash } = window.location;
          window.location.assign(
            docsChannelUrl(value, pathname, search, hash),
          );
        }}
      >
        <Select.Trigger
          aria-label={label}
          className="group flex h-9 w-full items-center justify-between rounded-lg border border-border bg-code-bg px-2.5 text-[13px] font-medium text-foreground shadow-sm outline-none transition-colors hover:border-muted focus-visible:ring-2 focus-visible:ring-foreground/20 data-[popup-open]:border-muted"
        >
          <span className="flex min-w-0 items-center gap-2">
            <ChannelDot channel={channel} />
            <Select.Value className="truncate" />
          </span>
          <Select.Icon className="ml-2 shrink-0 text-muted transition-transform group-data-[popup-open]:rotate-180">
            <ChevronIcon />
          </Select.Icon>
        </Select.Trigger>
        <Select.Portal>
          <Select.Positioner
            align="start"
            alignItemWithTrigger={false}
            className="z-[80] w-[var(--anchor-width)] outline-none"
            sideOffset={6}
          >
            <Select.Popup className="w-full origin-[var(--transform-origin)] rounded-lg border border-border bg-background p-1 text-[13px] shadow-[0_12px_32px_rgba(0,0,0,0.16)] outline-none transition-[transform,opacity] data-[ending-style]:scale-95 data-[ending-style]:opacity-0 data-[starting-style]:scale-95 data-[starting-style]:opacity-0">
              <Select.List>
                {channels.map((item) => (
                  <Select.Item
                    key={item.value}
                    value={item.value}
                    className="relative flex h-8 cursor-default select-none items-center gap-2 rounded-md px-2 pr-8 text-muted outline-none data-[highlighted]:bg-code-bg data-[highlighted]:text-foreground data-[selected]:font-medium data-[selected]:text-foreground"
                  >
                    <ChannelDot channel={item.value} />
                    <Select.ItemText>{item.label}</Select.ItemText>
                    <Select.ItemIndicator className="absolute right-2 text-foreground">
                      <CheckIcon />
                    </Select.ItemIndicator>
                  </Select.Item>
                ))}
              </Select.List>
            </Select.Popup>
          </Select.Positioner>
        </Select.Portal>
      </Select.Root>
    </div>
  );
}
