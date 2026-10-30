# Timo

SwiftUI day planner for iOS 26 with a Liquid Glass look. The README describes every feature and decision in detail; read the relevant part instead of rediscovering behaviour from the code, and update it whenever behaviour changes.

## Layout

- `Sources/TimoCore/Planner.swift`: the Foundation-only model (`Day`, `PlanItem`, `RepeatingPlan`, `Persona`, `Planner`). It's compiled straight into the app target and is the only code under test.
- `Tests/TimoCoreTests/`: XCTest suite (`PlannerTests`, `RepeatingTests`, `PersonaTests`, `TimelineLaneTests`).
- `Timo/DayView.swift`: the main screen (day pager, dock, date control and calendar, list/time views, rows). It's large; search it with grep and read only the part you need.
- `Timo/ItemEditor.swift`: the item editor (schedule/reminder pills, persona chips, location/people pills, (i) explanations).
- `Timo/PersonaViews.swift`: persona orb, top-left persona menu, persona history page, long-press delete.
- `Timo/PlanStore.swift`: JSON persistence (document version 7, reads 1–7), reminders, sample day.
- A new Swift file in `Timo/` must also be added to `Timo.xcodeproj/project.pbxproj` (PBXBuildFile, PBXFileReference, group child and Sources phase).

## Commands

```sh
swift test
xcodebuild -project Timo.xcodeproj -scheme Timo -destination 'id=E9FCCB9D-0F3D-42A7-B763-8A5DDA0B3353' -derivedDataPath build/dd build
```

- The simulator is the iPhone 18 Pro, `E9FCCB9D-0F3D-42A7-B763-8A5DDA0B3353`. The built app is `build/dd/Build/Products/Debug-iphonesimulator/Timo.app`, bundle ID `com.timovijn.timo`.
- `.build/` and `build/` are tracked in git, and building or testing modifies them. Never commit them; stage source files by name.
- Commit only when asked.

## Simulator data

- The plan lives at `$(xcrun simctl get_app_container <sim> com.timovijn.timo data)/Library/Application Support/Timo/plan.json`. The container path changes when the app is reinstalled, so look it up each time.
- It holds the user's sample data. Back it up before seeding or saving test items, and restore it afterwards. Opening the app also rewrites old plans to the current format.

## Model rules worth knowing

- An item's scheduled `day` never changes by itself. Where it's shown is derived: `liveDay(now:)`, `shows(on:now:)`, `movedAway(from:now:)`, `isCarried(now:)`.
- Ticking an item off while viewing a past day completes it on that day (`Planner.completionDate`).
- New items carry over only when Anytime; giving one a time turns "Move to next day if unfinished" off unless the user set it.
- Items have `personas: [Persona]` (multi-select, kept in `Persona.allCases` order via `Persona.ordered`).

## Design conventions

- Liquid Glass throughout: system glass for bars and buttons, round 56 pt glass buttons beside the date capsule. Morphs use one glass identity (`glassEffectID`) rather than custom zooms.
- Pills: a set value is a filled capsule (tinted for reminders and personas); an add button is a dashed outline with grey text.
- A selected persona tints the top-left button's glass in its colour; persona chips look like reminder pills in their colour. No large headers, gradients or glows on persona pages.
- Explanations in the editor sit behind a small (i) next to the section title and open below the section.
- Keep VoiceOver labels, Dynamic Type and Reduce Motion support with every change.

## Working economically

- Match verification to the change: build only for small visual tweaks, a single screenshot when the look matters, and video or frame-by-frame checks only for animation work.
- Write code that reads like the surrounding code: brief "why" comments, the same naming and idioms.
