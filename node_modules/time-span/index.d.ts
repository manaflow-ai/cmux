declare namespace timeSpan {
	interface TimeEndFunction {
		/**
		@returns Elapsed milliseconds.
		*/
		(): number;

		/**
		@returns Elapsed milliseconds rounded.
		*/
		rounded(): number;

		/**
		@returns Elapsed seconds.
		*/
		seconds(): number;

		/**
		@returns Elapsed nanoseconds.
		*/
		nanoseconds(): number;
	}
}

/**
Simplified high resolution timing.

@returns A function that returns the time difference.

@example
```
import timeSpan = require('time-span');

const end = timeSpan();

timeConsumingFn();

console.log(end());
//=> 1745.3186

console.log(end.rounded());
//=> 1745

console.log(end.seconds());
//=> 1.7453186
```
*/
declare function timeSpan(): timeSpan.TimeEndFunction;

export = timeSpan;
