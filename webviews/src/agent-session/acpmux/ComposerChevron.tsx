/** The composer chip disclosure, also used beside Details on the start-failure card. */
export function ChevronIcon({
  right = false,
  size = 14,
  className = "acpmux-icon",
}: {
  right?: boolean;
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
      strokeWidth={1.25}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      <path d="M4.6 6.3 8 9.6l3.4-3.3" transform={right ? "rotate(-90 8 8)" : undefined} />
    </svg>
  );
}
