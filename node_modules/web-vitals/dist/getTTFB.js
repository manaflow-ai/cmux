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
import { initMetric } from './lib/initMetric.js';
const afterLoad = (callback) => {
    if (document.readyState === 'complete') {
        // Queue a task so the callback runs after `loadEventEnd`.
        setTimeout(callback, 0);
    }
    else {
        // Use `pageshow` so the callback runs after `loadEventEnd`.
        addEventListener('pageshow', callback);
    }
};
const getNavigationEntryFromPerformanceTiming = () => {
    // Really annoying that TypeScript errors when using `PerformanceTiming`.
    const timing = performance.timing;
    const navigationEntry = {
        entryType: 'navigation',
        startTime: 0,
    };
    for (const key in timing) {
        if (key !== 'navigationStart' && key !== 'toJSON') {
            navigationEntry[key] = Math.max(timing[key] - timing.navigationStart, 0);
        }
    }
    return navigationEntry;
};
export const getTTFB = (onReport) => {
    const metric = initMetric('TTFB');
    afterLoad(() => {
        try {
            // Use the NavigationTiming L2 entry if available.
            const navigationEntry = performance.getEntriesByType('navigation')[0] ||
                getNavigationEntryFromPerformanceTiming();
            metric.value = metric.delta =
                navigationEntry.responseStart;
            metric.entries = [navigationEntry];
            metric.isFinal = true;
            onReport(metric);
        }
        catch (error) {
            // Do nothing.
        }
    });
};
