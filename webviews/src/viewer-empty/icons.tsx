// Stroke icons of the empty states and the path picker (16px grid, currentColor), drawn here so
// the empty states do not depend on the diff toolbar's icon set.
export type EmptyIconName = "folder" | "repo" | "file" | "clock" | "chevron";

const PATHS: Record<EmptyIconName, string[]> = {
  folder: [
    "M2 4.5A1.5 1.5 0 0 1 3.5 3h2.6l1.4 1.5h5A1.5 1.5 0 0 1 14 6v5.5a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 2 11.5z",
  ],
  repo: [
    "M2 4.5A1.5 1.5 0 0 1 3.5 3h2.6l1.4 1.5h5A1.5 1.5 0 0 1 14 6v5.5a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 2 11.5z",
    "M6.5 7.25v3.5M6.5 7.25a.75.75 0 1 0 0-.01M9.5 8a.75.75 0 1 0 0-.01M9.5 8.75c0 1-1 1.5-3 1.5",
  ],
  file: ["M4 2.5h5l3 3v8H4z", "M9 2.5v3h3", "M6 9h4M6 11h3"],
  clock: ["M8 2.5a5.5 5.5 0 1 1 0 11 5.5 5.5 0 0 1 0-11z", "M8 5v3l2 1.5"],
  chevron: ["M6 4l4 4-4 4"],
};

export function EmptyIcon({ name, title }: { name: EmptyIconName; title?: string }) {
  return (
    <svg
      className={`ve-icon ve-icon-${name}`}
      viewBox="0 0 16 16"
      width="16"
      height="16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden={title ? undefined : "true"}
      role={title ? "img" : undefined}
      aria-label={title}
    >
      {PATHS[name].map((d) => (
        <path key={d} d={d} />
      ))}
    </svg>
  );
}
