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
let isUnloading = false;
let listenersAdded = false;
const onPageHide = (event) => {
    isUnloading = !event.persisted;
};
const addListeners = () => {
    addEventListener('pagehide', onPageHide);
    // `beforeunload` is needed to fix this bug:
    // https://bugs.chromium.org/p/chromium/issues/detail?id=987409
    // eslint-disable-next-line @typescript-eslint/no-empty-function
    addEventListener('beforeunload', () => { });
};
export const onHidden = (cb, once = false) => {
    if (!listenersAdded) {
        addListeners();
        listenersAdded = true;
    }
    addEventListener('visibilitychange', ({ timeStamp }) => {
        if (document.visibilityState === 'hidden') {
            cb({ timeStamp, isUnloading });
        }
    }, { capture: true, once });
};
