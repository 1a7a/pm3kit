import Foundation

struct LibraryArchive: Codable {
    static let currentFormatVersion = 1

    var formatVersion: Int = LibraryArchive.currentFormatVersion
    var exportedAt: Date = Date()
    var cards: [ArchivedCard]
}

/// A card plus every dump file it needs. `card.tracks[].dumpfile` holds a bare
/// filename here, never an absolute path, so an archive is portable between
/// machines and carries no home directory in it.
struct ArchivedCard: Codable {
    var card: SavedCard
    var dumpFiles: [String: Data]
}

struct LibraryRestoreSummary {
    var importedCards: Int
    var skippedDuplicates: Int
    var writtenFiles: Int
}

enum LibraryArchiveError: LocalizedError {
    case unreadableArchive
    case unsupportedFormatVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unreadableArchive:
            return "That file is not a pm3-kit archive."
        case .unsupportedFormatVersion(let v):
            return "This archive is format version \(v); this build understands \(LibraryArchive.currentFormatVersion)."
        }
    }
}

enum LibraryArchiveStore {

    // MARK: export

    static func encodeArchive(cards: [SavedCard]) throws -> Data {
        let archived = cards.map { card -> ArchivedCard in
            var portable = card
            var files: [String: Data] = [:]
            for i in portable.tracks.indices {
                guard let path = portable.tracks[i].dumpfile else { continue }
                let set = collectDumpSet(primaryPath: path)
                files.merge(set) { current, _ in current }
                portable.tracks[i].dumpfile = URL(fileURLWithPath: path).lastPathComponent
            }
            return ArchivedCard(card: portable, dumpFiles: files)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(LibraryArchive(cards: archived))
    }

    /// Every file in the dump directory belonging to the same capture as the
    /// primary dump. Gen2 `restore` locates the `-key.bin` by name beside the
    /// dump, so the whole set has to travel together.
    static func collectDumpSet(primaryPath: String) -> [String: Data] {
        let primary = URL(fileURLWithPath: primaryPath)
        let directory = primary.deletingLastPathComponent()
        let stem = dumpSetStem(forFilename: primary.lastPathComponent)

        var files: [String: Data] = [:]
        if !stem.isEmpty {
            let siblings = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
            for sibling in siblings
            where sibling.lastPathComponent.lowercased().hasPrefix(stem.lowercased()) {
                if let bytes = try? Data(contentsOf: sibling) {
                    files[sibling.lastPathComponent] = bytes
                }
            }
        }
        if files[primary.lastPathComponent] == nil,
           let bytes = try? Data(contentsOf: primary) {
            files[primary.lastPathComponent] = bytes
        }
        return files
    }

    /// `hf-mf-DEADBEEF-dump.bin` and `hf-mf-DEADBEEF-key.bin` both stem to
    /// `hf-mf-DEADBEEF`.
    static func dumpSetStem(forFilename name: String) -> String {
        if let suffix = name.range(of: #"-(dump|key)\.[A-Za-z0-9]+$"#,
                                   options: [.regularExpression, .caseInsensitive]) {
            return String(name[name.startIndex..<suffix.lowerBound])
        }
        return (name as NSString).deletingPathExtension
    }

    // MARK: backup filename

    static let backupFilenamePrefix = "pm3kit-backup-"

    /// Calendar and locale are pinned because the default name must be a
    /// Gregorian date. A Mac set to the Buddhist calendar would otherwise
    /// stamp the year 2569.
    static func backupFilename(for date: Date = Date()) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.calendar = Calendar(identifier: .gregorian)
        stamp.timeZone = .current
        stamp.dateFormat = "yyyy-MM-dd-HHmm"
        return "\(backupFilenamePrefix)\(stamp.string(from: date)).json"
    }

    // MARK: import

    static func decodeArchive(from data: Data) throws -> LibraryArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let archive = try? decoder.decode(LibraryArchive.self, from: data) else {
            throw LibraryArchiveError.unreadableArchive
        }
        guard archive.formatVersion <= LibraryArchive.currentFormatVersion else {
            throw LibraryArchiveError.unsupportedFormatVersion(archive.formatVersion)
        }
        return archive
    }

    /// Writes each card's dump files into the dump directory and returns the
    /// cards with `dumpfile` pointing at the newly written local copies.
    /// Cards whose id already exists are skipped, so re-importing an archive
    /// does not duplicate the library.
    static func restoreCards(from archive: LibraryArchive,
                             existing: [SavedCard],
                             dumpDirectory: URL = PM3.dumpDir) -> (cards: [SavedCard], summary: LibraryRestoreSummary) {
        let known = Set(existing.map { $0.id })
        var restored: [SavedCard] = []
        var skipped = 0
        var written = 0

        for entry in archive.cards {
            guard !known.contains(entry.card.id) else { skipped += 1; continue }

            let renames = resolveFilenames(for: entry.dumpFiles, in: dumpDirectory)
            for (original, bytes) in entry.dumpFiles {
                let destination = dumpDirectory.appendingPathComponent(renames[original] ?? original)
                if (try? bytes.write(to: destination)) != nil { written += 1 }
            }

            var card = entry.card
            for i in card.tracks.indices {
                guard let name = card.tracks[i].dumpfile else { continue }
                let final = renames[name] ?? name
                card.tracks[i].dumpfile = dumpDirectory.appendingPathComponent(final).path
            }
            restored.append(card)
        }

        return (restored, LibraryRestoreSummary(importedCards: restored.count,
                                                skippedDuplicates: skipped,
                                                writtenFiles: written))
    }

    /// Maps each archived filename to the name it should take on disk. Files
    /// already present with identical bytes keep their name. A real clash
    /// renames the whole set together, so the dump and its key file keep the
    /// shared stem that `restore` relies on.
    static func resolveFilenames(for files: [String: Data], in directory: URL) -> [String: String] {
        let identity = Dictionary(uniqueKeysWithValues: files.keys.map { ($0, $0) })
        guard clashes(files, renamedBy: identity, in: directory) else { return identity }

        let stems = Set(files.keys.map { dumpSetStem(forFilename: $0) }).filter { !$0.isEmpty }
        guard let stem = stems.count == 1 ? stems.first : nil else {
            return uniqueByPrefix(files, in: directory)
        }

        for attempt in 2...99 {
            var candidate: [String: String] = [:]
            for name in files.keys {
                candidate[name] = "\(stem)-\(attempt)" + name.dropFirst(stem.count)
            }
            if !clashes(files, renamedBy: candidate, in: directory) { return candidate }
        }
        return uniqueByPrefix(files, in: directory)
    }

    private static func uniqueByPrefix(_ files: [String: Data], in directory: URL) -> [String: String] {
        let token = UUID().uuidString.prefix(8)
        return Dictionary(uniqueKeysWithValues: files.keys.map { ($0, "\(token)-\($0)") })
    }

    private static func clashes(_ files: [String: Data],
                                renamedBy renames: [String: String],
                                in directory: URL) -> Bool {
        for (original, bytes) in files {
            let destination = directory.appendingPathComponent(renames[original] ?? original)
            guard let onDisk = try? Data(contentsOf: destination) else { continue }
            if onDisk != bytes { return true }
        }
        return false
    }
}
