use super::*;

impl InterfaceInner {
    /// Return the next IEEE802.15.4 sequence number.
    #[cfg(feature = "medium-ieee802154")]
    pub(super) fn next_ieee802154_seq_number(&mut self) -> u8 {
        let no = self.sequence_no;
        self.sequence_no = self.sequence_no.wrapping_add(1);
        no
    }

    pub(super) fn process_ieee802154<'output, 'payload: 'output>(
        &mut self,
        sockets: &mut SocketSet,
        meta: PacketMeta,
        sixlowpan_payload: &'payload [u8],
        _fragments: &'output mut FragmentsBuffer,
    ) -> Option<Packet<'output>> {
        let ieee802154_frame = check!(Ieee802154Frame::new_checked(sixlowpan_payload));

        if ieee802154_frame.frame_type() != Ieee802154FrameType::Data {
            return None;
        }

        let ieee802154_repr = check!(Ieee802154Repr::parse(&ieee802154_frame));

        // Drop frames when the user has set a PAN id and the PAN id from frame is not equal to this
        // When the user didn't set a PAN id (so it is None), then we accept all PAN id's.
        // We always accept the broadcast PAN id.
        if self.pan_id.is_some()
            && ieee802154_repr.dst_pan_id != self.pan_id
            && ieee802154_repr.dst_pan_id != Some(Ieee802154Pan::BROADCAST)
        {
            net_debug!(
                "IEEE802.15.4: dropping {:?} because not our PAN id (or not broadcast)",
                ieee802154_repr
            );
            return None;
        }

        match ieee802154_frame.payload() {
            Some(payload) => {
                self.process_sixlowpan(sockets, meta, &ieee802154_repr, payload, _fragments)
            }
            None => None,
        }
    }

    pub(super) fn dispatch_ieee802154<Tx: TxToken>(
        &mut self,
        ll_dst_a: Ieee802154Address,
        tx_token: Tx,
        meta: PacketMeta,
        packet: Packet,
        frag: &mut Fragmenter,
    ) {
        let ll_src_a = self.hardware_addr.ieee802154_or_panic();

        // Create the IEEE802.15.4 header.
        let ieee_repr = Ieee802154Repr {
            frame_type: Ieee802154FrameType::Data,
            security_enabled: false,
            frame_pending: false,
            ack_request: false,
            sequence_number: Some(self.next_ieee802154_seq_number()),
            pan_id_compression: true,
            frame_version: Ieee802154FrameVersion::Ieee802154_2003,
            dst_pan_id: self.pan_id,
            dst_addr: Some(ll_dst_a),
            src_pan_id: self.pan_id,
            src_addr: Some(ll_src_a),
        };

        self.dispatch_sixlowpan(tx_token, meta, packet, ieee_repr, frag);
    }

    #[cfg(feature = "proto-sixlowpan-fragmentation")]
    pub(super) fn dispatch_ieee802154_frag<Tx: TxToken>(
        &mut self,
        tx_token: Tx,
        frag: &mut Fragmenter,
    ) {
        // Create the IEEE802.15.4 header.
        let ieee_repr = Ieee802154Repr {
            frame_type: Ieee802154FrameType::Data,
            security_enabled: false,
            frame_pending: false,
            ack_request: false,
            sequence_number: Some(self.next_ieee802154_seq_number()),
            pan_id_compression: true,
            frame_version: Ieee802154FrameVersion::Ieee802154_2003,
            dst_pan_id: self.pan_id,
            dst_addr: Some(frag.sixlowpan.ll_dst_addr),
            src_pan_id: self.pan_id,
            src_addr: Some(frag.sixlowpan.ll_src_addr),
        };

        self.dispatch_sixlowpan_frag(tx_token, ieee_repr, frag);
    }
}
