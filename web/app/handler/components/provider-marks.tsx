import { AppleMark } from "../../[locale]/components/apple-mark";
import type { HexclaveOAuthProvider } from "../../../services/auth/hexclave/auth";

/**
 * Provider glyphs are inlined rather than fetched. The sign-in page must paint
 * with zero subresource requests, and a blocked third-party image would leave
 * three unlabelled buttons.
 */
export function ProviderMark({
  provider,
}: {
  provider: HexclaveOAuthProvider;
}) {
  if (provider === "apple") return <AppleMark size={16} />;
  if (provider === "github") {
    return (
      <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" aria-hidden>
        <path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z" />
      </svg>
    );
  }
  return (
    <svg width="16" height="16" viewBox="0 0 48 48" aria-hidden>
      <path fill="#4285F4" d="M45.1 24.5c0-1.6-.1-2.8-.5-4.1H24v7.5h11.9c-.2 2-1.5 5-4.4 7l-.1.3 6.4 5 .4.1c4.1-3.8 6.9-9.4 6.9-15.8z" />
      <path fill="#34A853" d="M24 46c5.8 0 10.7-1.9 14.2-5.2l-6.8-5.3c-1.8 1.3-4.3 2.2-7.4 2.2-5.7 0-10.5-3.8-12.2-9l-.3.1-6.6 5.1-.1.3C8.3 41.1 15.6 46 24 46z" />
      <path fill="#FBBC05" d="M11.8 28.7c-.5-1.3-.7-2.7-.7-4.2s.3-2.9.7-4.2v-.4l-6.7-5.2-.2.1C3.4 17.7 2.7 20.8 2.7 24.5s.7 6.8 2.2 9.7l6.9-5.5z" />
      <path fill="#EA4335" d="M24 11.1c4 0 6.7 1.7 8.3 3.2l6-5.9C34.6 4.9 29.8 2.9 24 2.9 15.6 2.9 8.3 7.8 4.9 14.8l6.9 5.5c1.7-5.2 6.5-9.2 12.2-9.2z" />
    </svg>
  );
}
