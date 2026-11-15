import Foundation

/// Persistent library of saved cards. Autosaves to Application Support.
@MainActor
final class CardStore: ObservableObject {
    @Published var cards: [SavedCard] = [] { didSet { save() } }

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("pm3kit", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("library.json")
    }

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([SavedCard].self, from: data) else { return }
        cards = decoded
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(cards) { try? data.write(to: fileURL) }
    }

    @discardableResult
    func add(name: String, tracks: [CardTrack]) -> SavedCard {
        let card = SavedCard(name: name, tracks: tracks)
        cards.insert(card, at: 0)
        return card
    }

    /// Attach a track to an existing card, replacing any track of the same band.
    /// Used to build a dual-frequency card from separately imported parts.
    func addTrack(to id: SavedCard.ID, _ track: CardTrack) {
        guard let i = index(of: id) else { return }
        cards[i].tracks.removeAll { $0.band == track.band }
        cards[i].tracks.append(track)
        cards[i].tracks.sort { $0.band.rawValue < $1.band.rawValue }  // hf before lf
    }

    func addRestored(_ restored: [SavedCard]) {
        guard !restored.isEmpty else { return }
        cards.insert(contentsOf: restored, at: 0)
    }

    func delete(_ id: SavedCard.ID) {
        cards.removeAll { $0.id == id }
    }

    func index(of id: SavedCard.ID) -> Int? {
        cards.firstIndex { $0.id == id }
    }
}
