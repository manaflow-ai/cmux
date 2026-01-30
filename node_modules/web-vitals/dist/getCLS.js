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
import { observe } from './lib/observe.js';
import { onHidden } from './lib/onHidden.js';
import { bindReporter } from './lib/bindReporter.js';
export const getCLS = (onReport, reportAllChanges = false) => {
    const metric = initMetric('CLS', 0);
    let report;
    const entryHandler = (entry) => {
        // Only count layout shifts without recent user input.
        if (!entry.hadRecentInput) {
            metric.value += entry.value;
            metric.entries.push(entry);
            report();
        }
    };
    const po = observe('layout-shift', entryHandler);
    if (po) {
        report = bindReporter(onReport, metric, po, reportAllChanges);
        onHidden(({ isUnloading }) => {
            po.takeRecords().map(entryHandler);
            if (isUnloading) {
                metric.isFinal = true;
            }
            report();
        });
    }
};
