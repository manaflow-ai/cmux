use managed::ManagedSlice;

use crate::storage::{Full, RingBuffer};

use super::Empty;

/// Size and header of a packet.
#[derive(Debug, Clone, Copy)]
#[cfg_attr(feature = "defmt", derive(defmt::Format))]
pub struct PacketMetadata<H> {
    size: usize,
    header: Option<H>,
}

impl<H> PacketMetadata<H> {
    /// Empty packet description.
    pub const EMPTY: PacketMetadata<H> = PacketMetadata {
        size: 0,
        header: None,
    };

    fn padding(size: usize) -> PacketMetadata<H> {
        PacketMetadata {
            size: size,
            header: None,
        }
    }

    fn packet(size: usize, header: H) -> PacketMetadata<H> {
        PacketMetadata {
            size: size,
            header: Some(header),
        }
    }

    fn is_padding(&self) -> bool {
        self.header.is_none()
    }
}

/// An UDP packet ring buffer.
#[derive(Debug)]
pub struct PacketBuffer<'a, H: 'a> {
    metadata_ring: RingBuffer<'a, PacketMetadata<H>>,
    payload_ring: RingBuffer<'a, u8>,
}

impl<'a, H> PacketBuffer<'a, H> {
    /// Create a new packet buffer with the provided metadata and payload storage.
    ///
    /// Metadata storage limits the maximum _number_ of packets in the buffer and payload
    /// storage limits the maximum _total size_ of packets.
    pub fn new<MS, PS>(metadata_storage: MS, payload_storage: PS) -> PacketBuffer<'a, H>
    where
        MS: Into<ManagedSlice<'a, PacketMetadata<H>>>,
        PS: Into<ManagedSlice<'a, u8>>,
    {
        PacketBuffer {
            metadata_ring: RingBuffer::new(metadata_storage),
            payload_ring: RingBuffer::new(payload_storage),
        }
    }

    /// Query whether the buffer is empty.
    pub fn is_empty(&self) -> bool {
        self.metadata_ring.is_empty()
    }

    /// Query whether the buffer is full.
    pub fn is_full(&self) -> bool {
        self.metadata_ring.is_full()
    }

    // There is currently no enqueue_with() because of the complexity of managing padding
    // in case of failure.

    /// Enqueue a single packet with the given header into the buffer, and
    /// return a reference to its payload, or return `Err(Full)`
    /// if the buffer is full.
    pub fn enqueue(&mut self, size: usize, header: H) -> Result<&mut [u8], Full> {
        if self.payload_ring.capacity() < size || self.metadata_ring.is_full() {
            return Err(Full);
        }

        // Ring is currently empty.  Clear it (resetting `read_at`) to maximize
        // for contiguous space.
        if self.payload_ring.is_empty() {
            self.payload_ring.clear();
        }

        let window = self.payload_ring.window();
        let contig_window = self.payload_ring.contiguous_window();

        if window < size {
            return Err(Full);
        } else if contig_window < size {
            if window - contig_window < size {
                // The buffer length is larger than the current contiguous window
                // and is larger than the contiguous window will be after adding
                // the padding necessary to circle around to the beginning of the
                // ring buffer.
                return Err(Full);
            } else {
                // Add padding to the end of the ring buffer so that the
                // contiguous window is at the beginning of the ring buffer.
                *self.metadata_ring.enqueue_one()? = PacketMetadata::padding(contig_window);
                // note(discard): function does not write to the result
                // enqueued padding buffer location
                let _buf_enqueued = self.payload_ring.enqueue_many(contig_window);
            }
        }

        *self.metadata_ring.enqueue_one()? = PacketMetadata::packet(size, header);

        let payload_buf = self.payload_ring.enqueue_many(size);
        debug_assert!(payload_buf.len() == size);
        Ok(payload_buf)
    }

    /// Call `f` with a packet from the buffer large enough to fit `max_size` bytes. The packet
    /// is shrunk to the size returned from `f` and enqueued into the buffer.
    pub fn enqueue_with_infallible<'b, F>(
        &'b mut self,
        max_size: usize,
        header: H,
        f: F,
    ) -> Result<usize, Full>
    where
        F: FnOnce(&'b mut [u8]) -> usize,
    {
        if self.payload_ring.capacity() < max_size || self.metadata_ring.is_full() {
            return Err(Full);
        }

        let window = self.payload_ring.window();
        let contig_window = self.payload_ring.contiguous_window();

        if window < max_size {
            return Err(Full);
        } else if contig_window < max_size {
            if window - contig_window < max_size {
                // The buffer length is larger than the current contiguous window
                // and is larger than the contiguous window will be after adding
                // the padding necessary to circle around to the beginning of the
                // ring buffer.
                return Err(Full);
            } else {
                // Add padding to the end of the ring buffer so that the
                // contiguous window is at the beginning of the ring buffer.
                *self.metadata_ring.enqueue_one()? = PacketMetadata::padding(contig_window);
                // note(discard): function does not write to the result
                // enqueued padding buffer location
                let _buf_enqueued = self.payload_ring.enqueue_many(contig_window);
            }
        }

        let metadata_slot = self.metadata_ring.enqueue_one()?;

        // Only call f once we know that we will succeed
        let (size, _) = self
            .payload_ring
            .enqueue_many_with(|data| (f(&mut data[..max_size]), ()));

        *metadata_slot = PacketMetadata::packet(size, header);

        Ok(size)
    }

    fn dequeue_padding(&mut self) {
        let _ = self.metadata_ring.dequeue_one_with(|metadata| {
            if metadata.is_padding() {
                // note(discard): function does not use value of dequeued padding bytes
                let _buf_dequeued = self.payload_ring.dequeue_many(metadata.size);
                Ok(()) // dequeue metadata
            } else {
                Err(()) // don't dequeue metadata
            }
        });
    }

    /// Call `f` with a single packet from the buffer, and dequeue the packet if `f`
    /// returns successfully, or return `Err(EmptyError)` if the buffer is empty.
    pub fn dequeue_with<'c, R, E, F>(&'c mut self, f: F) -> Result<Result<R, E>, Empty>
    where
        F: FnOnce(&mut H, &'c mut [u8]) -> Result<R, E>,
    {
        self.dequeue_padding();

        self.metadata_ring.dequeue_one_with(|metadata| {
            self.payload_ring
                .dequeue_many_with(|payload_buf| {
                    debug_assert!(payload_buf.len() >= metadata.size);

                    match f(
                        metadata.header.as_mut().unwrap(),
                        &mut payload_buf[..metadata.size],
                    ) {
                        Ok(val) => (metadata.size, Ok(val)),
                        Err(err) => (0, Err(err)),
                    }
                })
                .1
        })
    }

    /// Dequeue a single packet from the buffer, and return a reference to its payload
    /// as well as its header, or return `Err(Error::Exhausted)` if the buffer is empty.
    pub fn dequeue(&mut self) -> Result<(H, &mut [u8]), Empty> {
        self.dequeue_padding();

        let meta = self.metadata_ring.dequeue_one()?;

        let payload_buf = self.payload_ring.dequeue_many(meta.size);
        debug_assert!(payload_buf.len() == meta.size);
        Ok((meta.header.take().unwrap(), payload_buf))
    }

    /// Peek at a single packet from the buffer without removing it, and return a reference to
    /// its payload as well as its header, or return `Err(Error:Exhausted)` if the buffer is empty.
    ///
    /// This function otherwise behaves identically to [dequeue](#method.dequeue).
    pub fn peek(&mut self) -> Result<(&H, &[u8]), Empty> {
        self.dequeue_padding();

        if let Some(metadata) = self.metadata_ring.get_allocated(0, 1).first() {
            Ok((
                metadata.header.as_ref().unwrap(),
                self.payload_ring.get_allocated(0, metadata.size),
            ))
        } else {
            Err(Empty)
        }
    }

    /// Return the maximum number packets that can be stored.
    pub fn packet_capacity(&self) -> usize {
        self.metadata_ring.capacity()
    }

    /// Return the maximum number of bytes in the payload ring buffer.
    pub fn payload_capacity(&self) -> usize {
        self.payload_ring.capacity()
    }

    /// Return the current number of bytes in the payload ring buffer.
    pub fn payload_bytes_count(&self) -> usize {
        self.payload_ring.len()
    }

    /// Reset the packet buffer and clear any staged.
    #[allow(unused)]
    pub(crate) fn reset(&mut self) {
        self.payload_ring.clear();
        self.metadata_ring.clear();
    }
}

#[cfg(test)]
#[path = "packet_buffer_test_tests.rs"]
mod test;
