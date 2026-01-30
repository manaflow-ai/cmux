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
import {observe, PerformanceEntryHandler} from './lib/observe.js';
import {onHidden} from './lib/onHidden.js';
import {bindReporter} from './lib/bindReporter.js';
import {ReportHandler} from './types.js';


// https://wicg.github.io/layout-instability/#sec-layout-shift
interface LayoutShift extends PerformanceEntry {
  value: number;
  hadRecentInput: boolean;
}

export const getCLS = (onReport: ReportHandler, reportAllChanges = false) => {
  const metric = initMetric('CLS', 0);

  let report: ReturnType<typeof bindReporter>;

  const entryHandler = (entry: LayoutShift) => {
    // Only count layout shifts without recent user input.
    if (!entry.hadRecentInput) {
      (metric.value as number) += entry.value;
      metric.entries.push(entry);
      report();
    }
  };

  const po = observe('layout-shift', entryHandler as PerformanceEntryHandler);
  if (po) {
    report = bindReporter(onReport, metric, po, reportAllChanges);

    onHidden(({isUnloading}) => {
      po.takeRecords().map(entryHandler as PerformanceEntryHandler);

      if (isUnloading) {
        metric.isFinal = true;
      }
      report();
    });
  }
};
