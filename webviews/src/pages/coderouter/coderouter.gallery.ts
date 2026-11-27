// l10n-allow-file: gallery fixtures (public-safe provider data), not shipped UI.
import { codeRouterPageEntry } from "../../gallery/format";
import { sampleProviders } from "./mockProvider";

const providers = sampleProviders(true).map((row) =>
  row.provider === "claude" ? { ...row, label: "team account" } : row,
);
const manyProviders = Array.from({ length: 16 }, (_, index) => ({
  ...providers[index % providers.length]!,
  provider: `provider-${index + 1}`,
  name: `Provider ${index + 1} with a long display name`,
  status: index % 3 === 0 ? "signed_in" : index % 3 === 1 ? "expired" : "missing",
  account: index % 3 === 2 ? null : `acct_sample_${index + 1}`,
  label: index % 3 === 2 ? null : "sample account",
  linked:
    index % 3 === 0
      ? [
          {
            id: `linked-${index + 1}`,
            account: `acct_sample_${index + 1}`,
            label: "sample account",
            state: "active",
            visibility: "private",
          },
        ]
      : [],
}));

export default codeRouterPageEntry({
  id: "pages.coderouter",
  title: "CodeRouter",
  area: "Pages",
  height: 640,
  widths: { narrow: 560, normal: 900, wide: 1200 },
  covers: ["page:cmux.coderouter", "pages/coderouter/CodeRouterPage.tsx"],
  variants: {
    connected: {
      note: "Connected providers with one linked account and one expired account.",
      signedIn: true,
      providers,
    },
    "signed-out": {
      note: "Signed out: local detection remains visible and linked accounts are empty.",
      signedIn: false,
      providers: providers.map((row) => ({ ...row, linked: [], can_connect: false })),
    },
    "many-providers": {
      note: "Sixteen provider rows with long names for scrolling.",
      signedIn: true,
      providers: manyProviders,
    },
    error: {
      note: "The account service returns a network error.",
      mode: "error",
      error: { code: "cmux.protocol.transport", message: "The account service is offline." },
      providers,
    },
    loading: {
      note: "The account and provider projection is still loading.",
      mode: "loading",
      providers,
    },
  },
});
