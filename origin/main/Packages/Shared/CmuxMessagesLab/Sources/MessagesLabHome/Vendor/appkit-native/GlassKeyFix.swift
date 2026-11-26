import AppKit

/// Real Messages' compose glass in a key window (macOS 27, dark) is brighter at its top and bottom rims and
/// darker at its end caps' sides than AppKit's NSGlassEffectView with the same frame and corner radius (still
/// gate nosb-active against two lossless takes, 2026-10-13, cx-3cb compose-parity): top rim row +12 levels
/// (109 -> 121), the next +7, the next 12 rows +1 to +2, the caps' sides -4 to -7 in both takes; the bottom
/// rim +5 / +8 in deactivate-activate (the gate scene's window) and +8 / +13 in appearance-light (a 940 pt
/// window, other rows behind the glass); the lower half -1 in one take and 0 in the other; the round buttons
/// the same at their rims (+11 at the top). No style or private key of the system glass gives Messages'
/// profile (compose-parity sweeps: `_variant` 0-30, `_subduedState`, `_scrimState`, `_contentLensing`,
/// `_interactionState`, `_adaptiveAppearance`, `_tintOpacityReduced`, `_useReducedShadowRadius`,
/// `_inverseMeshed`: none closer than the default).
///
/// So a fixed function of the glass's shape (sampled per device pixel at 2x; it never reads what is behind
/// the glass) is laid over it: only the difference both takes agree on (the same sign, the smaller step;
/// else nothing), so over either backdrop no pixel moves away from Messages. The field's caret, placeholder
/// and waveform columns take the glass's own value of that row. It is white (lighter) or black (darker)
/// at the alpha that gives the step over our glass, in a view above both glass containers (a container
/// tones its content). A layer `compositingFilter` (plusL) is not applied in this window (the placeholder
/// test drew it as a plain over-blend), so it is an over-blend.
///
/// Only where it was measured: a key window, dark appearance, 2x, macOS 27. Light appearance, a 1x
/// display, macOS 26 and 14-15, and an inactive window get the system glass alone (the inactive glass, flat
/// 50, already matches; light and macOS 26 have no lossless key reference of the field).
/// `--no-glass-key-fix`: off.
final class GlassKeyFix {
    static let on = !ProcessInfo.processInfo.arguments.contains("--no-glass-key-fix")

    /// One glass shape's correction: a white and a black layer over it.
    final class Part {
        let white = CALayer(), black = CALayer()
        var layers: [CALayer] { [black, white] }
        /// MAP: raw deflate of little-endian UInt16 alphas (/65535), W x H px at 2x: the white map's rows
        /// (top-down), then the black map's. STRETCH: the image rows and the column that stretch (the field).
        init(_ map: String, w: Int, h: Int, stretch: (rows: ClosedRange<Int>, column: Int)? = nil) {
            for l in layers {
                l.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "opacity": NSNull(), "contents": NSNull()]
                l.contentsScale = 2
                l.contentsGravity = .resize
                l.magnificationFilter = .nearest
                l.minificationFilter = .nearest
                l.isHidden = true
            }
            guard let (wi, bi) = GlassKeyFix.images(map, w: w, h: h) else { return }
            white.contents = wi; black.contents = bi
            if let s = stretch {
                // The stretch rows are symmetric about the middle row, so the contents' y origin does not matter.
                let cc = CGRect(x: CGFloat(s.column) / CGFloat(w), y: CGFloat(h - 1 - s.rows.upperBound) / CGFloat(h),
                                width: 1 / CGFloat(w), height: CGFloat(s.rows.count) / CGFloat(h))
                for l in layers { l.contentsCenter = cc }
            }
        }
        var ready: Bool { white.contents != nil }
        func place(_ f: CGRect) { for l in layers where l.frame != f { l.frame = f } }
        func show(_ on: Bool) { for l in layers where l.isHidden == on { l.isHidden = !on } }
    }

    /// Field: 61 x 62 px (31 pt high): the left cap (30 px), one middle column, the right cap (30 px); the
    /// rows 28-33 (the caps' straight sides, the glass's even middle) stretch for a taller field.
    let field = Part("7ZjBa1NJHMff7/dm8iZpDEVcbTZYVkSLYAMJioHFoCFUIrKEkiAlvFJNc4lL8OBNsSB72KMUegnsEqVQFxFKQSFIDoEVevDQQg926aH+AXUv6yks7ExeQ17SJG3avHm4fd8hmZffzPw+85s3b2ZeFKVfXYI8zuFn9aXL891L12d1DvN4CRQLdQ0u0xi77nnu/eB741vwPfW99zzl+RvfB99z73VPjF2m1wbcgytwiy6wHc97T9Hjdm+wdVqly3Sc/InjZJlfr9MN5nYXefmOZ4HdolcGwo/AA/qF1VhGEywdyijSNFSwwnPxPb1r00H0I6PV2Bf2gEaORA9CTb3jSWqvaBWnwEgruIIZaE/C2qhRxVc0qd3x1NTgIelPsEQntAiPM8093AVzMhjN3JwUJQ06RMiEVqJPsH/ulprk41vebZkGcxIWwVhCg9SpXFHKuMxj31L7oY7BV7VKV+vUFDRTo7xBSLWx9tZexSr9qo7BQbk1dZlWcBImW1qYvaZgEY1PezK3EB4qPPLagdgXuL8oeYuNlu18s71zaXvLt9zfIl7Yhz0KW2qEZKCTnxKKj5Eav5rWXr3J8Pm2pY72ZM9huM5NttVKQmsqYefrTj6FNQNhMtdjnod4uQ7N+p2pZk4n216ukM59h7pG/ZqvSK2tfsPusSjKT13sRv32dhV8jd1WjiqmLdxz0nx167yyBMiUpXudokxBgOy1PsMyKparjM/aKOdhBhQpmoHzLaQfJXHbWf76/iKHKzh+MN97WRFPShxdR62zyx7uaZvIp22cacNwvLj2agjs4tpHPo73+Tg+VfatnvbtGGdtIp91ziaOJGka7OLcBF0CW4ebYE/UlY7vq1GooNXcaJfoltDKEddhqWtkIRgn1pHHe/xDoyg3YNWiEV/FGz3HcxQS8NEC9kdMwOi+dzIJazjI9+kp7i95IH8X+UyIkkHNNR2iZAkvHthbCW+T+wNg34fbpNTn3UuATqJ7/nvtRxkerU4ScLh5cZccdr4dpa3QIuZ5v9ewv5V1DXWSJ4tHfkZW8CH5h2bJBs7uw5+FnyHL6z4kKwN7MpNQgKuuEdev2r/0L/oItvFTvR+z8Am38RHkyS9knoy4rroKkLRkBZ6BHXxHxljZ/Ye76P5dO8G+59dj7B3ZwRlpp8kU/H0i5ZxdHTly5MiRI0eOvhkNm97Rk5pcdpOXpnLJTV6ODROZo51jxtWme9vy0Y63RLatbbpF/sKneK2PtIXt5UzxpnwyxmSQm+wYS5wU+eNTDXKcWEtu+I+xx6dEXgjIirlJLgREHvSHidURt7JjLOgX+b0RQY4TeXGHyb2RusEG8nx9tOcDYWKeeVaT46RBFqMtm2yMdtCfY3LIDXZud4YVAllvXNK6bZCz3okz4lfRL59crMe8dkYe2WBnvcbq+cIXkkwO7e4Ym+71obBEcpisDxm7pDgZnJNI/oHlmOl0IpGskOZpyL4ToKKck3gOk8naV+R/wnDkyJEjR44cfYP6Dw==", w: 61, h: 62, stretch: (rows: 28...33, column: 30))
    /// Round buttons: 62 x 60 px, the 30 pt glass and its dark outline's column on each side.
    let plus = Part("7ZlLaBtHGMf1fTuzs7taPxDUTYgxDUH1pY6xLnmBG5cQqjpWRZBihKtCfUhID2nTm2kgOIdQ2ktTU1Mf3Oog4oKpMaaC2MaHhJTa4EMpPpleamgvISEX91DRpjNeb3bXektr6dD5/3HWu9mZ33zjeezMBAK1qB/uYpK+UC8ZV8xY5/3Q/VCs84p5yXihJuld7IfAoeganqHd7KlxtT1r/mtcNzeNTWOVW1yv8ydZ82r7U6ObnaHX0E/uijJJTXPV0PUt7SEdJMfJY/T6OBkkD+mWpuurhmlO0hXFD+4E7qhh/SbboBGSwzSkYRmLW/xfDiNkg95kYX1HnWgo/n5I0mfaipahC2h76aXHwLLzJAW2MzTOnmlJWm8LuIWcqX1D5zAJ81jJo+B2IJCE0+Qiy9RR+ydgGle0EMvt1VsC3J5D8SP+te6s38TVchKERbplXOTxT+OJGqLvhefKA/qYcy+D7WrTinJkMbtfskBgHQfYedoL1ZLzyvd0GeOe951SVLbzvriu8ejzSjX0ME9xmiztt9E4CNfTWqyUmb0IcjhIshiukE8PTPFekoJi+dRmb+oxHs9vSk9Z+nno2yPHfB0dYxDjPTFCbpft8eu4hE4Kf7j2VYw7A1C6jS7jwfKWi8V2uXfc911krkTkg/A+VKJUW5ri7yXgGLlVlJ4+pBnQrQVcK8IeOkAeAa+tZ43Tc3ingD4GXm4h3SlDI0pAJ6nuzcPgL+A58I4e5UdsfyPPYvF+WJnfKDvOZ+T6Uo740hvctR5rQv9yR15PBCPgF711dS7VGnW07K8XbWm7Ce7Th2EYWsm23Pz4HXaz6EPQAYXsZsfuZTeX3jr2NI5AJbofM3fhXBKCX5Xmst1z6Cn+NT1clu5v1O5vh16+XpzBSmz/5u6kK6ej8JE6i82KPMEjdd9/pzxXmsUehbOenC7gDI+89BjjX50nIHfgK/UVSLG8Ei0TuV/0MShcE32o7LIsTuFhs7uKrojeZj/yei+k22uCGRRuZA0cCKxh8TXwm/iIzatRcOjTKEa8g3nXsvY/uMqeK7ki+YH8bARI9CXZW8+VWeWVgr6yK9A4+1TPK1Noc/2hixxGYb1Efds6i5+xU1pe8bId5ixarn6Hy+7TmxiFngplvoAL7C0tRi261bpiULjbVtuK+xfMVLWrGsU2fVF/j1pU2+6oMmi51H6mt72JXcVd5fUqS3tD+UsbCH5CnTqeLbG7WnmWHocHNIO9NdTTEN5jHwRTGiVOnKX3bUtpiUecJvX0iSPqH8auvqMKqtiVtvelCy1GaWe8tp5c5q1rlGzWfW5xRzmqj7d/rT1RnX35YucE9jNr1174Hk2TJzQJJxsahbfJDX2wbUXrZpN7pyYp1/mI1+KcZAF7yTvkY/IFOUbO+TLv/UnG9Z+Cfwd/114zQixCusgaet1FImSRXmT/0COqqq7hhK9nZF8pb9CUNmB+aYpzuVVj3gjrr3KH9Xl+966+zT7XH7Et3i8jh/SFfRJu467SR7ZpWB8NdnRMtG3o37Jtuo6Fu6JSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJS/1/9Bw==", w: 62, h: 60)
    let emoji = Part("7ZlPSFxHHMd3fjOz78++qJF026AIIWz30ijupdFQa0oItbrbJezGSJpCc0hIhZT0lkYQPYSUHoqVSlOwvMOCB6mIsIeseLCkNIJQKDmJl7U0lyXgZXPoQu08Xyfvj/vcP75de5jv97Csvt983m92/k8gUIt60ENI073giHpV2z157dS1U7snr2oj6l4wTR9CDwo0RLehj3ZKL9VbLRntH/WOtqluqqvMxucd9peMdqvlpdop9dHb4Cc3h6eopq2qivJcXqcD5Ax5CnafIV9RnUal99QHaq+maVM0h/3g3oedYES5J23QGMnCDXQDPQGn24jpLGQhRGZor5SXf1R3gvePlH8PStNxNSnpdAxxrwA3JW4vAfdeMCePq2labwvIYZ1els6TNIsfRaYXoTqn0QL8QJdkvY7aP4vmICkt0yf79WaUVKtTKIXaSLuUk+fgbA3ZR9Eg+9WeMW4KZcC0UVa15jEZuIKi5Ht5kEZRteQSXqZrLM6yVVp1tiJ1CLPsS7gaeoRxBlibTaIkizNtf4tqzWONckJEp7s4UoHehbbxeXIdJW3mpdRqexkrrOVt465D6ZMQIyuQQPOOyHK2Yio9mWSlJRh9hk4e0uN7UYyESAIZnofyfO9oL65BNrw/7njGl3D4P3J5fuXW4sU1HSYlj94+AR0khRIuG/Gmq+slL7Dlx2A5gR6zftpBJqBcz1pjY2ECebmWkcnOdHqJ9biDzz/FWTgqsxp6FqbB3avbyAIcnVmZXmQ5Op+8gKz6DgQSvqw/4sir3vsd5WfAyNrvtU4cleMXse7IfBF0CAQawT5IL+AFsNd4qkGrPJPu5l9B9ieSDWKXp8/D8GteI+rbzbbT5xvQtqqnx5vOtujHwY6zdWAe57HJbkXNY88BN897qAl0i2pnh5pQ826y4eNmN0Ne7FZ0ETWfPYyOL+vjZXej42LPAt+lWLOYMQKYn41kx1Eeu+dQzm0keXh/VP0DtyO+dnCS/aQ7uabn4V1b+enXmfvLdlMN53GfYz+uQwq55xw/c+bcWdbKCviL4Glb6f1oFPHfnr+BXzOIPWeDPUh/d+1NspABe5x/c5eTXMAF6ZJrNJ+G68g55x51zi5HnoUEHZPeOFB2eP80yw+6N7mIi9LnuNwe2L1HNOm17s+M9ZixLjrIZvto+UOpfNQCOPdp8Tr2hOabmutBi25mvRhEyvueM/fXdAnqb298N8nXombdc3KA/Kb+TLyjJyBKRtFRuCbbuTbdxrNQwg+UpHT4GdcQOkdGkbtcr1OccjbPOpyr0xJ+pDyS+qHSSaoOMcJrvnwrq3Se5f7NE/QD+ZV8qYo12tuI7ZBp1rVnMsq1nxd6nee5z5by+BO6rJxQhqpcHUYZoVNaB3uG/H/ep5hWjdhr/0vaG3ol363pJPtb2KA6XYHDeM5TW2edGO+QpmPyZ6EZ6WIdK+JNWKfniJFRbSfXxhvpsBMsKn+pbwXrGxu7URoV6AadoWnEzW8G+E0Cv00o4RK2Tu4LjHuz5bQyfaQ7mwuog3xD/qQfkShr/c4bE+fdiXlTMkUn5Jw8cOKuskX8uStagwlpVronXZaWaYyEyRpYDrPv46xu2qUleUT9O/Rr6KbywhcuV4z1l+fwi9QW+lT5WFlVF9WI8iZzROnSVvfv57SWXm1Mfod+hwMN1DPYoj9JG0or02goomyxFlnEk9DdpN2GkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQ0P9d/wI=", w: 62, h: 60)
    var parts: [Part] { [field, plus, emoji] }
    var layers: [CALayer] { parts.flatMap(\.layers) }

    /// The white and black over-blend images (premultiplied, 16 bits per component) of a map.
    static func images(_ b64: String, w: Int, h: Int) -> (CGImage, CGImage)? {
        guard let z = Data(base64Encoded: b64), let raw = try? (z as NSData).decompressed(using: .zlib) as Data,
              raw.count == w * h * 2 * 2 else { return nil }
        let a: [UInt16] = raw.withUnsafeBytes { b in (0..<(w * h * 2)).map { UInt16(littleEndian: b.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self)) } }
        // cmux: built by appending, no index subscripts (crash ratchet): the white map's alphas are its RGBA,
        // the black map's are its alpha over zero colour.
        let n = w * h
        var wp: [UInt16] = [], bp: [UInt16] = []
        wp.reserveCapacity(n * 4); bp.reserveCapacity(n * 4)
        for wa in a.prefix(n) { wp.append(wa); wp.append(wa); wp.append(wa); wp.append(wa) }
        for ba in a.dropFirst(n).prefix(n) { bp.append(0); bp.append(0); bp.append(0); bp.append(ba) }
        func make(_ p: [UInt16]) -> CGImage? {
            let d = p.withUnsafeBufferPointer { Data(buffer: $0) }
            guard let prov = CGDataProvider(data: d as CFData) else { return nil }
            return CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8,
                           space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                           provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        guard let wi = make(wp), let bi = make(bp) else { return nil }
        return (wi, bi)
    }

    /// Shown only where it was measured.
    @MainActor func update(window: NSWindow?) {
        var show = false
        if Self.on, field.ready, let w = window, #available(macOS 27.0, *) {
            let dark = w.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            show = w.isKeyWindow && dark && w.backingScaleFactor == 2
        }
        for p in parts { p.show(show) }
    }
}
