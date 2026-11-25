/**
 * The one spinner for the sign-in screens and the handler's loading state: a
 * fine arc on a faint track. Plain SVG, so server and client both render it.
 */
export function SignInSpinner({ className = "h-3.5 w-3.5" }: { className?: string }) {
  return (
    <svg aria-hidden="true" viewBox="0 0 16 16" className={`${className} animate-spin text-muted motion-reduce:animate-none`} fill="none" strokeWidth="1.5">
      <circle cx="8" cy="8" r="6" stroke="currentColor" strokeOpacity="0.2" />
      <path d="M14 8a6 6 0 0 0-6-6" stroke="currentColor" strokeLinecap="round" />
    </svg>
  );
}
