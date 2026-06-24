import AVFoundation
import Foundation

struct TechnicalInfo {
    var codec: String
    var container: String   // file extension, e.g. WAV / MP3 / FLAC
    var sampleRate: Double
    var bitDepth: Int       // 0 for lossy formats (bit depth not meaningful)
    var channels: Int
    var bitrate: Int        // bits per second
    var fileSize: Int64

    var sampleRateLabel: String {
        sampleRate > 0 ? String(format: "%.1f kHz", sampleRate / 1000) : "—"
    }

    /// Trims a whole-number kHz (192 kHz) but keeps fractional ones (44.1 kHz).
    var sampleRateShort: String {
        guard sampleRate > 0 else { return "" }
        let khz = sampleRate / 1000
        return khz == khz.rounded() ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz)
    }

    /// Lossless/PCM → "24-bit / 192 kHz"; lossy → "320 kbps / 44.1 kHz".
    var qualityLabel: String {
        var parts: [String] = []
        if bitDepth > 0 { parts.append("\(bitDepth)-bit") }
        else if bitrate > 0 { parts.append("\(bitrate / 1000) kbps") }
        if !sampleRateShort.isEmpty { parts.append(sampleRateShort) }
        return parts.joined(separator: " / ")
    }

    var bitrateLabel: String {
        bitrate > 0 ? "\(bitrate / 1000) kbps" : "—"
    }

    var bitDepthLabel: String {
        bitDepth > 0 ? "\(bitDepth)-bit" : "—"
    }

    var channelsLabel: String {
        switch channels {
        case 0: return "—"
        case 1: return "Mono"
        case 2: return "Stereo"
        default: return "\(channels) channels"
        }
    }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

struct TagEdit {
    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var genre: String
    var year: Int?
    var trackNumber: Int? = nil
    var trackTotal: Int? = nil
    var discNumber: Int? = nil
    var discTotal: Int? = nil
    var composer: String = ""
    var showComposer: Bool = false
    var grouping: String = ""
    var compilation: Bool = false
    var rating: Int = 0
    var bpm: Int? = nil
    var comments: String = ""
}

enum MetadataService {
    static func technicalInfo(for track: Track) async -> TechnicalInfo {
        let url = track.url
        let container = url.pathExtension.uppercased()
        var codec = container
        var sampleRate = 0.0
        var channels = 0
        var bitrate = 0
        var bitDepth = 0

        let asset = AVURLAsset(url: url)
        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first {
            if let descriptions = try? await audioTrack.load(.formatDescriptions),
               let desc = descriptions.first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                sampleRate = asbd.mSampleRate
                channels = Int(asbd.mChannelsPerFrame)
                codec = codecName(asbd.mFormatID) ?? codec
                // mBitsPerChannel is set for PCM/lossless, 0 for lossy codecs.
                bitDepth = Int(asbd.mBitsPerChannel)
            }
            if let rate = try? await audioTrack.load(.estimatedDataRate), rate > 0 {
                bitrate = Int(rate)
            }
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
        if bitrate == 0, size > 0, track.duration > 0 {
            bitrate = Int(Double(size) * 8 / track.duration)
        }
        return TechnicalInfo(codec: codec, container: container, sampleRate: sampleRate,
                             bitDepth: bitDepth, channels: channels, bitrate: bitrate, fileSize: size)
    }

    private static func codecName(_ formatID: AudioFormatID) -> String? {
        switch formatID {
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatMPEG4AAC: return "AAC"
        case kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: return "AAC (HE)"
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatAppleLossless: return "ALAC (Lossless)"
        case kAudioFormatLinearPCM: return "PCM"
        case kAudioFormatOpus: return "Opus"
        case kAudioFormatAC3: return "AC-3"
        case kAudioFormatEnhancedAC3: return "E-AC-3"
        case kAudioFormatAMR: return "AMR"
        default: return nil
        }
    }

    // MARK: Tag writing

    /// AVFoundation can only author metadata into MPEG-4 family containers.
    /// MP3/FLAC/WAV tag writing needs a third-party tagging library (TagLib);
    /// for those, edits apply to the Mute library only.
    static func canWriteTags(_ url: URL) -> Bool {
        ["m4a", "m4b", "mp4", "aac"].contains(url.pathExtension.lowercased())
    }

    enum TagWriteError: LocalizedError {
        case unsupported, exportFailed

        var errorDescription: String? {
            switch self {
            case .unsupported: return "This file format doesn't support tag writing via macOS APIs."
            case .exportFailed: return "Rewriting the file failed."
            }
        }
    }

    /// Rewrites the file (passthrough — audio untouched) with updated tags,
    /// preserving any existing metadata we don't edit (notably artwork).
    static func writeTags(_ edit: TagEdit, to url: URL) async throws {
        guard canWriteTags(url) else { throw TagWriteError.unsupported }
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw TagWriteError.exportFailed
        }

        func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMutableMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            return item
        }

        var newItems: [AVMutableMetadataItem] = [
            item(.iTunesMetadataSongName, edit.title),
            item(.iTunesMetadataArtist, edit.artist),
            item(.iTunesMetadataAlbum, edit.album),
        ]
        if !edit.albumArtist.isEmpty { newItems.append(item(.iTunesMetadataAlbumArtist, edit.albumArtist)) }
        if !edit.genre.isEmpty { newItems.append(item(.iTunesMetadataUserGenre, edit.genre)) }
        if let year = edit.year { newItems.append(item(.iTunesMetadataReleaseDate, String(year))) }
        if !edit.composer.isEmpty { newItems.append(item(.iTunesMetadataComposer, edit.composer)) }
        if !edit.grouping.isEmpty { newItems.append(item(.iTunesMetadataGrouping, edit.grouping)) }
        if !edit.comments.isEmpty { newItems.append(item(.iTunesMetadataUserComment, edit.comments)) }
        if let bpm = edit.bpm { newItems.append(item(.iTunesMetadataBeatsPerMin, String(bpm))) }
        // Track/disc numbers and rating live in the Mute library (which
        // drives album ordering); they aren't round-tripped into the file's
        // binary trkn/disk atoms, which AVAssetExportSession can't reliably emit.

        let overridden = Set(newItems.compactMap(\.identifier))
        let existing = (try? await asset.load(.metadata)) ?? []
        let kept = existing.filter { metadataItem in
            guard let id = metadataItem.identifier else { return true }
            return !overridden.contains(id)
        }
        session.metadata = kept + newItems

        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
        do {
            try await session.export(to: temp, as: .m4a)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw TagWriteError.exportFailed
        }
    }
}
