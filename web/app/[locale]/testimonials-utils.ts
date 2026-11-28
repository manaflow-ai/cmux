import type { Testimonial } from "./testimonials-data";

/**
 * Returns the language family prefix for a locale.
 * Chinese variants stay distinct so zh-TW users can see Traditional translations.
 */
function langFamily(locale: string): string {
  const normalized = locale.toLowerCase();
  if (normalized === "zh-cn" || normalized === "zh-tw") {
    return normalized;
  }
  return normalized.split("-")[0];
}

/**
 * Get the translation to display for a testimonial in the given locale.
 * Returns null if the testimonial is in the user's language.
 */
export function getTestimonialTranslation(
  testimonial: Testimonial,
  locale: string,
  t: (key: string) => string
): string | null {
  if (langFamily(locale) === langFamily(testimonial.lang)) {
    return null;
  }
  try {
    return t(testimonial.key);
  } catch {
    return null;
  }
}

export function getTestimonialSubtitle(
  testimonial: Testimonial,
  t: (key: string) => string
): string | null {
  if ("subtitleKey" in testimonial && testimonial.subtitleKey) {
    try {
      return t(testimonial.subtitleKey);
    } catch {
      return null;
    }
  }

  if ("subtitle" in testimonial && testimonial.subtitle) {
    return testimonial.subtitle;
  }

  return null;
}
