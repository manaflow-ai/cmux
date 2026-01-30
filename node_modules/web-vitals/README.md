# `web-vitals`

- [Overview](#overview)
- [Installation](#installation)
- [Usage](#usage)
  - [Log the results to the console](#log-the-results-to-the-console)
  - [Report the value on every change](#report-the-value-on-every-change)
  - [Report only the delta of changes](#report-only-the-delta-of-changes)
  - [Send the results to an analytics endpoint](#send-the-results-to-an-analytics-endpoint)
  - [Send the results to Google Analytics](#send-the-results-to-google-analytics)
  - [Send the results to Google Tag Manager](#send-the-results-to-google-tag-manager)
  - [Load `web-vitals` from a CDN](#load-web-vitals-from-a-cdn)
- [API](#api)
  - [Types](#types)
  - [Functions](#functions)
- [Development](#development)
- [Browser Support](#browser-support)

## Overview

The `web-vitals` library is a tiny (~1K), modular library for measuring all the [Web Vitals](https://web.dev/vitals/) metrics on real users, in a way that accurately matches how they're measured by Chrome and reported to other Google tools (e.g. [Chrome User Experience Report](https://developers.google.com/web/tools/chrome-user-experience-report), [Page Speed Insights](https://developers.google.com/speed/pagespeed/insights/), [Search Console's Speed Report](https://webmasters.googleblog.com/2019/11/search-console-speed-report.html)).

The library supports all of the [Core Web Vitals](https://web.dev/vitals/#core-web-vitals) as well as all of the [other Web Vitals](https://web.dev/vitals/#other-web-vitals) that can be measured [in the field](https://web.dev/user-centric-performance-metrics/#how-metrics-are-measured):

### Core Web Vitals

- [Cumulative Layout Shift (CLS)](https://web.dev/cls/)
- [First Input Delay (FID)](https://web.dev/fid/)
- [Largest Contentful Paint (LCP)](https://web.dev/lcp/)

### Other Web Vitals

- [First Contentful Paint (FCP)](https://web.dev/fcp/)
- [Time to First Byte (TTFB)](https://web.dev/time-to-first-byte/)

## Installation

You can install this library from npm by running:

```sh
npm install web-vitals
```

_**Note:** If you're not using npm, you can still load `web-vitals` via `<script>` tags from a CDN like [unpkg.com](https://unpkg.com). See the [load `web-vitals` from a CDN](#load-web-vitals-from-a-cdn) usage example below for details._

## Usage

Each of the Web Vitals metrics are exposed as a single function that takes an `onReport` callback. This callback will fire any time either:

- The final value of the metric has been determined.
- The current metric value needs to be [reported right away](https://developers.google.com/web/updates/2018/07/page-lifecycle-api#advice-hidden) (due to the page being unloaded or backgrounded).

### Log the results to the console

The following example logs the result of each metric to the console once its value is ready to report.

```js
import {getCLS, getFID, getLCP} from 'web-vitals';

getCLS(console.log);
getFID(console.log);
getLCP(console.log);
```

_**Note:** some of these metrics will not report until the user has interacted with the page, switched tabs, or the page starts to unload. If you don't see the values logged to the console immediately, try switching tabs and then switching back._

### Report the value on every change

In most cases, you only want to call `onReport` when the metric is ready. However, for metrics like LCP and CLS (where the value may change over time) you can pass an optional, second argument (`reportAllChanges`). If `true` then `onReport` will be called any time the value of the metric changes, or once the final value has been determined.

This could be useful if, for example, you want to report the current LCP candidate as the page is loading, or you want to report layout shifts (and the current CLS value) as users are interacting with the page. In general, though, using `reportAllChanges` is not needed (or recommended).

```js
import {getCLS, getFID, getLCP} from 'web-vitals';

getCLS(console.log, true);
getFID(console.log); // Does not take a `reportAllChanges` param.
getLCP(console.log, true);
```

_**Note:** when using the `reportAllChanges` option, pay attention to the `isFinal` property of the reported metric, which will indicate whether or not the value might change in the future. See the [API](#api) reference below for more details._

### Report only the delta of changes

Some analytics providers allow you to update the value of a metric, even after you've already sent it to their servers (overwriting the previously-sent value with the same `id`).

Other analytics providers, however, do not allow this, so instead of reporting the new value, you need to report only the delta (the difference between the current value and the last-reported value). You can then compute the total value by summing all metric deltas sent with the same ID.

The following example shows how to use the `id` and `delta` properties:

```js
import {getCLS, getFID, getLCP} from 'web-vitals';

function logDelta({name, id, delta}) {
  console.log(`${name} matching ID ${id} changed by ${delta}`);
}

getCLS(logDelta);
getFID(logDelta);
getLCP(logDelta);
```

_**Note:** the first time the `onReport` function is called, its `value` and `delta` properties will be the same._

### Send the results to an analytics endpoint

The following example measures each of the Core Web Vitals metrics and reports them to a hypothetical `/analytics` endpoint, as soon as each is ready to be sent.

The `sendToAnalytics()` function uses the [`navigator.sendBeacon()`](https://developer.mozilla.org/en-US/docs/Web/API/Navigator/sendBeacon) method (if available), but falls back to the [`fetch()`](https://developer.mozilla.org/en-US/docs/Web/API/Fetch_API) API when not.

```js
import {getCLS, getFID, getLCP} from 'web-vitals';

function sendToAnalytics(metric) {
  const body = JSON.stringify(metric);
  // Use `navigator.sendBeacon()` if available, falling back to `fetch()`.
  (navigator.sendBeacon && navigator.sendBeacon('/analytics', body)) ||
      fetch('/analytics', {body, method: 'POST', keepalive: true});
}

getCLS(sendToAnalytics);
getFID(sendToAnalytics);
getLCP(sendToAnalytics);
```

### Send the results to Google Analytics

Google Analytics does not support reporting metric distributions in any of its built-in reports; however, if you set a unique dimension value (in this case, the metric `id`) on every metric instance that you send to Google Analytics, including that dimension in a custom report will allow you to construct a distribution manually.

Using the [Google Analytics Reporting API](https://developers.google.com/analytics/devguides/reporting) and a tool like [Data Studio](https://datastudio.google.com/) (or your own visualization library), you can create dashboards with histograms reporting quantile data (the 75th percentile is recommended) for all of the Web Vitals metrics.

The following code examples show how to send your metrics to Google Analytics in order to enable reporting quantile data:

#### Using `analytics.js`

```js
import {getCLS, getFID, getLCP} from 'web-vitals';

function sendToGoogleAnalytics({name, delta, id}) {
  // Assumes the global `ga()` function exists, see:
  // https://developers.google.com/analytics/devguides/collection/analyticsjs
  ga('send', 'event', {
    eventCategory: 'Web Vitals',
    eventAction: name,
    // Google Analytics metrics must be integers, so the value is rounded.
    // For CLS the value is first multiplied by 1000 for greater precision
    // (note: increase the multiplier for greater precision if needed).
    eventValue: Math.round(name === 'CLS' ? delta * 1000 : delta),
    // The `id` value will be unique to the current page load. When sending
    // multiple values from the same page (e.g. for CLS), Google Analytics can
    // compute a total by grouping on this ID (note: requires `eventLabel` to
    // be a dimension in your report).
    eventLabel: id,
    // Use a non-interaction event to avoid affecting bounce rate.
    nonInteraction: true,
  });
}

getCLS(sendToGoogleAnalytics);
getFID(sendToGoogleAnalytics);
getLCP(sendToGoogleAnalytics);
```

#### Using `gtag.js`

```js
import {getCLS, getFID, getLCP} from 'web-vitals';

function sendToGoogleAnalytics({name, delta, id}) {
  // Assumes the global `gtag()` function exists, see:
  // https://developers.google.com/analytics/devguides/collection/gtagjs
  gtag('event', name, {
    event_category: 'Web Vitals',
    // Google Analytics metrics must be integers, so the value is rounded.
    // For CLS the value is first multiplied by 1000 for greater precision
    // (note: increase the multiplier for greater precision if needed).
    value: Math.round(name === 'CLS' ? delta * 1000 : delta),
    // The `id` value will be unique to the current page load. When sending
    // multiple values from the same page (e.g. for CLS), Google Analytics can
    // compute a total by grouping on this ID (note: requires `eventLabel` to
    // be a dimension in your report).
    event_label: id,
    // Use a non-interaction event to avoid affecting bounce rate.
    non_interaction: true,
  });
}

getCLS(sendToGoogleAnalytics);
getFID(sendToGoogleAnalytics);
getLCP(sendToGoogleAnalytics);
```

### Send the results to Google Tag Manager

The following example measures each of the Core Web Vitals metrics and sends them as separate `dataLayer-events` to be used by Google Tag Manager. With the `web-vitals` trigger you send the metrics to any tag inside your account (see [this comment](https://github.com/GoogleChrome/web-vitals/pull/28#discussion_r422701126) for implementation details).

```js
import {getCLS, getFID, getLCP} from 'web-vitals';

function sendToGTM({name, delta, id}) {
  // Assumes the global `dataLayer` array exists, see:
  // https://developers.google.com/tag-manager/devguide
  dataLayer.push({
    event: 'web-vitals',
    event_category: 'Web Vitals',
    event_action: name,
    // Google Analytics metrics must be integers, so the value is rounded.
    // For CLS the value is first multiplied by 1000 for greater precision
    // (note: increase the multiplier for greater precision if needed).
    event_value: Math.round(name === 'CLS' ? delta * 1000 : delta),
    // The `id` value will be unique to the current page load. When sending
    // multiple values from the same page (e.g. for CLS), Google Analytics can
    // compute a total by grouping on this ID (note: requires `eventLabel` to
    // be a dimension in your report).
    event_label: id,
  });
}

getCLS(sendToGTM);
getFID(sendToGTM);
getLCP(sendToGTM);
```

### Load `web-vitals` from a CDN

The recommended way to use the `web-vitals` package is to install it from npm and integrate it into your build process. However, if you're not using npm, it's still possible to use `web-vitals` by requesting it from a CDN that serves npm package files.

The following examples show how to load `web-vitals` from [unpkg.com](https://unpkg.com) using either classic or module scripts:

```html
<!-- Load `web-vitals` using a classic script that sets the global `webVitals` object. -->
<script defer src="https://unpkg.com/web-vitals@0.2.4/dist/web-vitals.es5.umd.min.js"></script>
<script>
addEventListener('DOMContentLoaded', function() {
  webVitals.getCLS(console.log);
  webVitals.getFID(console.log);
  webVitals.getLCP(console.log);
});
</script>
```

```html
<!-- Load `web-vitals` using a module script. -->
<script type="module">
  import {getCLS, getFID, getLCP} from 'https://unpkg.com/web-vitals@0.2.4/dist/web-vitals.es5.min.js?module';

  getCLS(console.log);
  getFID(console.log);
  getLCP(console.log);
</script>
```

_**Note:** it's safe to use module scripts in legacy browsers because unknown script types are ignored._

## API

### Types:

#### `Metric`

```ts
interface Metric {
  // The name of the metric (in acronym form).
  name: 'CLS' | 'FCP' | 'FID' | 'LCP' | 'TTFB';

  // The current value of the metric.
  value: number;

  // The delta between the current value and the last-reported value.
  // On the first report, `delta` and `value` will always be the same.
  delta: number;

  // A unique ID representing this particular metric that's specific to the
  // current page. This ID can be used by an analytics tool to dedupe
  // multiple values sent for the same metric, or to group multiple deltas
  // together and calculate a total.
  id: string;

  // `false` if the value of the metric may change in the future,
  // for the current page.
  isFinal: boolean;

  // Any performance entries used in the metric value calculation.
  // Note, entries will be added to the array as the value changes.
  entries: PerformanceEntry[];
}
```

#### `ReportHandler`

```ts
interface ReportHandler {
  (metric: Metric): void;
}
```

### Functions:

#### `getCLS()`

```ts
type getCLS = (onReport: ReportHandler, reportAllChanges?: boolean) => void
```

Calculates the [CLS](https://web.dev/cls/) value for the current page and calls the `onReport` function once the value is ready to be reported, along with all `layout-shift` performance entries that were used in the metric value calculation. The reported value is a [double](https://heycam.github.io/webidl/#idl-double) (corresponding to a [layout shift value](https://wicg.github.io/layout-instability/#layout-shift-value)).

If the `reportAllChanges` param is `true`, the `onReport` function will be called any time a new `layout-shift` performance entry is dispatched, or once the final value of the metric has been determined.

_**Important:** unlike other metrics, CLS continues to monitor changes for the entire lifespan of the page&mdash;including if the user returns to the page after it's been hidden/backgrounded. However, since browsers often [will not fire additional callbacks once the user has backgrounded a page](https://developers.google.com/web/updates/2018/07/page-lifecycle-api#advice-hidden), `onReport` is always called when the page's visibility state changes to hidden. As a result, the `onReport` function might be called multiple times during the same page load (see [Reporting only the delta of changes](#report-only-the-delta-of-changes) for how to manage this)._

#### `getFCP()`

```ts
type getFCP = (onReport: ReportHandler) => void
```

Calculates the [FCP](https://web.dev/fcp/) value for the current page and calls the `onReport` function once the value is ready, along with the relevant `paint` performance entry used to determine the value. The reported value is a `DOMHighResTimeStamp`.

#### `getFID()`

```ts
type getFID = (onReport: ReportHandler) => void
```

Calculates the [FID](https://web.dev/fid/) value for the current page and calls the `onReport` function once the value is ready, along with the relevant `first-input` performance entry used to determine the value (and optionally the input event if using the [FID polyfill](#fid-polyfill)). The reported value is a `DOMHighResTimeStamp`.

_**Important:** since FID is only reported after the user interacts with the page, it's possible that it will not be reported for some page loads._

#### `getLCP()`

```ts
type getLCP = (onReport: ReportHandler, reportAllChanges?: boolean) => void
```

Calculates the [LCP](https://web.dev/lcp/) value for the current page and calls the `onReport` function once the value is ready (along with the relevant `largest-contentful-paint` performance entries used to determine the value). The reported value is a `DOMHighResTimeStamp`.

If the `reportAllChanges` param is `true`, the `onReport` function will be called any time a new `largest-contentful-paint` performance entry is dispatched, or once the final value of the metric has been determined.

#### `getTTFB()`

```ts
type getTTFB = (onReport: ReportHandler) => void
```

Calculates the [TTFB](https://web.dev/time-to-first-byte/) value for the current page and calls the `onReport` function once the page has loaded, along with the relevant `navigation` performance entry used to determine the value. The reported value is a `DOMHighResTimeStamp`.

Note, this function waits until after the page is loaded to call `onReport` in order to ensure all properties of the `navigation` entry are populated. This is useful if you want to report on other metrics exposed by the [Navigation Timing API](https://w3c.github.io/navigation-timing/).

For example, the TTFB metric starts from the page's [time origin](https://www.w3.org/TR/hr-time-2/#sec-time-origin), which means it [includes](https://developers.google.com/web/fundamentals/performance/navigation-and-resource-timing#the_life_and_timings_of_a_network_request) time spent on DNS lookup, connection negotiation, network latency, and unloading the previous document. If, in addition to TTFB, you want a metric that excludes these timings and _just_ captures the time spent making the request and receiving the first byte of the response, you could compute that from data found on the performance entry:

```js
import {getTTFB} from 'web-vitals';

getTTFB((metric) => {
  // Calculate the request time by subtracting from TTFB
  // everything that happened prior to the request starting.
  const requestTime = metric.value - metric.entries[0].requestStart;
  console.log('Request time:', requestTime);
});
```

_**Note:** browsers that do not support `navigation` entries will fall back to
using `performance.timing` (with the timestamps converted from epoch time to `DOMHighResTimeStamp`). This ensures code referencing these values (like in the example above) will work the same in all browsers._

## Browser Support

This code has been tested and will run without error in all major browsers as well as Internet Explorer back to version 9 (when transpiled to ES5). However, some of the APIs required to capture these metrics are only available in Chromium-based browsers (e.g. Chrome, Edge, Opera, Samsung Internet).

Browser support for each function is as follows:

- `getCLS()`: Chromium
- `getFCP()`: Chromium
- `getFID()`: Chromium, Firefox, Safari, Internet Explorer (with polyfill, [see below](#fid-polyfill))
- `getLCP()`: Chromium
- `getTTFB()`: Chromium, Firefox, Safari, Internet Explorer

### FID Polyfill

The `getFID()` function will work in all browsers if the page has included the [FID polyfill](https://github.com/GoogleChromeLabs/first-input-delay).

Browsers that support the native [Event Timing API](https://wicg.github.io/event-timing/) will use that and report the metric value from the `first-input` performance entry.

Browsers that **do not** support the native Event Timing API will use the value reported by the polyfill, and the `entries` array will contain a plain-object version of the native [`PerformanceEventTiming`](https://wicg.github.io/event-timing/#sec-performance-event-timing) object.

_**Note:** the `duration` and `processingEnd` properties of the `PerformanceEventTiming` will not be present, as they're not exposed by the polyfill._

## Development

### Building the code

The `web-vitals` source code is written in TypeScript. To transpile the code and build the production bundles, run the following command.

```sh
npm run build
```

To build the code and watch for changes, run:

```sh
npm run watch
```

### Running the tests

The `web-vitals` code is tested in real browsers using [webdriver.io](https://webdriver.io/). Use the following command to run the tests:

```sh
npm test
```

To test any of the APIs manually, you can start the test server

```sh
npm run test:server
```

Then navigate to `http://localhost:9090/test/<view>`, where `<view>` is the basename of one the templates under [/test/views/](/test/views/).

You'll likely want to combine this with `npm run watch` to ensure any changes you make are transpiled and rebuilt.

## License

[Apache 2.0](/LICENSE)
