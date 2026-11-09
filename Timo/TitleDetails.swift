import SwiftUI

/// Under a new item's title in the editor: a pill for each detail `QuickEntry` read from the
/// title ("January 20 dinner with Sam at 18:00"), which fill in the form when the title is done.
/// Tapping a pill gives its words back to the title.
struct TitleDetailPills: View {
    let entry: QuickEntry
    /// Keeps these matches' words in the title.
    let ignore: ([String]) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !pills.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                FlowLayout(spacing: 8) {
                    ForEach(pills) { pill in
                        Button {
                            withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { ignore(pill.matchIDs) }
                        } label: {
                            HStack(spacing: 6) {
                                if let persona = pill.persona {
                                    PersonaOrb(persona: persona, size: 14, glows: false)
                                } else {
                                    Image(systemName: pill.symbol).accessibilityHidden(true)
                                }
                                Text(pill.label).lineLimit(1)
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 12).frame(minHeight: 32)
                            .foregroundStyle(pill.tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.pillText))
                            .background(pill.tint.map { AnyShapeStyle($0.opacity(0.14)) } ?? AnyShapeStyle(.pillFill), in: .capsule)
                            .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(pill.name) from the title: \(pill.label)")
                        .accessibilityHint("Keeps these words in the title instead")
                    }
                }
                Text(entry.title.isEmpty ? "Add a title to go with these details." : "Saved as “\(entry.title)”. Tap a detail to keep its words in the title.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .transition(.opacity)
        }
    }

    private struct Pill: Identifiable {
        let id: String
        let name: String
        let label: String
        var symbol = ""
        var persona: Persona?
        var tint: Color?
        let matchIDs: [String]
    }
    /// Only what was typed: the editor's own day and time already show in its Schedule.
    private var pills: [Pill] {
        func ids(_ kinds: QuickEntry.Kind...) -> [String] { entry.matches.filter { kinds.contains($0.kind) }.map(\.id) }
        var pills: [Pill] = []
        if !ids(.day).isEmpty {
            pills.append(Pill(id: "day", name: "Day", label: dayLabel, symbol: "calendar", matchIDs: ids(.day)))
        }
        if let minute = entry.minute {
            pills.append(Pill(id: "time", name: "Time", label: timeLabel(minute, entry.endMinute), symbol: "clock", matchIDs: ids(.time, .length)))
        }
        if entry.repeatRule != .never {
            pills.append(Pill(id: "repeat", name: "Repeats", label: repeatLabel, symbol: "repeat", matchIDs: ids(.repeats)))
        }
        for match in entry.matches {
            switch match.kind {
            case .persona:
                if let persona = Persona.allCases.first(where: { $0.title == match.values.first }) {
                    pills.append(Pill(id: match.id, name: "Persona", label: persona.title, persona: persona, tint: persona.color, matchIDs: [match.id]))
                }
            case .people:
                pills.append(Pill(id: match.id, name: match.values.count == 1 ? "Person" : "People",
                                  label: match.values.formatted(.list(type: .and)), symbol: "person", matchIDs: [match.id]))
            case .place:
                pills.append(Pill(id: match.id, name: "Location", label: match.values.first ?? match.phrase,
                                  symbol: "mappin.and.ellipse", matchIDs: [match.id]))
            default: break
            }
        }
        return pills
    }

    private var dayLabel: String {
        let today = Day(Date())
        func format(_ day: Day) -> String {
            if day == today { return String(localized: "Today") }
            if let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today.date()), day == Day(tomorrow) { return String(localized: "Tomorrow") }
            var style = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated)
            if day.year != today.year { style = style.year() }
            return day.date().formatted(style)
        }
        guard let end = entry.endDay else { return format(entry.day) }
        return "\(format(entry.day)) – \(format(end))"
    }
    private func timeLabel(_ minute: Int, _ endMinute: Int?) -> String {
        func format(_ minute: Int) -> String {
            let date = Calendar.current.date(bySettingHour: minute / 60 % 24, minute: minute % 60, second: 0, of: Date()) ?? Date()
            return date.formatted(date: .omitted, time: .shortened)
        }
        guard let endMinute else { return format(minute) }
        return "\(format(minute))–\(format(endMinute))" + (endMinute >= 1440 ? " " + String(localized: "next day") : "")
    }
    private var repeatLabel: String {
        guard entry.repeatRule == .custom else { return entry.repeatRule.title }
        let symbols = Calendar.current.shortWeekdaySymbols
        return entry.repeatWeekdays.map { symbols[$0 - 1] }.formatted(.list(type: .and))
    }
}
