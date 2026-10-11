import Foundation
import AVFoundation
#if os(tvOS)
import SpatialAudioBridge
import SpatialAudioPlayback
#endif

/// A TrueHD Atmos or DTS:X track playing as APAC, as the view model holds it
/// on every system (the stream itself needs tvOS 26).
@MainActor
protocol SpatialAudioPlaying: AnyObject {
    /// The loopback playlist to play in place of the server's.
    var playlistURL: URL { get }
    /// The media source and track it plays, as `refusedSpatialAudio` records them.
    var trackKey: String { get }
    /// Keeps the receiver in Dolby Atmos while `player` plays the stream.
    func attach(to player: AVPlayer)
    /// Stops the conversion, the loopback server and the Atmos output.
    func stop()
}

extension PlayerViewModel {
    /// After a seek AVPlayer waited up to 15 s for spatial audio on titles
    /// with long keyframe intervals, so the stall watchdog allows this long.
    static let spatialAudioStallGrace: Double = 20

    /// Starts SpatialAudioBridge for the selected audio stream when it is
    /// TrueHD Atmos or DTS:X (`PlaybackSelection.spatialAudioTrackPosition`).
    ///
    /// Nil keeps the server's audio: an ineligible track, a system below
    /// tvOS 26, or a track the library refused, which then keeps the server's
    /// audio for the rest of the session. iOS is left out: AirPlay hands the
    /// item's URL to the receiver, which cannot reach this device's loopback
    /// server (the same reason as `pinnedPlaylistLoader`).
    func startSpatialAudio(
        for item: BaseItemDto,
        mediaSource: MediaSourceInfo,
        tracks: StreamTrackRequest,
        startTicks: Int64
    ) async -> (any SpatialAudioPlaying)? {
        #if os(tvOS)
        guard #available(tvOS 26, *),
              let position = PlaybackSelection.spatialAudioTrackPosition(in: mediaSource, tracks: tracks),
              case let trackKey = "\(mediaSource.id)/\(position)",
              !refusedSpatialAudio.contains(trackKey),
              let transcodingPath = mediaSource.transcodingUrl,
              let videoPlaylist = await client.buildURL(path: transcodingPath),
              let file = await client.staticStreamRequest(itemId: item.id, mediaSourceId: mediaSource.id)
        else { return nil }

        let started = ContinuousClock.now
        do {
            try AtmosOutputActivator.configureAudioSession()
            let matroska = try await MatroskaFile.open(HTTPByteSource(url: file.url, headers: file.headers))
            let embedded = mediaSource.audioStreams.filter { $0.isExternal != true }
            let codec: SpatialAudioCodec = embedded[position].codec?.lowercased() == "dts" ? .dtsX : .trueHDAtmos
            guard matroska.audioTracks.count == embedded.count, matroska.audioTracks[position].codec == codec else {
                throw SpatialAudioError.source("The file's audio tracks do not match the server's")
            }

            var options = APACStream.Options()
            // Only the stream copy: AVPlayer switches to the server's
            // re-encodes when a segment is slow, as it did before the pin (#443).
            options.includesVideoVariant = { !HLSMultivariantPlaylist.isStreamCopyFallback($0.absoluteString) }
            // Converts the segment at the start before returning, so a track
            // the library cannot play throws here, before the player exists.
            let stream = try await APACStream.start(
                file: matroska,
                track: matroska.audioTracks[position],
                videoMaster: videoPlaylist,
                startTime: CMTime(value: startTicks / 10000, timescale: 1000),
                options: options
            )
            // Always set with a video playlist; `start` throws when no variant remains.
            guard let playlistURL = stream.masterPlaylistURL else {
                await stream.stop()
                throw SpatialAudioError.source("The stream has no video")
            }
            noteLoadProgress()
            diag(.streamSelected, [
                PlayerDiagnostics.field("spatialAudio", "apac"),
                PlayerDiagnostics.field("audioTrack", position),
                PlayerDiagnostics.field("startSeconds", (ContinuousClock.now - started) / .seconds(1))
            ])
            return SpatialAudioStream(stream: stream, playlistURL: playlistURL, trackKey: trackKey)
        } catch {
            guard !Task.isCancelled else { return nil }
            refusedSpatialAudio.insert(trackKey)
            diagFailure(.streamSelected, [
                PlayerDiagnostics.field("spatialAudio", "refused"),
                PlayerDiagnostics.field("audioTrack", position),
                PlayerDiagnostics.field("reason", String(describing: error))
            ])
            return nil
        }
        #else
        return nil
        #endif
    }
}

#if os(tvOS)
/// The APAC stream and the activator that keeps the HDMI output in Dolby
/// Atmos while it plays. The stream serves the server's video playlist from a
/// loopback address with the APAC rendition as its only audio.
@available(tvOS 26, *)
@MainActor
private final class SpatialAudioStream: SpatialAudioPlaying {
    let playlistURL: URL
    let trackKey: String
    private let stream: APACStream
    private let atmos = AtmosOutputActivator()

    init(stream: APACStream, playlistURL: URL, trackKey: String) {
        self.stream = stream
        self.playlistURL = playlistURL
        self.trackKey = trackKey
    }

    func attach(to player: AVPlayer) {
        // The playlist offers only the APAC rendition, so every item plays it.
        atmos.attach(to: player)
    }

    func stop() {
        atmos.detach()
        Task { [stream] in await stream.stop() }
    }
}
#endif
