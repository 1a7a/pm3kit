import XCTest
@testable import pm3kit

final class CardSortOrderTests: XCTestCase {

    private func makeCard(_ name: String, created: TimeInterval, family: String) -> SavedCard {
        var card = SavedCard(name: name, tracks: [
            CardTrack(band: family == "em410x" || family == "hid_prox" ? .lf : .hf,
                      family: family, ident: "AA", cloneable: true),
        ])
        card.created = Date(timeIntervalSince1970: created)
        return card
    }

    private lazy var cards: [SavedCard] = [
        makeCard("Office badge", created: 300, family: "hid_prox"),
        makeCard("front door", created: 100, family: "mifare_classic"),
        makeCard("Gate fob", created: 200, family: "em410x"),
    ]

    func testManualOrderIsLeftAlone() {
        XCTAssertEqual(CardSortOrder.manual.arrange(cards).map(\.name),
                       ["Office badge", "front door", "Gate fob"])
    }

    func testNameSortIgnoresCase() {
        XCTAssertEqual(CardSortOrder.name.arrange(cards).map(\.name),
                       ["front door", "Gate fob", "Office badge"],
                       "a lowercase name must not sort after every capitalised one")
    }

    func testNewestAndOldestAreOpposites() {
        let newest = CardSortOrder.newestFirst.arrange(cards).map(\.name)
        let oldest = CardSortOrder.oldestFirst.arrange(cards).map(\.name)
        XCTAssertEqual(newest, ["Office badge", "Gate fob", "front door"])
        XCTAssertEqual(oldest, newest.reversed())
    }

    func testCardTypeGroupsThenSortsByName() {
        let sorted = CardSortOrder.cardType.arrange(cards)
        XCTAssertEqual(sorted.map(\.summary), ["EM410x", "HID Prox", "MIFARE Classic"])
    }

    func testOnlyManualOrderAcceptsDragging() {
        XCTAssertTrue(CardSortOrder.manual.isDraggable)
        for order in CardSortOrder.allCases where order != .manual {
            XCTAssertFalse(order.isDraggable, "\(order.label) is derived, so a drag would snap back")
        }
    }

    func testEverySortKeepsEveryCard() {
        for order in CardSortOrder.allCases {
            XCTAssertEqual(Set(order.arrange(cards).map(\.id)), Set(cards.map(\.id)), order.label)
        }
    }
}
