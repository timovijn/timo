# Timo

SwiftUI day planner for iOS 26 with a Liquid Glass look. The README describes every feature and decision in detail; read the relevant part instead of rediscovering behaviour from the code, and update it whenever behaviour changes.

## Layout

- `Sources/TimoCore/Planner.swift`: the Foundation-only model (`Day`, `PlanItem`, `RepeatingPlan`, `Persona`, `Planner`). It's compiled straight into the app target and, with `QuickEntry.swift`, is the code under test.
- `Sources/TimoCore/QuickEntry.swift`: reads one typed line ("January 20 dinner with Sam at 18:00") into an item's title, day, time, repeat, people, places and personas; reuses `SearchQuery`'s date helpers. Compiled into the app target only (not the widget).
- `Tests/TimoCoreTests/`: XCTest suite (`PlannerTests`, `RepeatingTests`, `PersonaTests`, `TimelineLaneTests`, `CancelTests`, `SyncTests`, `DayProgressTests`, `VisitTests`, `DayGuideTests`, `SearchTests`, `DateSearchTests`, `QuickEntryTests`, `AttachmentTests`, `ChecklistTests`).
- `Timo/DayView.swift`: the main screen (day pager, dock, date control and calendar, list/time views, rows). It's large; search it with grep and read only the part you need.
- `Timo/FocusedItem.swift`: the **focussed state**, Timo's name for the long-pressed state: the card expands in place with its history and Cancel and Delete. Holding an item or tapping its Live Activity brings it up.
- `Timo/ItemEditor.swift`: the item editor (schedule/reminder pills, persona chips, location/people pills, (i) explanations).
- `Timo/PersonaViews.swift`: persona orb, top-left persona menu, persona history page, long-press delete.
- `Timo/TitleDetails.swift`: the pills under a new item's title in the editor, one per detail `QuickEntry` read from it (tap one to keep its words in the title). `ItemEditor.applyTitleDetails` moves them into the form when the title is done or the item saved.
- `Timo/SearchView.swift`: search: the button beside the persona button that grows into the field in a row under the top controls (`SearchLayer`), the pull that draws it down (`SearchPull`, `PullsToSearch`) and the page-hiding `SearchBackdrop`. Results are the day list's own rows; the persona scopes them and the day's filter buttons count and narrow them (`searchFilter` in `DayView`); matching lives in `Planner.search`, and dates in a query are read by `SearchQuery`.
- `Timo/Attachments.swift`: item attachments (links, text, photos, files): the pills in the editor and focussed card (`AttachmentPills`), Quick Look and the text page.
- `Timo/Checklist.swift`: an item's checklist: `ChecklistEditor` (the editor section: entries as pills in a `FlowLayout`, typed in `ChecklistPillField`s that handle Return without ending editing) and `ChecklistCard` (ticking off in the focussed card). The model is `ChecklistEntry` in `Planner.swift`.
- `Timo/AttachmentFiles.swift` (app and share extension): `AttachmentFiles` (the files beside the plan), `ShareInbox` (what the extension hands the app; `PlanStore.applySharedInbox` saves it) and the read-only `PlanSnapshot`.
- `TimoShare/` (the `TimoShare` share extension, `com.timovijn.timo.share`): `ShareViewController` reads what was shared into attachments, `ShareView` is "Add to Timo". It also compiles `Planner.swift`, `QuickEntry.swift`, `PlanLocation.swift` and `AttachmentFiles.swift`.
- `Timo/PlanStore.swift`: JSON persistence (document version 11, reads 1–11), reminders, sample day.
- `Timo/PlanLocation.swift`: where the plan file lives (the App Group's shared container when available; one file on the Mac shared by all simulators), compiled into the app, the widget and the share extension.
- `TimoWidget/TimoWidget.swift`: the lock screen widget extension (today's done count); it also compiles `Planner.swift`.
- `Timo/GuideActivity.swift` (app and widget): Live Activity attributes, persona colours and the Complete intent; `TimoWidget/GuideLiveActivity.swift` draws it; `Timo/DayGuideActivities.swift` starts, schedules and ends the activities ("Guide my day").
- `Timo/CloudSync.swift`: iCloud sync with `CKSyncEngine` (one JSON record per item and repeating plan); every `PlanStore.commit` queues its changes. Attachment files go up as fixed-schema `File` records (one per attachment per zone, `queueMissingFiles`/`receiveFile`). Sharing is here too (a zone per shared item, a second engine for the shared database); `Timo/CloudSharing.swift` has the app and scene delegates that receive links and the system sharing sheet.
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

- All simulators (iPhone and iPad) share one plan at `~/Library/Application Support/Timo Simulators/plan.json` on the Mac, and running apps reload it when another one saves. Each simulator's own App Group copy (`$(xcrun simctl get_app_container <sim> com.timovijn.timo group.com.timovijn.timo)/Timo/plan.json`) is only read once, to seed that file when it's missing.
- It holds the user's sample data. Back it up before seeding or saving test items, and restore it afterwards. Opening the app also rewrites old plans to the current format.

## Model rules worth knowing

- An item's scheduled `day` never changes by itself. Where it's shown is derived: `liveDay(now:)`, `shows(on:now:)`, `movedAway(from:now:)`, `isCarried(now:)`.
- Ticking an item off while viewing a past day completes it on that day (`Planner.completionDate`).
- New items carry over only when Anytime; giving one a time turns "Move to next day if unfinished" off unless the user set it.
- Checklist ticks belong to the day, like completion: `PlanStore.save` and `Planner.saveRepeating` keep each occurrence's ticks, and ticking never counts as a series edit.
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
