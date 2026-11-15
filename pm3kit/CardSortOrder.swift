import Foundation

enum CardSortOrder: String, CaseIterable, Identifiable {
    case manual
    case name
    case newestFirst
    case oldestFirst
    case cardType

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manual: return "Manual order"
        case .name: return "Name"
        case .newestFirst: return "Newest first"
        case .oldestFirst: return "Oldest first"
        case .cardType: return "Card type"
        }
    }

    /// Only manual order can be rearranged by dragging; every other order is
    /// derived from the cards themselves, so a drag would snap back.
    var isDraggable: Bool { self == .manual }

    func arrange(_ cards: [SavedCard]) -> [SavedCard] {
        switch self {
        case .manual:
            return cards
        case .name:
            return cards.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .newestFirst:
            return cards.sorted { $0.created > $1.created }
        case .oldestFirst:
            return cards.sorted { $0.created < $1.created }
        case .cardType:
            return cards.sorted {
                $0.summary == $1.summary
                    ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    : $0.summary < $1.summary
            }
        }
    }
}
