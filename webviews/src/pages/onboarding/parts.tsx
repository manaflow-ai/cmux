// Shared pieces of the onboarding steps: the page context (strings and store) and a host image.
import { createContext, useContext, type CSSProperties } from "react";
import type { Strings } from "../shared/i18n";
import type { HostImage } from "./ops";
import type { OnboardingStore } from "./store";

export interface OnboardingContextValue {
  strings: Strings;
  store: OnboardingStore;
}

export const OnboardingContext = createContext<OnboardingContextValue | null>(null);

export function useOnboarding(): OnboardingContextValue {
  const value = useContext(OnboardingContext);
  if (!value) throw new Error("OnboardingContext is missing");
  return value;
}

/** An image the host drew. A template mark takes the text color (a mask over `currentColor`); any
 * other image draws as is. No image keeps the slot, empty, so nothing moves when it arrives. */
export function HostIcon({
  image,
  className,
  label,
}: {
  image: HostImage | null | undefined;
  className: string;
  label?: string;
}) {
  if (image == null) return <span className={className} data-empty="" aria-hidden="true" />;
  if (image.template) {
    const style = {
      WebkitMaskImage: `url("${image.src}")`,
      maskImage: `url("${image.src}")`,
    } as CSSProperties;
    return (
      <span
        className={className}
        data-template=""
        style={style}
        role={label ? "img" : undefined}
        aria-label={label}
        aria-hidden={label ? undefined : "true"}
      />
    );
  }
  return <img className={className} src={image.src} alt={label ?? ""} draggable={false} />;
}
