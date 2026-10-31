import AVFoundation

/// What Jonah needs to know about an audio file on the Mac side: its tags for the
/// iPod database, and enough technical detail (bitrate, sample rate) to fill a song entry.
struct AudioTags: Sendable {
    var title = ""
    var artist = ""
    var album = ""
    var genre = ""
    var trackNumber = 0
    var year = 0
    var duration: TimeInterval = 0
    var bitrate = 0        // kbps
    var sampleRate = 0     // Hz
    var playable = false   // AVFoundation could open it as audio

    static func read(_ url: URL) async -> AudioTags {
        let asset = AVURLAsset(url: url)
        var t = AudioTags()
        let common = (try? await asset.load(.commonMetadata)) ?? []
        let all = (try? await asset.load(.metadata)) ?? []

        func string(_ items: [AVMetadataItem], _ ids: [AVMetadataIdentifier]) async -> String {
            for id in ids {
                if let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first,
                   let s = try? await item.load(.stringValue), !s.isEmpty { return s.trimmingCharacters(in: .whitespaces) }
            }
            return ""
        }
        // FLAC and Ogg keep their tags as Vorbis comments ("vorb/ARTIST"), which
        // AVFoundation lists in a format of their own rather than as common metadata.
        var vorbis: [String: String] = [:]
        for format in (try? await asset.load(.availableMetadataFormats)) ?? [] where format.rawValue.contains("vorbis") {
            for item in (try? await asset.loadMetadata(for: format)) ?? [] {
                guard let key = item.identifier?.rawValue.split(separator: "/").last?.uppercased(),
                      let value = try? await item.load(.stringValue), vorbis[key] == nil else { continue }
                vorbis[key] = value.trimmingCharacters(in: .whitespaces)
            }
        }
        func or(_ s: String, _ key: String) -> String { s.isEmpty ? vorbis[key] ?? "" : s }

        t.title = or(await string(common, [.commonIdentifierTitle]), "TITLE")
        t.artist = or(await string(common, [.commonIdentifierArtist]), "ARTIST")
        t.album = or(await string(common, [.commonIdentifierAlbumName]), "ALBUM")
        t.genre = or(await string(all, [.id3MetadataContentType, .iTunesMetadataUserGenre, .quickTimeMetadataGenre]), "GENRE")
        t.year = Int(or(await string(all, [.id3MetadataYear, .id3MetadataRecordingTime, .iTunesMetadataReleaseDate,
                                          .quickTimeMetadataYear]), "DATE").prefix(4)) ?? 0

        // ID3 writes "3/12"; iTunes stores track number as big-endian bytes 2–3 of a data atom.
        let trackText = or(await string(all, [.id3MetadataTrackNumber]), "TRACKNUMBER")
        t.trackNumber = Int(trackText.split(separator: "/").first ?? "") ?? 0
        if t.trackNumber == 0,
           let item = AVMetadataItem.metadataItems(from: all, filteredByIdentifier: .iTunesMetadataTrackNumber).first,
           let data = try? await item.load(.dataValue), data.count >= 4 {
            t.trackNumber = Int(data[data.startIndex + 2]) << 8 | Int(data[data.startIndex + 3])
        }

        let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        t.duration = seconds.isFinite ? seconds : 0
        if let track = try? await asset.loadTracks(withMediaType: .audio).first {
            t.playable = true
            t.bitrate = Int(((try? await track.load(.estimatedDataRate)) ?? 0) / 1000)
            if let format = try? await track.load(.formatDescriptions).first,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format) {
                t.sampleRate = Int(asbd.pointee.mSampleRate)
            }
        }
        return t
    }
}
