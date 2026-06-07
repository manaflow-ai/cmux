export type IconName =
  | "background"
  | "bars"
  | "check"
  | "classic"
  | "collapse"
  | "clipboard"
  | "document"
  | "dots"
  | "expand"
  | "external"
  | "eye"
  | "files"
  | "numbers"
  | "refresh"
  | "search"
  | "sidebarCollapse"
  | "split"
  | "unified"
  | "word"
  | "wrap";

export function Icon({ name }: { name: IconName }) {
  return (
    <svg viewBox="0 0 20 20" aria-hidden="true">
      <IconPaths name={name} />
    </svg>
  );
}

function IconPaths({ name }: { name: IconName }) {
  switch (name) {
  case "background":
    return <><rect x="4" y="4" width="12" height="12" rx="2" /><path d="M7 8h6" /><path d="M7 12h6" /></>;
  case "bars":
    return <><path d="M5 4v12" /><path d="M9 6v8" /><path d="M13 8v4" /></>;
  case "check":
    return <path d="M4 10.5 8 14l8-9" />;
  case "classic":
    return <><path d="M4 5h12" /><path d="M4 10h12" /><path d="M4 15h12" /><path d="M7 3v4" /><path d="M13 8v4" /></>;
  case "collapse":
    return <><path d="M13.5 11.5 10 15 6.5 11.5" /><path d="M6.5 8.5 10 5l3.5 3.5" /></>;
  case "clipboard":
    return <><rect x="5" y="4" width="10" height="13" rx="2" /><path d="M8 4a2 2 0 0 1 4 0" /><path d="M8 7h4" /></>;
  case "document":
    return <><path d="M6 3h6l4 4v10H6z" /><path d="M12 3v5h5" /></>;
  case "dots":
    return <><path d="M5 10h.01" data-precision-dot="true" /><path d="M10 10h.01" data-precision-dot="true" /><path d="M15 10h.01" data-precision-dot="true" /></>;
  case "expand":
    return <path d="M6.5 8 10 11.5 13.5 8" />;
  case "external":
    return <><path d="M7 5H5a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2v-2" /><path d="M11 3h6v6" /><path d="m10 10 7-7" /></>;
  case "eye":
    return <><path d="M2.5 10s2.75-5 7.5-5 7.5 5 7.5 5-2.75 5-7.5 5-7.5-5-7.5-5z" /><circle cx="10" cy="10" r="2.4" /></>;
  case "files":
    return <><rect x="3.5" y="4" width="13" height="12" rx="2" /><path d="M11.5 4v12" /></>;
  case "numbers":
    return <><path d="M5 5h2v10" /><path d="M4 15h4" /><path d="M11 6.5a2 2 0 1 1 3.2 1.6L11 12h4" /><path d="M11 15h4" /></>;
  case "refresh":
    return <><path d="M16 8a6 6 0 0 0-10.3-3.7L4 6" /><path d="M4 3v3h3" /><path d="M4 12a6 6 0 0 0 10.3 3.7L16 14" /><path d="M16 17v-3h-3" /></>;
  case "search":
    return <><circle cx="8.5" cy="8.5" r="4.5" /><path d="m12 12 4 4" /></>;
  case "sidebarCollapse":
    return <><rect x="3.5" y="4" width="13" height="12" rx="2" /><path d="M8 4v12" /><path d="m12 8 2 2-2 2" /></>;
  case "split":
    return <><rect x="4" y="4" width="12" height="12" rx="2" /><rect x="6" y="6" width="3.5" height="8" rx="1" data-diff-deletion="true" /><rect x="10.5" y="6" width="3.5" height="8" rx="1" data-diff-addition="true" /></>;
  case "unified":
    return <><rect x="4" y="4" width="12" height="12" rx="2" /><rect x="6" y="6" width="8" height="3.5" rx="1" data-diff-deletion="true" /><rect x="6" y="10.5" width="8" height="3.5" rx="1" data-diff-addition="true" /></>;
  case "word":
    return <><path d="M3 6h14" /><path d="M3 10h8" /><path d="M3 14h11" /><path d="M14 10h3" /></>;
  case "wrap":
    return <><path d="M3 6h10a4 4 0 0 1 0 8H8" /><path d="m10 11-3 3 3 3" /></>;
  }
}
