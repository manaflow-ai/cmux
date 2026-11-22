## Sources

The regression first appeared in 0.63[^bisect], and the fix follows the upstream advice[^upstream].
A filter like `[^a-z]` in code is not a note, and neither is this one: [^a-z].

##### Minor heading

###### Smallest heading

![build graph](https://example.com/assets/build-graph.png)

![](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==)

```js
const nonLetters = /[^a-z]/g; // [^b] in code is not a note either
```

See the earlier note again[^bisect].

[^upstream]: The maintainers' guidance in issue 412,
  which also covers the Linux case.
[^bisect]: `git bisect` between 0.62 and 0.63.
