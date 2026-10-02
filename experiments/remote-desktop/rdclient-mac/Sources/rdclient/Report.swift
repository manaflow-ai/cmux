import Foundation

/// Builds the one-JSON-per-run report for `connect`.
func buildConnectReport(_ o: ConnectOptions, session: Session, window: (UInt64, UInt64), cpu: [String: Any],
                        connectMs: Double, losses: Int, sent: Int, sockKind: String,
                        utcStart: String, hello: [String: Any]) -> [String: Any] {
    session.withLock {
        let (w0, w1) = window
        let winSec = Double(w1 - w0) / 1e9
        let inWin = session.frames.filter { $0.tRecvNs >= w0 && $0.tRecvNs <= w1 }
        let bytes = inWin.reduce(0) { $0 + $1.bytes }
        let idlePongs = session.pongs.filter { !$0.underLoad }
        let loadPongs = session.pongs.filter { $0.underLoad }

        // Host clock offset (host - client) from the lowest-RTT idle ping, NTP style.
        var offsetNs: Double?
        if let best = (idlePongs.isEmpty ? loadPongs : idlePongs).min(by: { $0.rttMs < $1.rttMs }) {
            let mid = (Double(best.tSendNs) + Double(best.tRecvNs)) / 2
            offsetNs = Double(best.tHostNs) - mid
        }
        func hostToClientMs(_ hostNs: UInt64, minus clientNs: UInt64) -> Double? {
            guard let off = offsetNs, hostNs != 0 else { return nil }
            return (Double(hostNs) - off - Double(clientNs)) / 1e6
        }
        func clientMinusHostMs(_ clientNs: UInt64, _ hostNs: UInt64) -> Double? {
            guard let off = offsetNs, hostNs != 0 else { return nil }
            return (Double(clientNs) - (Double(hostNs) - off)) / 1e6
        }

        let s = session.samples
        let g2g = s.map { ms($0.t0Ns, $0.tDecodedNs) }
        let breakdown: [String: Any] = [
            "input_to_host_damage_est_ms": percentiles(s.compactMap { hostToClientMs($0.header.tDamageNs, minus: $0.t0Ns) }),
            "host_damage_to_capture_ms": percentiles(s.filter { $0.header.tDamageNs != 0 }.map { ms($0.header.tDamageNs, $0.header.tCaptureNs) }),
            "host_capture_to_encoded_ms": percentiles(s.map { ms($0.header.tCaptureNs, $0.header.tEncodedNs) }),
            "host_encoded_to_client_recv_est_ms": percentiles(s.compactMap { clientMinusHostMs($0.tRecvNs, $0.header.tEncodedNs) }),
            "client_recv_to_decoded_ms": percentiles(s.map { ms($0.tRecvNs, $0.tDecodedNs) }),
            "input_to_client_recv_ms": percentiles(s.map { ms($0.t0Ns, $0.tRecvNs) }),
            "matched_frame_bytes": percentiles(s.map { Double($0.frameBytes) }),
            "note": "est = uses the host clock offset from the lowest-RTT ping; error is up to half that RTT",
        ]

        var hostStatMedians: [String: Any] = [:]
        let statsInWin = session.hostStats.filter { $0.0 >= w0 && $0.0 <= w1 }.map { $0.1 }
        let keys = Set(statsInWin.flatMap { $0.keys })
        for k in keys.sorted() {
            let vals = statsInWin.compactMap { ($0[k] as? NSNumber)?.doubleValue }
            if let m = median(vals) { hostStatMedians[k] = round3(m) }
        }

        let interarrival: [Double] = zip(inWin.dropFirst(), inWin).map { ms($0.1.tRecvNs, $0.0.tRecvNs) }
        var report: [String: Any] = [
            "tool": "rdclient-mac connect",
            "label": o.label ?? "\(o.workload)-\(o.capture)-\(o.width)x\(o.height)",
            "utc_start": utcStart, "utc_end": utcNow(),
            "client_machine": machineInfo(),
            "path": ["addr": o.addr, "socket": sockKind, "socks_unix": orNull(o.socksUnix)],
            "hello": hello,
            "hello_ack": orNull(session.helloAck),
            "connect_ms": round3(connectMs),
            "rtt_idle_ms": percentiles(idlePongs.map { $0.rttMs }),
            "rtt_under_load_ms": percentiles(loadPongs.map { $0.rttMs }),
            "host_clock_offset_ms_est": orNull(offsetNs.map { round3($0 / 1e6) }),
            "glass_to_glass_ms": percentiles(g2g),
            "glass_to_glass_definition": "INPUT sent -> VTDecompressionSession output of the first frame whose marker equals the expected counter (marker read included; display present not included)",
            "samples": ["requested": o.workload == "idle" ? 0 : o.samples, "sent": sent, "matched": s.count,
                        "lost_1000ms": losses, "late_after_loss": session.lateMatches],
            "breakdown": breakdown,
            "video_window": [
                "seconds": round3(winSec), "frames": inWin.count, "bytes": bytes,
                "fps": winSec > 0 ? round3(Double(inWin.count) / winSec) : 0,
                "kbit_per_s": winSec > 0 ? round3(Double(bytes) * 8 / winSec / 1000) : 0,
                "keyframes": inWin.filter { $0.keyframe }.count,
                "frame_bytes": percentiles(inWin.map { Double($0.bytes) }),
                "interarrival_ms": percentiles(interarrival),
            ],
            "decode_ms": percentiles(inWin.map { $0.decodeMs }),
            "marker_read_ms": percentiles(inWin.map { $0.markerReadMs }),
            "host_header_window": [
                "capture_to_encoded_ms": percentiles(inWin.map { ms($0.header.tCaptureNs, $0.header.tEncodedNs) }),
                "damage_to_capture_ms": percentiles(inWin.filter { $0.header.tDamageNs != 0 }.map { ms($0.header.tDamageNs, $0.header.tCaptureNs) }),
            ],
            "host_stats_median": hostStatMedians,
            "host_stats_count": statsInWin.count,
            "client_cpu": cpu,
            "decoder": [
                "hardware": orNull(session.decoderHardware),
                "require_hardware_honored": orNull(session.decoderRequireHonored),
                "pixel_format": o.pixelFormat == fourCC("420f") ? "420f" : "420v",
                "mode": "synchronous VTDecompressionSessionDecodeFrame, RealTime=true, 1xRealTimePlayback",
            ],
            "errors": [
                "decode_errors": session.decodeErrors, "guard_failures": session.guardFailures,
                "keyframe_requests": session.keyframeRequests,
                "reader_error": orNull(session.readerError), "bye": orNull(session.byeReason),
            ],
        ]
        report["frames_total_session"] = session.frames.count
        return report
    }
}
