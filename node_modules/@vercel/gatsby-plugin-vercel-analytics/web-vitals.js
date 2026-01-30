import { getCLS, getFCP, getFID, getLCP, getTTFB } from "web-vitals";

let isRegistered = false;

function onError(err) {
  console.error("[gatsby-plugin-vercel]", err); // eslint-disable-line no-console
}

function onDebug(label, payload) {
  console.log(label, payload); // eslint-disable-line no-console
}

function sendToAnalytics(metric, options) {
  // Scrape the intial component name from the DOM:
  const pageScript = [].slice
    .call(
      /^\/component---(.+)\-(.+?)\-.{20}\.js$/.exec(
        document
          .querySelector(`script[src^="/component---"]`)
          ?.getAttribute("src")
      ) ?? []
    )
    .slice(1)
    .join("-");

  const chunkMapping = self.___chunkMapping
    ? typeof self.___chunkMapping === "string"
      ? JSON.parse(self.___chunkMapping)
      : self.___chunkMapping
    : {};

  // Verify page name is correct:
  const pageName =
    "component---" + pageScript in chunkMapping ? pageScript : null;

  if (options.debug && !pageName) {
    onDebug(
      `[gatsby-plugin-vercel]`,
      "Unable to detect Page Name, skipping reporting."
    );
  }

  const body = {
    dsn: options.analyticsId,
    id: metric.id,
    page: pageName ?? "",
    href: location.href,
    event_name: metric.name,
    value: metric.value.toString(),
    speed:
      "connection" in navigator &&
      navigator["connection"] &&
      "effectiveType" in navigator["connection"]
        ? navigator["connection"]["effectiveType"]
        : "",
  };

  if (options.debug) {
    onDebug(metric.name, JSON.stringify(body, null, 2));
  }

  const blob = new Blob([new URLSearchParams(body).toString()], {
    // This content type is necessary for `sendBeacon`:
    type: "application/x-www-form-urlencoded",
  });
  const vitalsUrl = "https://vitals.vercel-analytics.com/v1/vitals";
  (navigator.sendBeacon && navigator.sendBeacon(vitalsUrl, blob)) ||
    fetch(vitalsUrl, {
      body: blob,
      method: "POST",
      credentials: "omit",
      keepalive: true,
    });
}

export async function webVitals({ options }) {
  // Only register listeners once
  if (isRegistered) {
    return;
  }
  isRegistered = true;

  try {
    getFID((metric) => sendToAnalytics(metric, options));
    getTTFB((metric) => sendToAnalytics(metric, options));
    getLCP((metric) => sendToAnalytics(metric, options));
    getCLS((metric) => sendToAnalytics(metric, options));
    getFCP((metric) => sendToAnalytics(metric, options));
  } catch (err) {
    onError(err);
  }
}
