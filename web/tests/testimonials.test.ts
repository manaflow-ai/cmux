import { describe, expect, test } from "bun:test";
import {
  getTestimonialSubtitle,
  getTestimonialTranslation,
  type Testimonial,
} from "../app/[locale]/testimonials";

describe("testimonial translations", () => {
  const simplifiedChineseTestimonial = {
    key: "minixalpha",
    name: "minixalpha",
    handle: "@minixalpha",
    avatar: "/avatars/minixalpha.jpg",
    text: "我也主力用 cmux",
    lang: "zh-CN",
    url: "https://x.com/minixalpha/status/2037496984890986576",
    platform: "x" as const,
  } satisfies Testimonial;

  test("does not translate Simplified Chinese testimonials for zh-CN readers", () => {
    const translation = getTestimonialTranslation(
      simplifiedChineseTestimonial,
      "zh-CN",
      () => "繁體中文翻譯"
    );

    expect(translation).toBeNull();
  });

  test("shows Traditional Chinese translations for Simplified Chinese testimonials", () => {
    const translation = getTestimonialTranslation(
      simplifiedChineseTestimonial,
      "zh-TW",
      (key) => {
        expect(key).toBe("minixalpha");
        return "繁體中文翻譯";
      }
    );

    expect(translation).toBe("繁體中文翻譯");
  });

  test("resolves localized testimonial subtitles by key", () => {
    const testimonialWithSubtitleKey = {
      ...simplifiedChineseTestimonial,
      subtitleKey: "steipete",
    } satisfies Testimonial;

    const subtitle = getTestimonialSubtitle(
      testimonialWithSubtitleKey,
      (key) => {
        expect(key).toBe("steipete");
        return "Localized subtitle";
      }
    );

    expect(subtitle).toBe("Localized subtitle");
  });
});
