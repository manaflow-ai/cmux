# async-sema

This is a semaphore implementation for use with `async` and `await`. The
implementation follows the traditional definition of a semaphore rather than the
definition of an asynchronous semaphore seen in some js community examples.
Where as the latter one generally allows every defined task to proceed
immediately and synchronizes at the end, async-sema allows only a selected
number of tasks to proceed at once while the rest will remain waiting.

Async-sema manages the semaphore count as a list of tokens instead of a single
variable containing the number of available resources. This enables an
interesting application of managing the actual resources with the semaphore
object itself. To make it practical the constructor for Sema includes an option
for providing an init function for the semaphore tokens. Use of a custom token
initializer is demonstrated in `examples/pooling.js`.

## Usage

Firstly, add the package to your project's `dependencies`:

```bash
npm install --save async-sema
```

or

```bash
yarn add async-sema
```

Then start using it like shown in the following example. Check more
use case examples [here](./examples).

## Example

```js
const { Sema } = require('async-sema');
const s = new Sema(
  4, // Allow 4 concurrent async calls
  {
    capacity: 100 // Prealloc space for 100 tokens
  }
);

async function fetchData(x) {
  await s.acquire()
  try {
    console.log(s.nrWaiting() + ' calls to fetch are waiting')
    // ... do some async stuff with x
  } finally {
    s.release();
  }
}

const data = await Promise.all(array.map(fetchData));
```

The package also offers a simple rate limiter utilizing the semaphore
implementation.

```js
const { RateLimit } = require('async-sema');

async function f() {
  const lim = RateLimit(5); // rps

  for (let i = 0; i < n; i++) {
    await lim();
    // ... do something async
  }
}
```

## API

### Sema

#### Constructor(nr, { initFn, pauseFn, resumeFn, capacity })

Creates a semaphore object. The first argument is mandatory and the second
argument is optional.

- `nr` The maximum number of callers allowed to acquire the semaphore
  concurrently.
- `initFn` Function that is used to initialize the tokens used to manage
  the semaphore. The default is `() => '1'`.
- `pauseFn` An optional fuction that is called to opportunistically request
  pausing the the incoming stream of data, instead of piling up waiting
  promises and possibly running out of memory.
  See [examples/pausing.js](./examples/pausing.js).
- `resumeFn` An optional function that is called when there is room again
  to accept new waiters on the semaphore. This function must be declared
  if a `pauseFn` is declared.
- `capacity` Sets the size of the preallocated waiting list inside the
  semaphore. This is typically used by high performance where the developer
  can make a rough estimate of the number of concurrent users of a semaphore.

#### async drain()

Drains the semaphore and returns all the initialized tokens in an array.
Draining is an ideal way to ensure there are no pending async tasks, for
example before a process will terminate.

#### nrWaiting()

Returns the number of callers waiting on the semaphore, i.e. the number of
pending promises.

#### tryAcquire()

Attempt to acquire a token from the semaphore, if one is available immediately.
Otherwise, return `undefined`.

#### async acquire()

Acquire a token from the semaphore, thus decrement the number of available
execution slots. If `initFn` is not used then the return value of the function
can be discarded.

#### release(token)

Release the semaphore, thus increment the number of free execution slots. If
`initFn` is used then the `token` returned by `acquire()` should be given as
an argument when calling this function.

### RateLimit(rps, { timeUnit, uniformDistribution })

Creates a rate limiter function that blocks with a promise whenever the rate
limit is hit and resolves the promise once the call rate is within the limit
set by `rps`. The second argument is optional.

The `timeUnit` is an optional argument setting the width of the rate limiting
window in milliseconds. The default `timeUnit` is `1000 ms`, therefore making
the `rps` argument act as requests per second limit.

The `uniformDistribution` argument enforces a discrete uniform distribution over
time, instead of the default that allows hitting the function `rps` time and
then pausing for `timeWindow` milliseconds. Setting the `uniformDistribution`
option is mainly useful in a situation where the flow of rate limit function
calls is continuous and and occuring faster than `timeUnit` (e.g. reading a
file) and not enabling it would cause the maximum number of calls to resolve
immediately (thus exhaust the limit immediately) and therefore the next bunch
calls would need to wait for `timeWindow` milliseconds. However if the flow is
sparse then this option may make the
code run slower with no advantages.

## Contributing

1. [Fork](https://help.github.com/articles/fork-a-repo/) this repository to your own GitHub account and then [clone](https://help.github.com/articles/cloning-a-repository/) it to your local device
2. Move into the directory of the clone: `cd async-sema`
3. Link it to the global module directory of Node.js: `npm link`

Inside the project where you want to test your clone of the package, you can now either use `npm link async-sema` to link the clone to the local dependencies.

## Author

Olli Vanhoja ([@OVanhoja](https://twitter.com/OVanhoja))
