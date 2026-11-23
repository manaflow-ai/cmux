// gh_budget_wait.sh's waits for an actions/github-script step's octokit.
//
//   if (process.env.GH_BUDGET_WAIT_JS) require(process.env.GH_BUDGET_WAIT_JS).install({ github, core });
//
// (gh_budget_wait.sh --install copies this file next to its gh wrapper and sets
// GH_BUDGET_WAIT_JS.) Every later request the step's `github` client sends, REST
// and paginate included, then waits through what a scheduled step must survive:
//
//   - a rate-limit refusal (403 or 429 saying so, or x-ratelimit-remaining 0):
//     waits for the budget's own reset (retry-after, else x-ratelimit-reset),
//     else backs off 60, 120, 240, then 300 s (GitHub's secondary limit sends
//     no reset), at most GH_BUDGET_WAIT_ATTEMPTS tries (default 6);
//   - a GitHub server error (5xx): waits 10, 20, then 40 s, at most
//     GH_BUDGET_WAIT_5XX_ATTEMPTS tries (default 4).
//
// All waits in a job share gh_budget_wait.sh's ledger and its total,
// GH_BUDGET_WAIT_MAX_SECONDS (default 3600). A reset further away than the job
// has left to wait fails at once. A call that fails through every try is
// reported with core.error and rethrown. A refused or 5xx request is retried
// as is: the same call, with the same token, later.
//
// install({ github, core, spare }): `spare` is a second client (getOctokit(OTHER_TOKEN)) with its own
// hourly budget. A rate-limited GET is sent once on it before any wait, and its answer is used when
// it gets one; when it too is refused (any failure), the wait runs as above. Writes never move to it.
// The nightly promote job waited 352 s, 491 s and 737 s on one dry budget (runs 45114240299 and
// 45112291910, 2026-11-23) while another token in the same job had reads left.
'use strict';

const fs = require('fs');
const path = require('path');

const RATE_LIMIT_TEXT = /rate limit exceeded|secondary rate limit|abuse detection|too many requests/i;

function intEnv(env, name, fallback) {
  const value = Number.parseInt(env[name] || '', 10);
  return Number.isFinite(value) && value >= 0 ? value : fallback;
}

function header(error, name) {
  const headers = (error && error.response && error.response.headers) || {};
  return headers[name] ?? headers[name.toLowerCase()];
}

// 'rate', 'server' or null for any other failure (never retried).
function classify(error) {
  const status = Number(error && error.status);
  const message = String((error && error.message) || '');
  if (status === 429) return 'rate';
  if (status === 403 && (RATE_LIMIT_TEXT.test(message) || String(header(error, 'x-ratelimit-remaining')) === '0' || header(error, 'retry-after') !== undefined)) {
    return 'rate';
  }
  if (status >= 500 && status <= 599) return 'server';
  return null;
}

// Seconds to wait before rate-limit try `tryNumber` + 1, and whether it is a known reset.
function rateLimitWait(error, tryNumber, nowSeconds) {
  const retryAfter = Number.parseInt(header(error, 'retry-after') || '', 10);
  if (Number.isFinite(retryAfter) && retryAfter >= 0) return { seconds: retryAfter + 1, reset: true };
  const reset = Number.parseInt(header(error, 'x-ratelimit-reset') || '', 10);
  if (String(header(error, 'x-ratelimit-remaining')) === '0' && Number.isFinite(reset) && reset > nowSeconds) {
    return { seconds: reset - nowSeconds + 5, reset: true };
  }
  return { seconds: Math.min(60 * 2 ** (tryNumber - 1), 300), reset: false };
}

// The job's waited total, shared with gh_budget_wait.sh. Missing is 0; unreadable is all of it.
function ledger(env, maxTotal) {
  const dir = path.join(env.RUNNER_TEMP || env.TMPDIR || '/tmp', 'gh-budget-wait');
  const file = path.join(dir, 'waited');
  return {
    spent() {
      let text;
      try {
        text = fs.readFileSync(file, 'utf8').trim();
      } catch (error) {
        return error.code === 'ENOENT' ? 0 : maxTotal;
      }
      return /^[0-9]+$/.test(text) ? Number(text) : maxTotal;
    },
    // Reserved before sleeping, as the shell wrapper does; false when it cannot be written.
    reserve(seconds, why) {
      try {
        fs.mkdirSync(dir, { recursive: true });
        const tmp = `${file}.${process.pid}`;
        fs.writeFileSync(tmp, String(this.spent() + seconds));
        fs.renameSync(tmp, file);
        fs.appendFileSync(path.join(dir, 'waits.log'), `${new Date().toISOString().slice(11, 19)}Z ${why}\n`);
        return true;
      } catch {
        return false;
      }
    },
  };
}

function install({ github, core, env = process.env, sleep, now, spare } = {}) {
  if (!github || !github.hook) throw new Error('gh_budget_wait.cjs: install needs the github-script `github` client');
  const log = core || { notice: console.log, error: console.error };
  const pause = sleep || ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
  const clock = now || (() => Math.floor(Date.now() / 1000));
  const maxTotal = intEnv(env, 'GH_BUDGET_WAIT_MAX_SECONDS', 3600);
  const rateAttempts = intEnv(env, 'GH_BUDGET_WAIT_ATTEMPTS', 6);
  const serverAttempts = intEnv(env, 'GH_BUDGET_WAIT_5XX_ATTEMPTS', 4);
  const book = ledger(env, maxTotal);

  github.hook.wrap('request', async (request, options) => {
    const what = `${options.method} ${options.url}`;
    let rateTries = 0;
    let serverTries = 0;
    let spareTried = !spare || options.method !== 'GET';
    for (;;) {
      try {
        return await request(options);
      } catch (error) {
        const kind = classify(error);
        if (!kind) throw error;
        let want;
        let note;
        if (kind === 'rate' && !spareTried) {
          spareTried = true;
          // Without `request`: it carries the first client's hook (and so its token); the spare adds its own.
          const { request: _ownHook, ...route } = options;
          try {
            const answer = await spare.request(route);
            log.notice(`GitHub API budget: ${what} was refused for the API rate limit; read it on the spare token instead of waiting`);
            return answer;
          } catch (spareError) {
            log.notice(`GitHub API budget: ${what} was refused for the API rate limit, and on the spare token too (${spareError.status || spareError.message})`);
          }
        }
        if (kind === 'rate') {
          rateTries += 1;
          note = `was refused for the API rate limit (try ${rateTries} of ${rateAttempts})`;
          if (rateTries >= rateAttempts) {
            log.error(`GitHub API: ${what} ${note}; failing: ${error.message}`);
            throw error;
          }
          const wait = rateLimitWait(error, rateTries, clock());
          const left = maxTotal - book.spent();
          if (wait.reset && wait.seconds > left) {
            log.error(`GitHub API: ${what} ${note}; the budget resets in ${wait.seconds}s, past this job's ${left}s left to wait (GH_BUDGET_WAIT_MAX_SECONDS=${maxTotal}); failing: ${error.message}`);
            throw error;
          }
          want = wait.seconds;
        } else {
          serverTries += 1;
          note = `got a GitHub server error ${error.status} (try ${serverTries} of ${serverAttempts})`;
          if (serverTries >= serverAttempts) {
            log.error(`GitHub API: ${what} ${note}; failing: ${error.message}`);
            throw error;
          }
          want = 10 * 2 ** (serverTries - 1);
        }
        const left = maxTotal - book.spent();
        if (left <= 0) {
          log.error(`GitHub API: ${what} ${note}; this job's ${maxTotal}s of waiting is spent; failing: ${error.message}`);
          throw error;
        }
        want = Math.min(want, left);
        const why = `${what} ${note}; waiting ${want}s`;
        if (!book.reserve(want, why)) {
          log.error(`GitHub API: ${what} ${note}; could not record a ${want}s wait; failing: ${error.message}`);
          throw error;
        }
        log.notice(`GitHub API budget: ${why}`);
        await pause(want * 1000);
      }
    }
  });
  return github;
}

module.exports = { install, classify, rateLimitWait };
