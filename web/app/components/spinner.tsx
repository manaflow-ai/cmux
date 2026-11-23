/**
 * The one spinner of cmux.com: the open arc the cmux app draws (webviews
 * conversation/icons.tsx `Spinner`), no track behind it, one calm turn every
 * 2 s (the app's spinner period, schemas/motion-scale `spinner`). Plain SVG,
 * so server and client both render it. Color is the text color around it.
 */
export function Spinner({ className = "h-3.5 w-3.5" }: { className?: string }) {
  return (
    <svg
      aria-hidden="true"
      viewBox="0 0 16 16"
      className={`${className} animate-spin [animation-duration:2000ms] motion-reduce:animate-none`}
      fill="none"
    >
      <path d="M8 2.75a5.25 5.25 0 1 1-4.55 2.63" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
    </svg>
  );
}
