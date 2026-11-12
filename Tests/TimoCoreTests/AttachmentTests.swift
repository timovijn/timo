import XCTest
@testable import TimoCore

final class AttachmentTests: XCTestCase {
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!; return c }
    func date(_ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }
    func day(_ value: Int) -> Day { Day(date(value), calendar: calendar) }

    func testTypedLineReadsAsLinkOrText() {
        let link = Attachment.reading("  https://www.example.com/tickets?id=4 ")
        XCTAssertEqual(link?.kind, .link)
        XCTAssertEqual(link?.title, "example.com")
        XCTAssertEqual(link?.url?.absoluteString, "https://www.example.com/tickets?id=4")
        // A bare address still reads as a link.
        XCTAssertEqual(Attachment.reading("apple.com/iphone")?.url?.absoluteString, "https://apple.com/iphone")
        XCTAssertEqual(Attachment.reading("Bring the passport")?.kind, .text)
        XCTAssertEqual(Attachment.reading("v1.2")?.kind, .text, "a word with a dot but no real host stays text")
        XCTAssertEqual(Attachment.reading("ftp://example.com")?.kind, .text)
        XCTAssertNil(Attachment.reading("   "))
    }
    func testTextIsTitledByItsShortenedFirstLine() {
        let note = Attachment.text("Gate B12\nBoarding 9:40")
        XCTAssertEqual(note.title, "Gate B12")
        XCTAssertEqual(note.text, "Gate B12\nBoarding 9:40")
        let long = Attachment.text(String(repeating: "a", count: 80))
        XCTAssertEqual(long.title.count, 60)
        XCTAssertTrue(long.title.hasSuffix("…"))
    }
    func testItemsWithoutAttachmentsEncodeAsBefore() throws {
        let plain = PlanItem(title: "Lunch", day: day(25))
        let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        XCTAssertFalse(json.contains("attachments"))
        var kept = plain
        kept.attachments = [.link(URL(string: "https://example.com")!),
                            Attachment(kind: .file, title: "Ticket", fileName: "Ticket.pdf", contentType: "com.adobe.pdf", byteCount: 1200)]
        let decoded = try JSONDecoder().decode(PlanItem.self, from: try JSONEncoder().encode(kept))
        XCTAssertEqual(decoded.attachments, kept.attachments)
        XCTAssertEqual(try JSONDecoder().decode(PlanItem.self, from: try JSONEncoder().encode(plain)).attachments, [])
    }
    func testSearchFindsAttachmentTitlesAddressesAndText() {
        var trip = PlanItem(title: "Trip", day: day(25))
        trip.attachments = [.link(URL(string: "https://booking.example.com/r/123")!), .text("Seat 14A"),
                            Attachment(kind: .file, title: "Boarding pass", fileName: "Boarding pass.pdf")]
        let other = PlanItem(title: "Lunch", day: day(25))
        for query in ["booking", "14a", "boarding pass"] {
            XCTAssertEqual(Planner.search(query, in: [trip, other], now: date(25), calendar: calendar).flatMap(\.items).map(\.id), [trip.id], query)
        }
    }
    func testRepeatingItemsKeepTheirAttachmentsOnEveryDay() {
        var template = PlanItem(title: "Gym", day: day(26), minute: 540, movesToNextDay: false)
        template.repeatRule = .daily
        template.attachments = [.text("Locker 12")]
        var items: [PlanItem] = []
        Planner.materialize([RepeatingPlan(template: template)], in: &items, from: day(26), through: day(28), calendar: calendar)
        XCTAssertEqual(items.map(\.attachments), Array(repeating: template.attachments, count: 3))
    }
    func testMergeKeepsAttachmentsAddedOnOneSide() {
        let base = PlanItem(title: "Trip", day: day(25))
        var mine = base; mine.attachments = [.text("Seat 14A")]
        var theirs = base; theirs.title = "Trip to Rome"
        let merged = PlanItem.merged(base: base, mine: mine, theirs: theirs)
        XCTAssertEqual(merged.attachments, mine.attachments)
        XCTAssertEqual(merged.title, "Trip to Rome")
    }
}
