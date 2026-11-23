import { expect, test } from "bun:test";
import { standInRanges } from "./standIns";

test("the overscan's rows no mounted range holds, in order", () => {
  expect(standInRanges({ first: 10, last: 40 }, [{ first: 18, last: 30 }])).toEqual([
    { first: 10, last: 18 },
    { first: 30, last: 40 },
  ]);
  expect(
    standInRanges({ first: 10, last: 40 }, [
      { first: 0, last: 12 },
      { first: 20, last: 22 },
      { first: 35, last: 90 },
    ]),
  ).toEqual([
    { first: 12, last: 20 },
    { first: 22, last: 35 },
  ]);
});

test("none where the mounted rows cover the overscan, all of it where none are mounted there", () => {
  expect(standInRanges({ first: 10, last: 40 }, [{ first: 5, last: 50 }])).toEqual([]);
  expect(standInRanges({ first: 10, last: 40 }, [])).toEqual([{ first: 10, last: 40 }]);
  expect(standInRanges({ first: 10, last: 40 }, [{ first: 50, last: 60 }])).toEqual([{ first: 10, last: 40 }]);
  expect(standInRanges({ first: 0, last: 0 }, [{ first: 0, last: 5 }])).toEqual([]);
});
