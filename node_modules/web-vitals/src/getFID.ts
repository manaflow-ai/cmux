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

import {bindReporter} from './lib/bindReporter.js';
import {getFirstHidden} from './lib/getFirstHidden.js';
import {initMetric} from './lib/initMetric.js';
import {observe, PerformanceEntryHandler} from './lib/observe.js';
import {onHidden} from './lib/onHidden.js';
import {ReportHandler} from './types.js';


interface FIDPolyfillCallback {
  (value: number, event: Event): void;
}

interface FIDPolyfill {
  onFirstInputDelay: (onReport: FIDPolyfillCallback) => void;
}

declare global {
  interface Window {
    perfMetrics: FIDPolyfill;
  }
}

// https://wicg.github.io/event-timing/#sec-performance-event-timing
interface PerformanceEventTiming extends PerformanceEntry {
  processingStart: DOMHighResTimeStamp;
  cancelable?: boolean;
  target?: Element;
}

export const getFID = (onReport: ReportHandler) => {
  const metric = initMetric('FID');
  const firstHidden = getFirstHidden();

  const entryHandler = (entry: PerformanceEventTiming) => {
    // Only report if the page wasn't hidden prior to the first input.
    if (entry.startTime < firstHidden.timeStamp) {
      metric.value = entry.processingStart - entry.startTime;
      metric.entries.push(entry);
      metric.isFinal = true;
      report();
    }
  };

  const po = observe('first-input', entryHandler as PerformanceEntryHandler);
  const report = bindReporter(onReport, metric, po);

  if (po) {
    onHidden(() => {
      po.takeRecords().map(entryHandler as PerformanceEntryHandler);
      po.disconnect();
    }, true);
  } else {
    if (window.perfMetrics && window.perfMetrics.onFirstInputDelay) {
      window.perfMetrics.onFirstInputDelay((value: number, event: Event) => {
        // Only report if the page wasn't hidden prior to the first input.
        if (event.timeStamp < firstHidden.timeStamp) {
          metric.value = value;
          metric.isFinal = true;
          metric.entries = [{
            entryType: 'first-input',
            name: event.type,
            target: event.target,
            cancelable: event.cancelable,
            startTime: event.timeStamp,
            processingStart: event.timeStamp + value,
          } as PerformanceEventTiming];
          report();
        }
      });
    }
  }
};
