/*
 * Copyright 2020 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import {initMetric} from './lib/initMetric.js';
import {ReportHandler} from './types.js';


interface NavigationEntryShim {
  // From `PerformanceNavigationTimingEntry`.
  entryType: string;
  startTime: number;

  // From `performance.timing`.
  connectEnd?: number;
  connectStart?: number;
  domComplete?: number;
  domContentLoadedEventEnd?: number;
  domContentLoadedEventStart?: number;
  domInteractive?: number;
  domainLookupEnd?: number;
  domainLookupStart?: number;
  fetchStart?: number;
  loadEventEnd?: number;
  loadEventStart?: number;
  redirectEnd?: number;
  redirectStart?: number;
  requestStart?: number;
  responseEnd?: number;
  responseStart?: number;
  secureConnectionStart?: number;
  unloadEventEnd?: number;
  unloadEventStart?: number;
}

type PerformanceTimingKeys =
    'connectEnd' |
    'connectStart' |
    'domComplete' |
    'domContentLoadedEventEnd' |
    'domContentLoadedEventStart' |
    'domInteractive' |
    'domainLookupEnd' |
    'domainLookupStart' |
    'fetchStart' |
    'loadEventEnd' |
    'loadEventStart' |
    'redirectEnd' |
    'redirectStart' |
    'requestStart' |
    'responseEnd' |
    'responseStart' |
    'secureConnectionStart' |
    'unloadEventEnd' |
    'unloadEventStart';

const afterLoad = (callback: () => void) => {
  if (document.readyState === 'complete') {
    // Queue a task so the callback runs after `loadEventEnd`.
    setTimeout(callback, 0);
  } else {
    // Use `pageshow` so the callback runs after `loadEventEnd`.
    addEventListener('pageshow', callback);
  }
}

const getNavigationEntryFromPerformanceTiming = () => {
  // Really annoying that TypeScript errors when using `PerformanceTiming`.
  const timing = performance.timing;

  const navigationEntry: NavigationEntryShim = {
    entryType: 'navigation',
    startTime: 0,
  };

  for (const key in timing) {
    if (key !== 'navigationStart' && key !== 'toJSON') {
      navigationEntry[key as PerformanceTimingKeys] = Math.max(
          timing[key as PerformanceTimingKeys] - timing.navigationStart, 0);
    }
  }
  return navigationEntry as PerformanceNavigationTiming;
};

export const getTTFB = (onReport: ReportHandler) => {
  const metric = initMetric('TTFB');

  afterLoad(() => {
    try {
      // Use the NavigationTiming L2 entry if available.
      const navigationEntry = performance.getEntriesByType('navigation')[0] ||
          getNavigationEntryFromPerformanceTiming();

      metric.value = metric.delta =
          (navigationEntry as PerformanceNavigationTiming).responseStart;

      metric.entries = [navigationEntry];
      metric.isFinal = true;

      onReport(metric);
    } catch (error) {
      // Do nothing.
    }
  });
};
