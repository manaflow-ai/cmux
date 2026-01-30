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
import {whenInput} from './lib/whenInput.js';
import {ReportHandler} from './types.js';


export const getLCP = (onReport: ReportHandler, reportAllChanges = false) => {
  const metric = initMetric('LCP');
  const firstHidden = getFirstHidden();

  let report: ReturnType<typeof bindReporter>;

  const entryHandler = (entry: PerformanceEntry) => {
    // The startTime attribute returns the value of the renderTime if it is not 0,
    // and the value of the loadTime otherwise.
    const value = entry.startTime;

    // If the page was hidden prior to paint time of the entry,
    // ignore it and mark the metric as final, otherwise add the entry.
    if (value < firstHidden.timeStamp) {
      metric.value = value;
      metric.entries.push(entry);
    } else {
      metric.isFinal = true;
    }

    report();
  };

  const po = observe('largest-contentful-paint', entryHandler);

  if (po) {
    report = bindReporter(onReport, metric, po, reportAllChanges);

    const onFinal = () => {
      if (!metric.isFinal) {
        po.takeRecords().map(entryHandler as PerformanceEntryHandler);
        metric.isFinal = true;
        report();
      }
    }

    whenInput().then(onFinal);
    onHidden(onFinal, true);
  }
};
