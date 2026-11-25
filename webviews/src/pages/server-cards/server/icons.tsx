// The server surfaces' glyphs: 16 px stroke icons on the 16-unit grid, drawn in currentColor.
import type { ReactNode } from "react";

export type ServerIconName =
  | "server"
  | "mac"
  | "terminal"
  | "apps"
  | "database"
  | "browser"
  | "automation"
  | "health"
  | "qr"
  | "pairing"
  | "paired"
  | "team"
  | "devices"
  | "phone"
  | "chief"
  | "chevron"
  | "lock"
  | "external"
  | "pin"
  | "cloud"
  | "ok"
  | "info"
  | "warning"
  | "critical";

const PATHS: Record<ServerIconName, ReactNode> = {
  server: <path d="M2.5 3h11v4h-11zM2.5 9h11v4h-11zM5 5h.01M5 11h.01" />,
  mac: <path d="M2.5 3.5h11v7h-11zM6 13.5h4M8 10.5v3" />,
  terminal: <path d="M2.5 3h11v10h-11zM5 6.5 7 8.25 5 10M8.5 10h2.5" />,
  apps: <path d="M8 2 14 5 8 8 2 5zM2 8l6 3 6-3M2 11l6 3 6-3" />,
  database: (
    <path d="M3 4c0-1.1 2.24-2 5-2s5 .9 5 2-2.24 2-5 2-5-.9-5-2zM3 4v8c0 1.1 2.24 2 5 2s5-.9 5-2V4M3 8c0 1.1 2.24 2 5 2s5-.9 5-2" />
  ),
  browser: (
    <path d="M8 14A6 6 0 1 0 8 2a6 6 0 0 0 0 12zM2 8h12M8 2c1.6 1.7 2.4 3.7 2.4 6S9.6 12.3 8 14M8 2C6.4 3.7 5.6 5.7 5.6 8s.8 4.3 2.4 6" />
  ),
  automation: <path d="M9 1.8 3.5 9h4L7 14.2 12.5 7h-4z" />,
  health: <path d="M1.8 8.2h2.8L6.2 4.6l2.6 7 1.8-3.4h3.6" />,
  qr: (
    <path d="M2.5 2.5h4v4h-4zM9.5 2.5h4v4h-4zM2.5 9.5h4v4h-4zM9.5 9.5h1.5v1.5H9.5zM12 12h1.5v1.5H12zM12 9.5h1.5M9.5 12.5v1" />
  ),
  pairing: (
    <path d="M6.2 9.8 9.8 6.2M7 4.6l1.3-1.3a2.6 2.6 0 0 1 3.7 3.7L10.7 8.3M9 11.4l-1.3 1.3a2.6 2.6 0 0 1-3.7-3.7L5.3 7.7" />
  ),
  paired: <path d="M8 14A6 6 0 1 0 8 2a6 6 0 0 0 0 12zM5.4 8.2l1.8 1.8 3.4-3.6" />,
  team: (
    <path d="M6 7.4a2.2 2.2 0 1 0 0-4.4 2.2 2.2 0 0 0 0 4.4zM2 13.4c0-2.2 1.8-3.8 4-3.8s4 1.6 4 3.8M10.6 3.2a2.2 2.2 0 0 1 0 4.2M11.6 9.8c1.4.4 2.4 1.8 2.4 3.6" />
  ),
  devices: <path d="M1.8 3.5h9v6.5h-9zM4.2 12.5h4.2M12.2 6h2v7.5h-2z" />,
  phone: <path d="M4.5 1.8h7v12.4h-7zM7.2 12.2h1.6" />,
  chief: <path d="M2.6 11.4 2 4.6l3.4 2.6L8 2.8l2.6 4.4L14 4.6l-.6 6.8H2.6zM2.8 13.6h10.4" />,
  chevron: <path d="m6.2 4.5 3.6 3.5-3.6 3.5" />,
  lock: <path d="M3.5 7.2h9v6.6h-9zM5.4 7.2V5a2.6 2.6 0 0 1 5.2 0v2.2" />,
  external: <path d="M9.5 2.5h4v4M13.5 2.5 7.5 8.5M11.5 9.5v4h-9v-9h4" />,
  pin: <path d="M6 2h4l-.6 4 2.6 2.4H4L6.6 6zM8 8.4V14" />,
  cloud: <path d="M4.6 12.6h7a2.8 2.8 0 0 0 .4-5.6 4 4 0 0 0-7.7-.6A3.1 3.1 0 0 0 4.6 12.6zM6 9.4l1.4 1.4 2.8-2.8" />,
  ok: <path d="M8 14A6 6 0 1 0 8 2a6 6 0 0 0 0 12zM5.4 8.2l1.8 1.8 3.4-3.6" />,
  info: <path d="M8 14A6 6 0 1 0 8 2a6 6 0 0 0 0 12zM8 7.4v3.8M8 5h.01" />,
  warning: <path d="M8 2.2 14.2 13H1.8zM8 6.4v3.2M8 11.4h.01" />,
  critical: <path d="M8 14A6 6 0 1 0 8 2a6 6 0 0 0 0 12zM8 4.8v3.8M8 11h.01" />,
};

export function ServerIcon({
  name,
  size = 16,
  className,
}: {
  name: ServerIconName;
  size?: number;
  className?: string;
}) {
  return (
    <svg
      className={className}
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.3}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      style={{ flexShrink: 0 }}
    >
      {PATHS[name]}
    </svg>
  );
}
