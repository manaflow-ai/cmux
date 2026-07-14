type Redirect = (href: unknown) => unknown;

const router = {
  back: () => undefined,
  forward: () => undefined,
  refresh: () => undefined,
  push: () => undefined,
  replace: () => undefined,
  prefetch: async () => undefined,
};

export function createNextNavigationMock(redirect: Redirect) {
  return {
    redirect,
    permanentRedirect: redirect,
    notFound: () => {
      throw new Error("notFound");
    },
    usePathname: () => "/",
    useRouter: () => router,
    useSearchParams: () => new URLSearchParams(),
    useServerInsertedHTML: () => undefined,
  };
}
