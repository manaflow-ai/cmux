import React, { useEffect, useRef } from "react";
import { useT, type StringKey } from "../i18n";
import { Icon } from "../icons/Icon";
import type { PermissionGroup, PermissionGroupItem } from "./protocol";

function record(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
}
const text = (value: unknown) => (typeof value === "string" && value.trim() ? value : undefined);
const kinds: Record<string, { icon: string; label: StringKey }> = {
  execute: { icon: "tool.shell", label: "permission.kind.execute" },
  edit: { icon: "tool.edit", label: "permission.kind.edit" },
  read: { icon: "tool.read", label: "permission.kind.read" },
  fetch: { icon: "tool.web", label: "permission.kind.fetch" },
};

export function requestDetails(item: PermissionGroupItem, cwd?: string) {
  const tool = record(item.request.toolCall);
  const input = record(tool?.rawInput);
  const kind = text(tool?.kind) ?? "other";
  const locations = Array.isArray(tool?.locations)
    ? tool.locations.flatMap((location) => text(record(location)?.path) ?? [])
    : [];
  return {
    tool,
    kind,
    ...(kinds[kind] ?? { icon: "tools", label: "permission.toolRequest" as const }),
    title: (kind === "execute" ? (text(input?.command) ?? text(input?.cmd)) : undefined) ?? text(tool?.title),
    folder: text(input?.cwd) ?? text(input?.working_directory) ?? cwd,
    locations,
  };
}

export function ShortcutHint({ shortcut }: { shortcut?: string }) {
  return shortcut ? (
    <kbd
      aria-hidden="true"
      className="ml-1 inline-flex shrink-0 rounded border border-solid border-edge px-1 font-sans text-caption text-dim opacity-0 group-hover/permission:opacity-100 group-focus-within/permission:opacity-100 group-data-[shortcut-hints=true]/permission:opacity-100"
    >
      {shortcut}
    </kbd>
  ) : null;
}

export function RequestRows({
  group,
  expandSignal,
  expandShortcut,
  cwd,
}: {
  group: PermissionGroup;
  expandSignal: number;
  expandShortcut?: string;
  cwd?: string;
}) {
  const t = useT();
  const container = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (expandSignal === 0) return;
    container.current?.querySelectorAll("details").forEach((details) => {
      details.open = true;
    });
  }, [expandSignal]);
  return (
    <div
      className="acpmux-permission-items mt-3 divide-x-0 divide-y divide-solid divide-edge rounded-lg bg-base"
      ref={container}
    >
      {group.items.map((item, index) => {
        const { tool, icon, label, title, folder, locations } = requestDetails(item, cwd);
        return (
          <details key={item.permissionId}>
            <summary
              className="flex min-h-11 cursor-pointer list-none items-center gap-2 rounded-lg px-3 py-2 text-fg outline-offset-[-2px] hover:bg-hover focus-visible:outline focus-visible:outline-1 focus-visible:outline-fg [&::-webkit-details-marker]:hidden"
              onKeyDown={(event) => {
                if (event.key !== "Enter" && event.key !== " ") return;
                event.preventDefault();
                if (event.repeat || event.altKey || event.metaKey || event.ctrlKey || event.nativeEvent.isComposing)
                  return;
                const details = event.currentTarget.parentElement as HTMLDetailsElement;
                details.open = !details.open;
              }}
            >
              <Icon name={icon} className="shrink-0 text-muted" />
              <span className="min-w-0 flex-1">
                <span className="line-clamp-2 break-all font-mono text-body">
                  {title ?? t("permission.toolRequest")}
                </span>
                <span className="mt-0.5 flex min-w-0 flex-wrap items-center gap-x-2 text-caption text-muted">
                  <span>{t(label)}</span>
                  {folder && (
                    <span className="min-w-0 break-all font-mono" dir="auto">
                      {folder}
                    </span>
                  )}
                  {!folder && locations[0] && (
                    <span className="min-w-0 break-all font-mono" dir="auto">
                      {locations[0]}
                    </span>
                  )}
                  {item.state !== "pending" && (
                    <span>
                      {t(item.state === "cancelled" ? "permission.itemCancelled" : "permission.itemResolved")}
                    </span>
                  )}
                </span>
              </span>
              {index === 0 && <ShortcutHint shortcut={expandShortcut} />}
              <Icon name="disclosure.collapsed" className="shrink-0 text-dim [[open]>summary>&]:rotate-90" />
            </summary>
            <div className="px-3 pb-3 text-caption text-muted">
              {locations.length > 0 && (
                <ul className="my-2 list-none p-0 font-mono">
                  {locations.map((path, i) => (
                    <li className="break-all" key={i}>
                      {path}
                    </li>
                  ))}
                </ul>
              )}
              {tool?.rawInput !== undefined && (
                <pre className="m-0 max-h-56 overflow-auto whitespace-pre-wrap break-all rounded-md border border-solid border-edge bg-menu p-3 font-mono text-caption text-fg">
                  {typeof tool.rawInput === "string" ? tool.rawInput : JSON.stringify(tool.rawInput, null, 2)}
                </pre>
              )}
              {tool?.content !== undefined && (
                <pre className="mb-0 max-h-56 overflow-auto whitespace-pre-wrap break-all rounded-md border border-solid border-edge bg-menu p-3 font-mono text-caption text-fg">
                  {JSON.stringify(tool.content, null, 2)}
                </pre>
              )}
              {tool?.rawInput === undefined && tool?.content === undefined && (
                <p className="m-0">{t("permission.noInput")}</p>
              )}
            </div>
          </details>
        );
      })}
    </div>
  );
}
