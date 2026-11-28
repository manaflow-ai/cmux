/// The chips' chevron (ComposerPickers.tsx ChevronIcon) turned right at 12px, for a disclosure that sits over the chips
/// (ErrorDetails' Details on New Tab's start failure); `className` carries the rotor and open state.
export const ChipDisclosureChevron = ({ className }: { className: string }) => (
  <svg
    className={className}
    width={12}
    height={12}
    viewBox="0 0 16 16"
    fill="none"
    stroke="currentColor"
    strokeWidth={1.25}
    strokeLinecap="round"
    strokeLinejoin="round"
    aria-hidden="true"
    focusable="false"
  >
    <path d="M6.3 4.6 9.6 8l-3.3 3.4" />
  </svg>
);
