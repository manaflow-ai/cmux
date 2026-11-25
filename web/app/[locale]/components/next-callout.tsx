import { useTranslations } from "next-intl";
import { Link } from "../../../i18n/navigation";

/** One quiet line under the home page's Download button that leads to cmux NEXT. */
export function NextCallout({ className }: { className?: string }) {
  const t = useTranslations("home");
  return (
    <p className={`text-[13px] text-muted ${className ?? ""}`}>
      {t.rich("nextCallout", {
        link: (chunks) => (
          <Link
            href="/next"
            className="text-foreground underline underline-offset-2 decoration-link-underline transition-colors hover:decoration-foreground"
          >
            {chunks}
          </Link>
        ),
      })}
    </p>
  );
}
