import { webVitals } from "./web-vitals";

export const onClientEntry = (_, pluginOptions = {}) => {
  let options = {
    debug: false,
    ...pluginOptions,
    analyticsId: process.env.GATSBY_VERCEL_ANALYTICS_ID,
  };

  if (!options.analyticsId) {
    return null;
  }

  if (options.debug || process.env.NODE_ENV === "production") {
    webVitals({ options });
  }
};
