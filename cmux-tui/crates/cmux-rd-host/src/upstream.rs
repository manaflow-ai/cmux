//! Upstream media streams a viewer opens on this host (rd change C4).
//! Red tests first; the handler follows.

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_rd_core::cc::{CcConfig, PathKind};
    use cmux_rd_core::upstream::{UpstreamConfig, UpstreamSender};
    use cmux_rd_engine::EngineConfig;
    use cmux_rd_proto::MAX_DATAGRAM_VPC;

    const MIC: u16 = 100;
    const CAMERA: u16 = 101;

    #[derive(Default)]
    struct Recorder {
        audio_only: bool,
        events: Vec<String>,
        frames: Vec<(u16, Vec<u8>)>,
    }

    impl UpstreamSink for Recorder {
        fn accepts(&self, kind: StreamKind) -> bool {
            kind == StreamKind::UpAudio || (!self.audio_only && kind == StreamKind::UpVideo)
        }
        fn open(&mut self, stream: u16, kind: StreamKind) -> Result<(), String> {
            self.events.push(format!("open {stream} {kind:?}"));
            Ok(())
        }
        fn frame(&mut self, stream: u16, frame: &CompleteFrame) {
            self.frames.push((stream, frame.body.access_unit.clone()));
        }
        fn close(&mut self, stream: u16) {
            self.events.push(format!("close {stream}"));
        }
    }

    fn negotiated() -> Vec<String> {
        vec![caps::UP_MEDIA.into(), caps::STREAM_OPEN.into()]
    }

    fn open(kind: StreamKind, stream: u16, codec: &str) -> Control {
        Control::StreamOpen { stream, kind, codec: codec.into(), of: None }
    }

    fn engine() -> MediaEngine {
        MediaEngine::new(EngineConfig::default(), 0)
    }

    fn reason(answer: Option<Control>) -> String {
        match answer {
            Some(Control::StreamRefused { reason, .. }) => reason,
            other => panic!("expected a refusal, got {other:?}"),
        }
    }

    #[test]
    fn a_host_without_a_sink_offers_no_upstream_caps() {
        assert!(offered_caps(&NoSink).is_empty());
        assert_eq!(offered_caps(&Recorder::default()), vec![caps::UP_MEDIA, caps::STREAM_OPEN]);
    }

    #[test]
    fn an_opened_mic_stream_reaches_the_sink_and_the_viewer_gets_acks() {
        let mut e = engine();
        let mut up = Upstreams::new(Recorder::default(), &negotiated());
        let answer = up.on_control(&mut e, &open(StreamKind::UpAudio, MIC, "opus"), true);
        assert!(matches!(answer, Some(Control::StreamOpened { stream: MIC })), "{answer:?}");
        assert_eq!(up.sink().events, vec!["open 100 UpAudio"]);

        // The viewer's sender (rd-ffi's CmuxRdUpstream core) on the same wire.
        let mut viewer = UpstreamSender::new(UpstreamConfig {
            stream: MIC,
            max_datagram: MAX_DATAGRAM_VPC,
            cc: CcConfig::default(),
            path: PathKind::DirectWan,
            fec: false,
        });
        let sent = viewer.send_frame(&[7u8; 120], 20_000, true, 0).expect("packetize");
        for d in sent.expect("sent") {
            let out = e.on_datagram(&d, false, 1_000);
            up.deliver(&out.upstream);
        }
        assert_eq!(up.sink().frames, vec![(MIC, vec![7u8; 120])]);
        let ack = e.upstream_feedback(2_000).expect("feedback after the frame");
        viewer.on_datagram(&ack, 3_000).expect("feedback for the mic stream");
        assert_eq!(viewer.stats().acked_frame, 1);
    }

    #[test]
    fn refusals_name_the_reason_and_register_nothing() {
        let mut e = engine();
        // Caps not negotiated: nothing opens.
        let mut off = Upstreams::new(Recorder::default(), &[caps::UP_MEDIA.into()]);
        assert_eq!(
            reason(off.on_control(&mut e, &open(StreamKind::UpAudio, MIC, "opus"), true)),
            "caps"
        );

        let mut up =
            Upstreams::new(Recorder { audio_only: true, ..Recorder::default() }, &negotiated());
        let cases = [
            (open(StreamKind::Video, 5, "h264"), "kind"),
            (open(StreamKind::Unknown, 5, "x"), "kind"),
            // Only a tile stream names a surface.
            (
                Control::StreamOpen {
                    stream: MIC,
                    kind: StreamKind::UpAudio,
                    codec: "opus".into(),
                    of: Some(0),
                },
                "kind",
            ),
            (open(StreamKind::UpAudio, MIC, "pcm"), "codec"),
            (open(StreamKind::UpVideo, CAMERA, "h264"), "unsupported"),
            // Stream 0 is the main display.
            (open(StreamKind::UpAudio, 0, "opus"), "in_use"),
        ];
        for (control, want) in cases {
            assert_eq!(reason(up.on_control(&mut e, &control, true)), want, "{control:?}");
        }
        assert_eq!(up.opened().count(), 0);
        assert!(up.sink().events.is_empty());
        // The engine kept no stream from a refusal: a later valid open succeeds.
        assert!(matches!(
            up.on_control(&mut e, &open(StreamKind::UpAudio, MIC, "opus"), true),
            Some(Control::StreamOpened { stream: MIC })
        ));
        assert_eq!(
            reason(up.on_control(&mut e, &open(StreamKind::UpAudio, MIC, "opus"), true)),
            "in_use"
        );
    }

    #[test]
    fn close_stops_delivery_and_session_end_closes_everything() {
        let mut e = engine();
        let mut up = Upstreams::new(Recorder::default(), &negotiated());
        up.on_control(&mut e, &open(StreamKind::UpAudio, MIC, "opus"), true);
        up.on_control(&mut e, &open(StreamKind::UpVideo, CAMERA, "h264"), true);
        assert_eq!(
            up.on_control(&mut e, &Control::StreamClose { stream: MIC }, true).map(|_| ()),
            None
        );
        // A closed stream's datagrams no longer register with the engine.
        let mut viewer = UpstreamSender::new(UpstreamConfig {
            stream: MIC,
            max_datagram: MAX_DATAGRAM_VPC,
            cc: CcConfig::default(),
            path: PathKind::DirectWan,
            fec: false,
        });
        for d in viewer.send_frame(&[1u8; 50], 0, true, 0).expect("packetize").expect("sent") {
            let out = e.on_datagram(&d, false, 1_000);
            assert!(out.upstream.is_empty());
            up.deliver(&out.upstream);
        }
        assert!(e.upstream_feedback(2_000).is_none());
        // Closing an unknown stream is a no-op.
        up.on_control(&mut e, &Control::StreamClose { stream: 77 }, true);
        assert_eq!(up.close_all(&mut e), vec![CAMERA]);
        assert_eq!(up.opened().count(), 0);
        assert_eq!(
            up.sink().events,
            vec!["open 100 UpAudio", "open 101 UpVideo", "close 100", "close 101"]
        );
        assert!(up.sink().frames.is_empty());
        // Both ids are free again in the engine.
        e.add_upstream(MIC).expect("mic id free");
        e.add_upstream(CAMERA).expect("camera id free");
    }

    #[test]
    fn a_view_only_viewer_cannot_open_a_microphone() {
        let mut e = engine();
        let mut up = Upstreams::new(Recorder::default(), &negotiated());
        let control = open(StreamKind::UpAudio, MIC, "opus");
        assert_eq!(reason(up.on_control(&mut e, &control, false)), "view_only");
        assert_eq!(up.opened().count(), 0);
        assert!(up.sink().events.is_empty());
        // Nothing was registered: the id opens once the viewer has control.
        assert!(matches!(
            up.on_control(&mut e, &control, true),
            Some(Control::StreamOpened { stream: MIC })
        ));
    }
}
