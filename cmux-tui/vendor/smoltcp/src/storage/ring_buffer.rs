// Some of the functions in ring buffer is marked as #[must_use]. It notes that
// these functions may have side effects, and it's implemented by [RFC 1940].
// [RFC 1940]: https://github.com/rust-lang/rust/issues/43302

use core::cmp;
use managed::ManagedSlice;

use crate::storage::Resettable;

use super::{Empty, Full};

/// A ring buffer.
///
/// This ring buffer implementation provides many ways to interact with it:
///
///   * Enqueueing or dequeueing one element from corresponding side of the buffer;
///   * Enqueueing or dequeueing a slice of elements from corresponding side of the buffer;
///   * Accessing allocated and unallocated areas directly.
///
/// It is also zero-copy; all methods provide references into the buffer's storage.
/// Note that all references are mutable; it is considered more important to allow
/// in-place processing than to protect from accidental mutation.
///
/// This implementation is suitable for both simple uses such as a FIFO queue
/// of UDP packets, and advanced ones such as a TCP reassembly buffer.
#[derive(Debug)]
pub struct RingBuffer<'a, T: 'a> {
    storage: ManagedSlice<'a, T>,
    read_at: usize,
    length: usize,
}

impl<'a, T: 'a> RingBuffer<'a, T> {
    /// Create a ring buffer with the given storage.
    ///
    /// During creation, every element in `storage` is reset.
    pub fn new<S>(storage: S) -> RingBuffer<'a, T>
    where
        S: Into<ManagedSlice<'a, T>>,
    {
        RingBuffer {
            storage: storage.into(),
            read_at: 0,
            length: 0,
        }
    }

    /// Clear the ring buffer.
    pub fn clear(&mut self) {
        self.read_at = 0;
        self.length = 0;
    }

    /// Return the maximum number of elements in the ring buffer.
    pub fn capacity(&self) -> usize {
        self.storage.len()
    }

    /// Clear the ring buffer, and reset every element.
    pub fn reset(&mut self)
    where
        T: Resettable,
    {
        self.clear();
        for elem in self.storage.iter_mut() {
            elem.reset();
        }
    }

    /// Return the current number of elements in the ring buffer.
    pub fn len(&self) -> usize {
        self.length
    }

    /// Return the number of elements that can be added to the ring buffer.
    pub fn window(&self) -> usize {
        self.capacity() - self.len()
    }

    /// Return the largest number of elements that can be added to the buffer
    /// without wrapping around (i.e. in a single `enqueue_many` call).
    pub fn contiguous_window(&self) -> usize {
        cmp::min(self.window(), self.capacity() - self.get_idx(self.length))
    }

    /// Query whether the buffer is empty.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Query whether the buffer is full.
    pub fn is_full(&self) -> bool {
        self.window() == 0
    }

    /// Shorthand for `(self.read + idx) % self.capacity()` with an
    /// additional check to ensure that the capacity is not zero.
    fn get_idx(&self, idx: usize) -> usize {
        let len = self.capacity();
        if len > 0 {
            (self.read_at + idx) % len
        } else {
            0
        }
    }

    /// Shorthand for `(self.read + idx) % self.capacity()` with no
    /// additional checks to ensure the capacity is not zero.
    fn get_idx_unchecked(&self, idx: usize) -> usize {
        (self.read_at + idx) % self.capacity()
    }
}

/// This is the "discrete" ring buffer interface: it operates with single elements,
/// and boundary conditions (empty/full) are errors.
impl<'a, T: 'a> RingBuffer<'a, T> {
    /// Call `f` with a single buffer element, and enqueue the element if `f`
    /// returns successfully, or return `Err(Full)` if the buffer is full.
    pub fn enqueue_one_with<'b, R, E, F>(&'b mut self, f: F) -> Result<Result<R, E>, Full>
    where
        F: FnOnce(&'b mut T) -> Result<R, E>,
    {
        if self.is_full() {
            return Err(Full);
        }

        let index = self.get_idx_unchecked(self.length);
        let res = f(&mut self.storage[index]);
        if res.is_ok() {
            self.length += 1;
        }
        Ok(res)
    }

    /// Enqueue a single element into the buffer, and return a reference to it,
    /// or return `Err(Full)` if the buffer is full.
    ///
    /// This function is a shortcut for `ring_buf.enqueue_one_with(Ok)`.
    pub fn enqueue_one(&mut self) -> Result<&mut T, Full> {
        self.enqueue_one_with(Ok)?
    }

    /// Call `f` with a single buffer element, and dequeue the element if `f`
    /// returns successfully, or return `Err(Empty)` if the buffer is empty.
    pub fn dequeue_one_with<'b, R, E, F>(&'b mut self, f: F) -> Result<Result<R, E>, Empty>
    where
        F: FnOnce(&'b mut T) -> Result<R, E>,
    {
        if self.is_empty() {
            return Err(Empty);
        }

        let next_at = self.get_idx_unchecked(1);
        let res = f(&mut self.storage[self.read_at]);

        if res.is_ok() {
            self.length -= 1;
            self.read_at = next_at;
        }
        Ok(res)
    }

    /// Dequeue an element from the buffer, and return a reference to it,
    /// or return `Err(Empty)` if the buffer is empty.
    ///
    /// This function is a shortcut for `ring_buf.dequeue_one_with(Ok)`.
    pub fn dequeue_one(&mut self) -> Result<&mut T, Empty> {
        self.dequeue_one_with(Ok)?
    }
}

/// This is the "continuous" ring buffer interface: it operates with element slices,
/// and boundary conditions (empty/full) simply result in empty slices.
impl<'a, T: 'a> RingBuffer<'a, T> {
    /// Call `f` with the largest contiguous slice of unallocated buffer elements,
    /// and enqueue the amount of elements returned by `f`.
    ///
    /// # Panics
    /// This function panics if the amount of elements returned by `f` is larger
    /// than the size of the slice passed into it.
    pub fn enqueue_many_with<'b, R, F>(&'b mut self, f: F) -> (usize, R)
    where
        F: FnOnce(&'b mut [T]) -> (usize, R),
    {
        if self.length == 0 {
            // Ring is currently empty. Reset `read_at` to optimize
            // for contiguous space.
            self.read_at = 0;
        }

        let write_at = self.get_idx(self.length);
        let max_size = self.contiguous_window();
        let (size, result) = f(&mut self.storage[write_at..write_at + max_size]);
        assert!(size <= max_size);
        self.length += size;
        (size, result)
    }

    /// Enqueue a slice of elements up to the given size into the buffer,
    /// and return a reference to them.
    ///
    /// This function may return a slice smaller than the given size
    /// if the free space in the buffer is not contiguous.
    #[must_use]
    pub fn enqueue_many(&mut self, size: usize) -> &mut [T] {
        self.enqueue_many_with(|buf| {
            let size = cmp::min(size, buf.len());
            (size, &mut buf[..size])
        })
        .1
    }

    /// Enqueue as many elements from the given slice into the buffer as possible,
    /// and return the amount of elements that could fit.
    #[must_use]
    pub fn enqueue_slice(&mut self, data: &[T]) -> usize
    where
        T: Copy,
    {
        let (size_1, data) = self.enqueue_many_with(|buf| {
            let size = cmp::min(buf.len(), data.len());
            buf[..size].copy_from_slice(&data[..size]);
            (size, &data[size..])
        });
        let (size_2, ()) = self.enqueue_many_with(|buf| {
            let size = cmp::min(buf.len(), data.len());
            buf[..size].copy_from_slice(&data[..size]);
            (size, ())
        });
        size_1 + size_2
    }

    /// Call `f` with the largest contiguous slice of allocated buffer elements,
    /// and dequeue the amount of elements returned by `f`.
    ///
    /// # Panics
    /// This function panics if the amount of elements returned by `f` is larger
    /// than the size of the slice passed into it.
    pub fn dequeue_many_with<'b, R, F>(&'b mut self, f: F) -> (usize, R)
    where
        F: FnOnce(&'b mut [T]) -> (usize, R),
    {
        let capacity = self.capacity();
        let max_size = cmp::min(self.len(), capacity - self.read_at);
        let (size, result) = f(&mut self.storage[self.read_at..self.read_at + max_size]);
        assert!(size <= max_size);
        self.read_at = if capacity > 0 {
            (self.read_at + size) % capacity
        } else {
            0
        };
        self.length -= size;
        (size, result)
    }

    /// Dequeue a slice of elements up to the given size from the buffer,
    /// and return a reference to them.
    ///
    /// This function may return a slice smaller than the given size
    /// if the allocated space in the buffer is not contiguous.
    #[must_use]
    pub fn dequeue_many(&mut self, size: usize) -> &mut [T] {
        self.dequeue_many_with(|buf| {
            let size = cmp::min(size, buf.len());
            (size, &mut buf[..size])
        })
        .1
    }

    /// Dequeue as many elements from the buffer into the given slice as possible,
    /// and return the amount of elements that could fit.
    #[must_use]
    pub fn dequeue_slice(&mut self, data: &mut [T]) -> usize
    where
        T: Copy,
    {
        let (size_1, data) = self.dequeue_many_with(|buf| {
            let size = cmp::min(buf.len(), data.len());
            data[..size].copy_from_slice(&buf[..size]);
            (size, &mut data[size..])
        });
        let (size_2, ()) = self.dequeue_many_with(|buf| {
            let size = cmp::min(buf.len(), data.len());
            data[..size].copy_from_slice(&buf[..size]);
            (size, ())
        });
        size_1 + size_2
    }
}

/// This is the "random access" ring buffer interface: it operates with element slices,
/// and allows to access elements of the buffer that are not adjacent to its head or tail.
impl<'a, T: 'a> RingBuffer<'a, T> {
    /// Return the largest contiguous slice of unallocated buffer elements starting
    /// at the given offset past the last allocated element, and up to the given size.
    #[must_use]
    pub fn get_unallocated(&mut self, offset: usize, mut size: usize) -> &mut [T] {
        let start_at = self.get_idx(self.length + offset);
        // We can't access past the end of unallocated data.
        if offset > self.window() {
            return &mut [];
        }
        // We can't enqueue more than there is free space.
        let clamped_window = self.window() - offset;
        if size > clamped_window {
            size = clamped_window
        }
        // We can't contiguously enqueue past the end of the storage.
        let until_end = self.capacity() - start_at;
        if size > until_end {
            size = until_end
        }

        &mut self.storage[start_at..start_at + size]
    }

    /// Write as many elements from the given slice into unallocated buffer elements
    /// starting at the given offset past the last allocated element, and return
    /// the amount written.
    #[must_use]
    pub fn write_unallocated(&mut self, offset: usize, data: &[T]) -> usize
    where
        T: Copy,
    {
        let (size_1, offset, data) = {
            let slice = self.get_unallocated(offset, data.len());
            let slice_len = slice.len();
            slice.copy_from_slice(&data[..slice_len]);
            (slice_len, offset + slice_len, &data[slice_len..])
        };
        let size_2 = {
            let slice = self.get_unallocated(offset, data.len());
            let slice_len = slice.len();
            slice.copy_from_slice(&data[..slice_len]);
            slice_len
        };
        size_1 + size_2
    }

    /// Enqueue the given number of unallocated buffer elements.
    ///
    /// # Panics
    /// Panics if the number of elements given exceeds the number of unallocated elements.
    pub fn enqueue_unallocated(&mut self, count: usize) {
        assert!(count <= self.window());
        self.length += count;
    }

    /// Return the largest contiguous slice of allocated buffer elements starting
    /// at the given offset past the first allocated element, and up to the given size.
    #[must_use]
    pub fn get_allocated(&self, offset: usize, mut size: usize) -> &[T] {
        let start_at = self.get_idx(offset);
        // We can't read past the end of the allocated data.
        if offset > self.length {
            return &mut [];
        }
        // We can't read more than we have allocated.
        let clamped_length = self.length - offset;
        if size > clamped_length {
            size = clamped_length
        }
        // We can't contiguously dequeue past the end of the storage.
        let until_end = self.capacity() - start_at;
        if size > until_end {
            size = until_end
        }

        &self.storage[start_at..start_at + size]
    }

    /// Read as many elements from allocated buffer elements into the given slice
    /// starting at the given offset past the first allocated element, and return
    /// the amount read.
    #[must_use]
    pub fn read_allocated(&mut self, offset: usize, data: &mut [T]) -> usize
    where
        T: Copy,
    {
        let (size_1, offset, data) = {
            let slice = self.get_allocated(offset, data.len());
            data[..slice.len()].copy_from_slice(slice);
            (slice.len(), offset + slice.len(), &mut data[slice.len()..])
        };
        let size_2 = {
            let slice = self.get_allocated(offset, data.len());
            data[..slice.len()].copy_from_slice(slice);
            slice.len()
        };
        size_1 + size_2
    }

    /// Dequeue the given number of allocated buffer elements.
    ///
    /// # Panics
    /// Panics if the number of elements given exceeds the number of allocated elements.
    pub fn dequeue_allocated(&mut self, count: usize) {
        assert!(count <= self.len());
        self.length -= count;
        self.read_at = self.get_idx(count);
    }
}

impl<'a, T: 'a> From<ManagedSlice<'a, T>> for RingBuffer<'a, T> {
    fn from(slice: ManagedSlice<'a, T>) -> RingBuffer<'a, T> {
        RingBuffer::new(slice)
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn test_buffer_length_changes() {
        let mut ring = RingBuffer::new(vec![0; 2]);
        assert!(ring.is_empty());
        assert!(!ring.is_full());
        assert_eq!(ring.len(), 0);
        assert_eq!(ring.capacity(), 2);
        assert_eq!(ring.window(), 2);

        ring.length = 1;
        assert!(!ring.is_empty());
        assert!(!ring.is_full());
        assert_eq!(ring.len(), 1);
        assert_eq!(ring.capacity(), 2);
        assert_eq!(ring.window(), 1);

        ring.length = 2;
        assert!(!ring.is_empty());
        assert!(ring.is_full());
        assert_eq!(ring.len(), 2);
        assert_eq!(ring.capacity(), 2);
        assert_eq!(ring.window(), 0);
    }

    #[test]
    fn test_buffer_enqueue_dequeue_one_with() {
        let mut ring = RingBuffer::new(vec![0; 5]);
        assert_eq!(
            ring.dequeue_one_with(|_| -> Result::<(), ()> { unreachable!() }),
            Err(Empty)
        );

        ring.enqueue_one_with(Ok::<_, ()>).unwrap().unwrap();
        assert!(!ring.is_empty());
        assert!(!ring.is_full());

        for i in 1..5 {
            ring.enqueue_one_with(|e| Ok::<_, ()>(*e = i))
                .unwrap()
                .unwrap();
            assert!(!ring.is_empty());
        }
        assert!(ring.is_full());
        assert_eq!(
            ring.enqueue_one_with(|_| -> Result::<(), ()> { unreachable!() }),
            Err(Full)
        );

        for i in 0..5 {
            assert_eq!(
                ring.dequeue_one_with(|e| Ok::<_, ()>(*e)).unwrap().unwrap(),
                i
            );
            assert!(!ring.is_full());
        }
        assert_eq!(
            ring.dequeue_one_with(|_| -> Result::<(), ()> { unreachable!() }),
            Err(Empty)
        );
        assert!(ring.is_empty());
    }

    #[test]
    fn test_buffer_enqueue_dequeue_one() {
        let mut ring = RingBuffer::new(vec![0; 5]);
        assert_eq!(ring.dequeue_one(), Err(Empty));

        ring.enqueue_one().unwrap();
        assert!(!ring.is_empty());
        assert!(!ring.is_full());

        for i in 1..5 {
            *ring.enqueue_one().unwrap() = i;
            assert!(!ring.is_empty());
        }
        assert!(ring.is_full());
        assert_eq!(ring.enqueue_one(), Err(Full));

        for i in 0..5 {
            assert_eq!(*ring.dequeue_one().unwrap(), i);
            assert!(!ring.is_full());
        }
        assert_eq!(ring.dequeue_one(), Err(Empty));
        assert!(ring.is_empty());
    }

    #[test]
    fn test_buffer_enqueue_many_with() {
        let mut ring = RingBuffer::new(vec![b'.'; 12]);

        assert_eq!(
            ring.enqueue_many_with(|buf| {
                assert_eq!(buf.len(), 12);
                buf[0..2].copy_from_slice(b"ab");
                (2, true)
            }),
            (2, true)
        );
        assert_eq!(ring.len(), 2);
        assert_eq!(&ring.storage[..], b"ab..........");

        ring.enqueue_many_with(|buf| {
            assert_eq!(buf.len(), 12 - 2);
            buf[0..4].copy_from_slice(b"cdXX");
            (2, ())
        });
        assert_eq!(ring.len(), 4);
        assert_eq!(&ring.storage[..], b"abcdXX......");

        ring.enqueue_many_with(|buf| {
            assert_eq!(buf.len(), 12 - 4);
            buf[0..4].copy_from_slice(b"efgh");
            (4, ())
        });
        assert_eq!(ring.len(), 8);
        assert_eq!(&ring.storage[..], b"abcdefgh....");

        for _ in 0..4 {
            *ring.dequeue_one().unwrap() = b'.';
        }
        assert_eq!(ring.len(), 4);
        assert_eq!(&ring.storage[..], b"....efgh....");

        ring.enqueue_many_with(|buf| {
            assert_eq!(buf.len(), 12 - 8);
            buf[0..4].copy_from_slice(b"ijkl");
            (4, ())
        });
        assert_eq!(ring.len(), 8);
        assert_eq!(&ring.storage[..], b"....efghijkl");

        ring.enqueue_many_with(|buf| {
            assert_eq!(buf.len(), 4);
            buf[0..4].copy_from_slice(b"abcd");
            (4, ())
        });
        assert_eq!(ring.len(), 12);
        assert_eq!(&ring.storage[..], b"abcdefghijkl");

        for _ in 0..4 {
            *ring.dequeue_one().unwrap() = b'.';
        }
        assert_eq!(ring.len(), 8);
        assert_eq!(&ring.storage[..], b"abcd....ijkl");
    }

    #[test]
    fn test_buffer_enqueue_many() {
        let mut ring = RingBuffer::new(vec![b'.'; 12]);

        ring.enqueue_many(8).copy_from_slice(b"abcdefgh");
        assert_eq!(ring.len(), 8);
        assert_eq!(&ring.storage[..], b"abcdefgh....");

        ring.enqueue_many(8).copy_from_slice(b"ijkl");
        assert_eq!(ring.len(), 12);
        assert_eq!(&ring.storage[..], b"abcdefghijkl");
    }

    #[test]
    fn test_buffer_enqueue_slice() {
        let mut ring = RingBuffer::new(vec![b'.'; 12]);

        assert_eq!(ring.enqueue_slice(b"abcdefgh"), 8);
        assert_eq!(ring.len(), 8);
        assert_eq!(&ring.storage[..], b"abcdefgh....");

        for _ in 0..4 {
            *ring.dequeue_one().unwrap() = b'.';
        }
        assert_eq!(ring.len(), 4);
        assert_eq!(&ring.storage[..], b"....efgh....");

        assert_eq!(ring.enqueue_slice(b"ijklabcd"), 8);
        assert_eq!(ring.len(), 12);
        assert_eq!(&ring.storage[..], b"abcdefghijkl");
    }

    #[test]
    fn test_buffer_dequeue_many_with() {
        let mut ring = RingBuffer::new(vec![b'.'; 12]);

        assert_eq!(ring.enqueue_slice(b"abcdefghijkl"), 12);

        assert_eq!(
            ring.dequeue_many_with(|buf| {
                assert_eq!(buf.len(), 12);
                assert_eq!(buf, b"abcdefghijkl");
                buf[..4].copy_from_slice(b"....");
                (4, true)
            }),
            (4, true)
        );
        assert_eq!(ring.len(), 8);
        assert_eq!(&ring.storage[..], b"....efghijkl");

        ring.dequeue_many_with(|buf| {
            assert_eq!(buf, b"efghijkl");
            buf[..4].copy_from_slice(b"....");
            (4, ())
        });
        assert_eq!(ring.len(), 4);
        assert_eq!(&ring.storage[..], b"........ijkl");

        assert_eq!(ring.enqueue_slice(b"abcd"), 4);
        assert_eq!(ring.len(), 8);

        ring.dequeue_many_with(|buf| {
            assert_eq!(buf, b"ijkl");
            buf[..4].copy_from_slice(b"....");
            (4, ())
        });
        ring.dequeue_many_with(|buf| {
            assert_eq!(buf, b"abcd");
            buf[..4].copy_from_slice(b"....");
            (4, ())
        });
        assert_eq!(ring.len(), 0);
        assert_eq!(&ring.storage[..], b"............");
    }

    #[test]
    fn test_buffer_dequeue_many() {
        let mut ring = RingBuffer::new(vec![b'.'; 12]);

        assert_eq!(ring.enqueue_slice(b"abcdefghijkl"), 12);

        {
            let buf = ring.dequeue_many(8);
            assert_eq!(buf, b"abcdefgh");
            buf.copy_from_slice(b"........");
        }
        assert_eq!(ring.len(), 4);
        assert_eq!(&ring.storage[..], b"........ijkl");

        {
            let buf = ring.dequeue_many(8);
            assert_eq!(buf, b"ijkl");
            buf.copy_from_slice(b"....");
        }
        assert_eq!(ring.len(), 0);
        assert_eq!(&ring.storage[..], b"............");
    }

    #[test]
    fn test_buffer_dequeue_slice() {
        let mut ring = RingBuffer::new(vec![b'.'; 12]);

        assert_eq!(ring.enqueue_slice(b"abcdefghijkl"), 12);

        {
            let mut buf = [0; 8];
            assert_eq!(ring.dequeue_slice(&mut buf[..]), 8);
            assert_eq!(&buf[..], b"abcdefgh");
            assert_eq!(ring.len(), 4);
        }

        assert_eq!(ring.enqueue_slice(b"abcd"), 4);

        {
            let mut buf = [0; 8];
            assert_eq!(ring.dequeue_slice(&mut buf[..]), 8);
            assert_eq!(&buf[..], b"ijklabcd");
            assert_eq!(ring.len(), 0);
        }
    }

    #[test]
    fn test_buffer_get_unallocated() {
        let mut ring = RingBuffer::new(vec![b'.'; 12]);

        assert_eq!(ring.get_unallocated(16, 4), b"");

        {
            let buf = ring.get_unallocated(0, 4);
            buf.copy_from_slice(b"abcd");
        }
        assert_eq!(&ring.storage[..], b"abcd........");

        let buf_enqueued = ring.enqueue_many(4);
        assert_eq!(buf_enqueued.len(), 4);
        assert_eq!(ring.len(), 4);

        {
            let buf = ring.get_unallocated(4, 8);
            buf.copy_from_slice(b"ijkl");
        }
        assert_eq!(&ring.storage[..], b"abcd....ijkl");

        ring.enqueue_many(8).copy_from_slice(b"EFGHIJKL");
        ring.dequeue_many(4).copy_from_slice(b"abcd");
        assert_eq!(ring.len(), 8);
        assert_eq!(&ring.storage[..], b"abcdEFGHIJKL");

        {
            let buf = ring.get_unallocated(0, 8);
            buf.copy_from_slice(b"ABCD");
        }
        assert_eq!(&ring.storage[..], b"ABCDEFGHIJKL");
    }

    #[test]
    fn test_buffer_write_unallocated() {
        let mut ring = RingBuffer::new(vec![b'.'; 12]);
        ring.enqueue_many(6).copy_from_slice(b"abcdef");
        ring.dequeue_many(6).copy_from_slice(b"ABCDEF");

        assert_eq!(ring.write_unallocated(0, b"ghi"), 3);
        assert_eq!(ring.get_unallocated(0, 3), b"ghi");

        assert_eq!(ring.write_unallocated(3, b"jklmno"), 6);
        assert_eq!(ring.get_unallocated(3, 3), b"jkl");

        assert_eq!(ring.write_unallocated(9, b"pqrstu"), 3);
        assert_eq!(ring.get_unallocated(9, 3), b"pqr");
    }

    #[test]
    fn test_buffer_get_allocated() {
        let mut ring = RingBuffer::new(vec![b'.'; 12]);

        assert_eq!(ring.get_allocated(16, 4), b"");
        assert_eq!(ring.get_allocated(0, 4), b"");

        let len_enqueued = ring.enqueue_slice(b"abcd");
        assert_eq!(ring.get_allocated(0, 8), b"abcd");
        assert_eq!(len_enqueued, 4);

        let len_enqueued = ring.enqueue_slice(b"efghijkl");
        ring.dequeue_many(4).copy_from_slice(b"....");
        assert_eq!(ring.get_allocated(4, 8), b"ijkl");
        assert_eq!(len_enqueued, 8);

        let len_enqueued = ring.enqueue_slice(b"abcd");
        assert_eq!(ring.get_allocated(4, 8), b"ijkl");
        assert_eq!(len_enqueued, 4);
    }

    #[test]
    fn test_buffer_read_allocated() {
        let mut ring = RingBuffer::new(vec![b'.'; 12]);
        ring.enqueue_many(12).copy_from_slice(b"abcdefghijkl");

        let mut data = [0; 6];
        assert_eq!(ring.read_allocated(0, &mut data[..]), 6);
        assert_eq!(&data[..], b"abcdef");

        ring.dequeue_many(6).copy_from_slice(b"ABCDEF");
        ring.enqueue_many(3).copy_from_slice(b"mno");

        let mut data = [0; 6];
        assert_eq!(ring.read_allocated(3, &mut data[..]), 6);
        assert_eq!(&data[..], b"jklmno");

        let mut data = [0; 6];
        assert_eq!(ring.read_allocated(6, &mut data[..]), 3);
        assert_eq!(&data[..], b"mno\x00\x00\x00");
    }

    #[test]
    fn test_buffer_with_no_capacity() {
        let mut no_capacity: RingBuffer<u8> = RingBuffer::new(vec![]);

        // Call all functions that calculate the remainder against rx_buffer.capacity()
        // with a backing storage with a length of 0.
        assert_eq!(no_capacity.get_unallocated(0, 0), &[]);
        assert_eq!(no_capacity.get_allocated(0, 0), &[]);
        no_capacity.dequeue_allocated(0);
        assert_eq!(no_capacity.enqueue_many(0), &[]);
        assert_eq!(no_capacity.enqueue_one(), Err(Full));
        assert_eq!(no_capacity.contiguous_window(), 0);
    }

    /// Use the buffer a bit. Then empty it and put in an item of
    /// maximum size. By detecting a length of 0, the implementation
    /// can reset the current buffer position.
    #[test]
    fn test_buffer_write_wholly() {
        let mut ring = RingBuffer::new(vec![b'.'; 8]);
        ring.enqueue_many(2).copy_from_slice(b"ab");
        ring.enqueue_many(2).copy_from_slice(b"cd");
        assert_eq!(ring.len(), 4);
        let buf_dequeued = ring.dequeue_many(4);
        assert_eq!(buf_dequeued, b"abcd");
        assert_eq!(ring.len(), 0);

        let large = ring.enqueue_many(8);
        assert_eq!(large.len(), 8);
    }
}
