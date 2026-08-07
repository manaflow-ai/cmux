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
        {children}
      </PlatformDownloadLink>
    );
  }

  return (
    <span
      aria-disabled="true"
      className={`${className} cursor-not-allowed opacity-45`}
      style={ctaButtonStyle}
    >
      {children}
    </span>
  );
}
