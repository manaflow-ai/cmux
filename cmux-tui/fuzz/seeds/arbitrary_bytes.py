"""Bytes that `arbitrary` 1.x (the version in cmux-tui/fuzz/Cargo.lock)
decodes into a chosen value, for the seeds of the fuzz targets whose input
is a `#[derive(Arbitrary)]` type.

The layout this mirrors (arbitrary src/unstructured.rs, foreign/, and
derive_arbitrary): integers are little-endian from the front; a bool is a
u8's low bit; an enum variant is `(u32 * variants) >> 32`; an Option is a
bool, then the value; a Vec is a bool before each element and a false bool
after the last; a String's byte length is taken from the end of the data
(one byte while 256 bytes or fewer remain, two while 65537 or fewer do) and
its bytes from the front. A struct's fields go in declaration order.
"""


class Arbitrary:
    def __init__(self):
        # ("front", bytes) or ("len", n): a length read from the end.
        self._ops = []

    def raw(self, data):
        self._ops.append(("front", bytes(data)))

    def u8(self, value):
        self.raw(value.to_bytes(1, "little"))

    def u16(self, value):
        self.raw(value.to_bytes(2, "little"))

    def u32(self, value):
        self.raw(value.to_bytes(4, "little"))

    def u64(self, value):
        self.raw(value.to_bytes(8, "little"))

    def i32(self, value):
        self.raw(value.to_bytes(4, "little", signed=True))

    def i64(self, value):
        self.raw(value.to_bytes(8, "little", signed=True))

    def bool(self, value):
        self.u8(1 if value else 0)

    def variant(self, index, count):
        tag = ((index << 32) + count - 1) // count
        assert (tag * count) >> 32 == index
        self.u32(tag)

    def string(self, value):
        data = value.encode()
        self._ops.append(("len", len(data)))
        self.raw(data)

    def option(self, value, encode):
        self.bool(value is not None)
        if value is not None:
            encode(value)

    def vec(self, items, encode):
        for item in items:
            self.bool(True)
            encode(item)
        self.bool(False)

    def byte_vec(self, data):
        self.vec(data, self.u8)

    def ipv4(self, octets):
        self.raw(bytes(octets))

    def finish(self):
        front = sum(len(data) for kind, data in self._ops if kind == "front")
        lengths = [n for kind, n in self._ops if kind == "len"]
        widths = [1] * len(lengths)
        while True:
            remaining = self._remaining(front + sum(widths), widths)
            new = [1 if left <= 256 else 2 for left in remaining]
            assert all(left <= 65537 for left in remaining), "a seed past 64 KiB"
            if new == widths:
                break
            widths = new
        chunks = []
        for n, left, width in zip(lengths, remaining, widths):
            largest = left - width
            assert n <= largest
            if width == 1 or largest < 256:
                chunks.append(bytes([n]) + bytes(width - 1))
            else:
                chunks.append(n.to_bytes(2, "big"))
        out = b"".join(data for kind, data in self._ops if kind == "front")
        return out + b"".join(reversed(chunks))

    def _remaining(self, total, widths):
        """The data left at each length read, with these length widths."""
        left, reads, out = total, iter(widths), []
        for kind, value in self._ops:
            if kind == "front":
                left -= len(value)
            else:
                out.append(left)
                left -= next(reads)
        return out
