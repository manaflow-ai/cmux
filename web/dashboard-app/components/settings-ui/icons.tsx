/**
 * Small stroke icons for settings controls, drawn on the same 16px grid and
 * 1.25 stroke as the dashboard shell icons.
 */
const common = {
  "aria-hidden": true,
  viewBox: "0 0 16 16",
  fill: "none",
  stroke: "currentColor",
  strokeWidth: 1.25,
  strokeLinecap: "round",
  strokeLinejoin: "round",
} as const;

export function PencilIcon() {
  return (
    <svg {...common} className="size-3.5">
      <path d="M10.5 2.5l3 3L6 13H3v-3z" />
      <path d="M9 4l3 3" />
    </svg>
  );
}

export function UploadIcon() {
  return (
    <svg {...common} className="size-4">
      <path d="M8 10.5V2.5M5 5.5l3-3 3 3" />
      <path d="M2.5 10.5v3h11v-3" />
    </svg>
  );
}

export function MoreIcon() {
  return (
    <svg {...common} className="size-4">
      <circle cx="3.5" cy="8" r="0.6" fill="currentColor" />
      <circle cx="8" cy="8" r="0.6" fill="currentColor" />
      <circle cx="12.5" cy="8" r="0.6" fill="currentColor" />
    </svg>
  );
}

export function ChevronDownIcon({ className = "size-3.5" }: { readonly className?: string }) {
  return (
    <svg {...common} className={className}>
      <path d="m4 6 4 4 4-4" />
    </svg>
  );
}

export function CheckIcon() {
  return (
    <svg {...common} strokeWidth={1.5} className="size-3.5">
      <path d="m3 8.5 3 3 7-7" />
    </svg>
  );
}

export function CopyIcon() {
  return (
    <svg {...common} className="size-3.5">
      <rect x="5.5" y="5.5" width="8" height="8" />
      <path d="M10.5 5.5v-3h-8v8h3" />
    </svg>
  );
}

export function PlusIcon() {
  return (
    <svg {...common} className="size-3.5">
      <path d="M8 3v10M3 8h10" />
    </svg>
  );
}
