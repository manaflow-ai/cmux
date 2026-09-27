import {
  ctaButtonBase,
  ctaButtonDefaultSize,
  ctaButtonStyle,
} from "@/app/[locale]/components/cta-styles";
import {
  PlatformDownloadLink,
  type BrowserDownloadPlatform,
} from "@/app/[locale]/components/platform-download-link";

interface BrowserDownloadCardActionProps {
  readonly platform: BrowserDownloadPlatform;
  readonly artifact: string;
  readonly href: string;
  readonly available: boolean;
  readonly children: React.ReactNode;
}

/** Keeps download telemetry and disabled-card semantics consistent. */
export function BrowserDownloadCardAction({
  platform,
  artifact,
  href,
  available,
  children,
}: BrowserDownloadCardActionProps) {
  const className = `${ctaButtonBase} ${ctaButtonDefaultSize} w-full justify-center`;

  if (available) {
    return (
      <PlatformDownloadLink
        href={href}
        platform={platform}
        artifact={artifact}
        location="browser-landing"
        className={className}
        style={ctaButtonStyle}
      >
        <DownloadLabel>{children}</DownloadLabel>
      </PlatformDownloadLink>
    );
  }

  return (
    <span
      aria-disabled="true"
      className={`${className} cursor-not-allowed opacity-45`}
      style={ctaButtonStyle}
    >
      <DownloadLabel>{children}</DownloadLabel>
    </span>
  );
}

/** Lets long localized labels wrap inside the fixed-width landing-page cards. */
function DownloadLabel({ children }: { children: React.ReactNode }) {
  return (
    <span className="min-w-0 text-balance whitespace-normal text-center">
      {children}
    </span>
  );
}
