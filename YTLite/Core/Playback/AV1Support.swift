import Foundation
import VideoToolbox

/// AV1 decode capability — hardware (VideoToolbox) and software (dav1d).
/// YouTube serves 1440p+/4K only as VP9 or AV1; AVPlayer can never decode
/// VP9, and decodes AV1 solely in hardware (A17 Pro+, HLS support since iOS
/// 17.4). `av01` formats are admitted to the DASH ladder when either path is
/// available — elsewhere the ladder stays avc1-only and tops out at 1080p.
///
/// The software (dav1d) path is currently **debug-only** — there is no
/// shipped user-facing opt-in. Two independent Debug-section axes control
/// it, and with both off the app behaves byte-for-byte like it did before
/// any AV1 work: hardware devices play av01 through AVPlayer, everyone else
/// is avc1-only and capped at 1080p.
///
/// - Toggle A (`isForceSoftwareDecoder`, Settings → Debug → "Force Software
///   Decoder") is the master switch for the dav1d path. On a hardware-AV1
///   device it overrides the hardware route, forcing av01 through dav1d
///   instead — the only way to exercise the software decoder on modern
///   hardware. On a device without hardware AV1 it unlocks the >1080p
///   ladder, admitting av01 (1440p/2160p) via software.
/// - Toggle B (`isForceAV1LowRes`, Settings → Debug → "Force AV1 for
///   360–1080p") additionally lifts the height floor so av01 is admitted at
///   *every* height, not just above 1080p — for exercising the decoder at
///   resolutions weak hardware can actually sustain (an A7 measured
///   40.7 ms/frame at 1440p; 480p/720p should be fine). B depends on A: with
///   A off, B does nothing (baked into `isForceAV1LowRes` itself, not just
///   the Settings UI).
///
/// The three call sites below each read one property/method here instead of
/// re-deriving the hardware/master-switch/low-res-floor combination:
/// `isSupported` (quality-menu visibility), `isAV01Admitted(atHeight:)`
/// (per-format DASH ladder gate), and `isSoftwareDecodeRoute` (engine
/// routing).
enum AV1Support {
    /// AVPlayer / VideoToolbox hardware decode. A17 Pro+ only.
    static let isHardwareSupported: Bool = {
        guard #available(iOS 17.4, *) else {
            return false
        }
        return VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    }()

    /// dav1d is statically linked into every device build with no
    /// simulator slice (see `Dav1dShim.c` — stubbed there, returns NULL).
    /// This is the same cheap link-presence probe `CodecCapabilityProbe`
    /// logs at launch: it says nothing about whether a given chip can
    /// decode fast enough, only that the decoder exists in this binary.
    static let isSoftwareAvailable: Bool = {
        dav1d_shim_version() != nil
    }()

    /// Toggle A, effective value: the dav1d path is force-enabled. Requires
    /// dav1d to actually be linked in — see `isSoftwareAvailable`.
    static var isForceSoftwareDecoder: Bool {
        get {
            isSoftwareAvailable
                && UserDefaults.standard.bool(forKey: UserDefaultsKeys.Debug.softwareAV1Decoder)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.Debug.softwareAV1Decoder)
        }
    }

    /// Toggle B, effective value: the >1080p height floor is lifted so av01
    /// is admitted at every height. Dependent on Toggle A — reads as `false`
    /// whenever `isForceSoftwareDecoder` is `false`, regardless of the
    /// stored default, so B genuinely does nothing without A.
    static var isForceAV1LowRes: Bool {
        get {
            isForceSoftwareDecoder
                && UserDefaults.standard.bool(forKey: UserDefaultsKeys.Debug.forceAV1LowRes)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.Debug.forceAV1LowRes)
        }
    }

    /// Whether *some* av01 tier is reachable at all — drives quality-menu
    /// visibility (`VideoQualityStore.options`), not per-format admission.
    /// See `isAV01Admitted(atHeight:)` for the actual per-format ladder gate.
    static var isSupported: Bool {
        isHardwareSupported || isForceSoftwareDecoder
    }

    /// Which engine decodes an admitted av01 format (used by
    /// `AndroidVRSource+SampleBuffer.shouldUseSampleBuffer`): `true` routes
    /// through the software sample-buffer/dav1d engine, `false` through the
    /// cheaper, device-verified generated-HLS/AVPlayer (hardware) path.
    /// Toggle A forces the software route even on hardware-AV1 devices;
    /// otherwise hardware devices keep the AVPlayer route and non-hardware
    /// devices (only reachable here when av01 was admitted at all, i.e. A
    /// was on) take the software route.
    static var isSoftwareDecodeRoute: Bool {
        isForceSoftwareDecoder || (isSoftwareAvailable && !isHardwareSupported)
    }

    /// The per-format DASH ladder gate for av01 (used by
    /// `fmtIsPlayableVideo`). Hardware devices admit av01 at every height,
    /// same as shipped behavior, regardless of `allowsSoftwareAV1` — hardware
    /// decode never touches dav1d, so it's fine for any client. On the
    /// software-only path av01 is admitted only above 1080p — avc1 already
    /// covers 1080p in hardware, so software decode (battery/heat cost) must
    /// never be picked at a resolution hardware already reaches — unless
    /// Toggle B lifts that floor.
    ///
    /// `allowsSoftwareAV1` gates the *software* branch only: only the client
    /// that actually has a sample-buffer/dav1d route (android_vr — see
    /// `AndroidVRSource+SampleBuffer`) may admit av01 via software. Other
    /// clients (e.g. mweb, whose build path is generated-HLS → AVPlayer with
    /// no software-decode route) must never see av01 admitted unless
    /// hardware can decode it — AVPlayer has no dav1d fallback and would show
    /// a black screen. Defaults to `true` for callers that don't (yet) know
    /// their client, preserving prior behavior.
    static func isAV01Admitted(atHeight height: Int, allowsSoftwareAV1: Bool = true) -> Bool {
        isHardwareSupported
            || (allowsSoftwareAV1
                && isForceSoftwareDecoder
                && (height > 1_080 || isForceAV1LowRes))
    }

    /// Same gate for an HDR (PQ/HLG) av01 format, which has an extra
    /// restriction: **hardware decode cannot play it here.** Measured on an
    /// A18 Pro — an HDR variant tagged `VIDEO-RANGE=PQ` is refused with
    /// `NSURLErrorUnsupportedURL` before a single byte is fetched, because
    /// AVFoundation's HDR path won't take our `ytv-hls://` custom scheme
    /// through `AVAssetResourceLoader`; drop the tag and it reads the
    /// playlists, then rejects the PQ content as mis-declared (-12927). SDR
    /// av01 over the same generated HLS plays fine, so it is the HDR pipeline
    /// specifically. Serving the playlists from a local HTTP server would
    /// lift this; until then an HDR rung is only offered when the software
    /// (dav1d) engine will be the one playing it — where HDR is
    /// device-verified working.
    static func isHDRAV01Admitted(atHeight height: Int, allowsSoftwareAV1: Bool = true) -> Bool {
        isAV01Admitted(atHeight: height, allowsSoftwareAV1: allowsSoftwareAV1)
            && isSoftwareDecodeRoute
    }
}
