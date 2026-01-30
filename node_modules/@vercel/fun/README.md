# ƒun
[![Build Status](https://github.com/vercel/fun/workflows/Node%20CI/badge.svg)](https://github.com/vercel/fun/actions?workflow=Node+CI)

Local serverless function λ development runtime.

## Example

Given a Lambda function like this one:

```js
// example/index.js
exports.handler = function(event, context, callback) {
	callback(null, { hello: 'world' });
};
```

You can invoke this function locally using the code below:

```js
import { createFunction } from '@vercel/fun';

async function main() {
	// Starts up the necessary server to be able to invoke the function
	const fn = await createFunction({
		Code: {
			// `ZipFile` works, or an already unzipped directory may be specified
			Directory: __dirname + '/example'
		},
		Handler: 'index.handler',
		Runtime: 'nodejs8.10',
		Environment: {
			Variables: {
				HELLO: 'world'
			}
		},
		MemorySize: 512
	});

	// Invoke the function with a custom payload. A new instance of the function
	// will be initialized if there is not an available one ready to process.
	const res = await fn({ hello: 'world' });

	console.log(res);
	// Prints: { hello: 'world' }

	// Once we are done with the function, destroy it so that the processes are
	// cleaned up, and the API server is shut down (useful for hot-reloading).
	await fn.destroy();
}

main().catch(console.error);
```

## Caveats

ƒun provides an execution environment that closely resembles the
real Lambda environment, with some key differences that are documented here:

 * Lambdas processes are ran as your own user, not the `sbx_user1051` user.
 * Processes are *not* sandboxed nor chrooted, so do not rely on hard-coded
   locations like `/var/task`, `/var/runtime`, `/opt`, etc. Instead, your
   function code should use the environment variables that represent these
   locations (namely `LAMBDA_TASK_ROOT` and `LAMBDA_RUNTIME_DIR`).
 * Processes are frozen by sending the `SIGSTOP` signal to the lambda process,
   and unfrozen by sending the `SIGCONT` signal, not using the [cgroup freezer][].
 * Lambdas that compile to native executables (i.e. Go) will need to be compiled
   for your operating system. So if you are on macOS, then the binary needs to be
   executable on macOS.

## Runtimes

ƒun aims to support all runtimes that AWS Lambda provides. Currently
implemented are:

 * `nodejs` for Node.js Lambda functions using the system `node` binary
 * `nodejs6.10` for Node.js Lambda functions using a downloaded Node v6.10.0 binary
 * `nodejs8.10` for Node.js Lambda functions using a downloaded Node v8.10.0 binary
 * `nodejs10.x` for Node.js Lambda functions using a downloaded Node v10.15.3 binary
 * `nodejs12.x` for Node.js Lambda functions using a downloaded Node v12.22.7 binary
 * `nodejs14.x` for Node.js Lambda functions using a downloaded Node v14.18.1 binary
 * `python` for Python Lambda functions using the system `python` binary
 * `python2.7` for Python Lambda functions using a downloaded Python v2.7.12 binary
 * `python3` for Python Lambda functions using the system `python3` binary (or fallback to `python`)
 * `python3.6` for Python Lambda functions using a downloaded Python v3.6.8 binary
 * `python3.7` for Python Lambda functions using a downloaded Python v3.7.2 binary
 * `go1.x` for Lambda functions written in Go - binary must be compiled for your platform
 * `provided` for [custom runtimes][]
 * `executable` for executables that are powered by Fluid compute

[cgroup freezer]: https://www.kernel.org/doc/Documentation/cgroup-v1/freezer-subsystem.txt
[custom runtimes]: https://docs.aws.amazon.com/lambda/latest/dg/runtimes-custom.html
