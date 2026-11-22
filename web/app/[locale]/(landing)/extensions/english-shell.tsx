import LocaleLayout from "@/app/[locale]/layout";
import LandingLayout from "@/app/[locale]/(landing)/layout";

/**
 * The site's English page shell (locale providers, theme, footer) for listing pages served
 * outside the locale tree. The request proxy passes any path with a dot through unrewritten
 * (it reads as a file), and a listing URL has one whenever its host is spelled out
 * (`/extensions/gitlab.com/...`) or its repo name has a dot (`/extensions/OWNER/foo.js`):
 * app/extensions/[...slug] and app/setups/[...slug] serve those, with this shell.
 */
export function EnglishShell({ children }: { children: React.ReactNode }) {
  return (
    <LocaleLayout params={Promise.resolve({ locale: "en" })}>
      <LandingLayout>{children}</LandingLayout>
    </LocaleLayout>
  );
}
