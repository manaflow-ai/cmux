import { useTranslations, useLocale } from "next-intl";
import { getTranslations } from "next-intl/server";
import { SiteHeader } from "../components/site-header";
import { testimonials, TestimonialCard, getTestimonialTranslation } from "../testimonials";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "wallOfLove" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: { canonical: "./" },
  };
}

export default function WallOfLovePage() {
  const t = useTranslations("wallOfLove");
  const tt = useTranslations("testimonials");
  const locale = useLocale();

  return (
    <div className="min-h-screen">
      <SiteHeader section="wall of love" />
      <main className="w-full max-w-6xl mx-auto px-6 py-10">
        <h1 className="text-2xl font-semibold tracking-tight mb-2">
          {t("title")}
        </h1>
        <p className="text-muted text-[15px] mb-8">
          {t("description")}
        </p>

        <div className="columns-1 sm:columns-2 lg:columns-3 gap-4">
          {testimonials.map((testimonial) => (
            <TestimonialCard
              key={testimonial.url}
              testimonial={testimonial}
              translation={getTestimonialTranslation(testimonial, locale, tt)}
            />
          ))}
        </div>
      </main>
    </div>
  );
}
