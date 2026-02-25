import type { Metadata } from "next";
import { SiteHeader } from "../components/site-header";
import { testimonials, TestimonialCard } from "../testimonials";

export const metadata: Metadata = {
  title: "Wall of Love — cmux",
  description:
    "What people are saying about cmux, the terminal built for multitasking.",
};

export default function WallOfLovePage() {
  return (
    <div className="min-h-screen">
      <SiteHeader section="wall of love" />
      <main className="w-full max-w-6xl mx-auto px-6 py-10">
        <h1 className="text-2xl font-semibold tracking-tight mb-2">
          Wall of Love
        </h1>
        <p className="text-muted text-[15px] mb-8">
          What people are saying about cmux.
        </p>

        <div className="columns-1 sm:columns-2 lg:columns-3 gap-4">
          {testimonials.map((t) => (
            <TestimonialCard key={t.url} testimonial={t} />
          ))}
        </div>
      </main>
    </div>
  );
}
