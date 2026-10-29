# timo

A native, local-first iPhone daily planner built with SwiftUI. Requires iOS 26 or later and a compatible Xcode installation. There are no third-party dependencies, accounts or network requests.

## Run on your iPhone

1. Open **Timo.xcodeproj** in Xcode (not Package.swift).
2. Select the **Timo** project in the left sidebar, then the **Timo** application target.
3. Under **Signing & Capabilities**, leave **Automatically manage signing** enabled and select your **Personal Team**. If the bundle identifier is unavailable, change `com.timovijn.timo` to a unique identifier.
4. Connect your unlocked iPhone, trust the Mac and enable Developer Mode if prompted.
5. Select your iPhone as the destination beside the Timo scheme and press **⌘R**.

A free Personal Team can install the app on your phone. You must run it again from Xcode when its seven-day provisioning profile expires. Keep the same bundle identifier and update the installed app rather than deleting it to preserve its local data.

## Run in Simulator

Open the same project, select an installed iPhone Simulator as the destination and press **⌘R**. No signing team is needed for Simulator. If a runtime is missing, install it through Xcode Settings → Components.

## Try the first version

- Tap **Try a sample day** on the empty screen for work, sport, shaving, shopping, cooking, calling Mum and reading. Sample data is optional and only offered when there are no stored items.
- Tap **+** to create a task. Switch to Event to reserve a start/end period.
- Tap a circle to complete an item or undo completion. Completed items stay in place.
- Tap a title to edit dates, times, notes, type or parent. Reschedule through its Day field.
- Save a parent, reopen it and tap **Add subtask**. Subtasks can be independently scheduled; the daily row shows their parent.
- Items needing review have a small orange dot in the full day view. The orange Liquid Glass button at the top right toggles a review filter in the same list, with complete / leave open / reschedule buttons under each item. Resolving an item removes it from the filtered list. Tap the toolbar button again or Show all to return to the full day; an All clear state also offers Show full day. The filter fades and slides between views (fade only with Reduce Motion). Review actions use a filled Complete capsule, a quieter Leave open capsule and a calendar button for rescheduling; larger text stacks the labelled controls. Changing day clears the filter. Ended events, elapsed task times and finished subtasks can prompt a review.
- Rows use a compact layout with times beside titles when space permits; longer titles and larger text sizes wrap naturally. Tap a title to edit or delete, and use its circle to change completion. There are no row swipe actions. Deleting a parent offers both keep-subtasks and delete-subtasks choices.
- Use the bottom arrows and date control to move between days; **Today** returns to the current day.

## Scheduling decisions

- One shared item model, with task/event scheduling rules and stable UUIDs.
- Tasks use local calendar dates plus an optional minute of the day. Carry-over uses Calendar.current, not elapsed 24-hour intervals.
- Every open task dated before today moves directly to today, loses its old time, retains its original scheduled date and records the first day it was carried from. It keeps its identifier and parent relationship.
- Carry-over runs at launch, foreground entry, every 30 seconds while active, and after edits/completion changes. It does not depend on background execution at midnight.
- Entering a new incomplete task on a past day immediately carries it to today. Undoing a completed past task does the same.
- Past days contain the items still scheduled there, not a snapshot of the original plan. No historical copies are generated.
- Events never carry over. Overnight events appear on each day they overlap; an event ending at midnight is excluded from the following day.
- Tasks and subtasks are evaluated independently; completing a parent does not finish its children, and finishing children only suggests completing their parent task.
- Time-passed suggestions never change completion state. Leave open dismisses that suggestion until the schedule changes, completion is undone or carry-over occurs.
- Parent selection enforces one level of subtasks and rejects missing parents, cycles and events as children.
- The screen follows today across midnight when viewing today; intentionally viewing another day does not jump back.

## Persistence

The plan is stored as an atomically written, versioned JSON document in the app's Application Support/Timo/plan.json. The plan is small and local; this keeps version one dependency-free and allows scheduling tests to run without an iOS runtime. SwiftData is not used in this implementation. A later storage migration can retain the existing item IDs.

Writes complete before in-memory state is published. Save failures are surfaced. An unreadable or unsupported existing document is left untouched and saving is disabled. Deleting the app deletes its local plan. There is no backup/export UI yet.

## Tests

From the project folder:

```sh
swift test
```

Package.swift contains the Foundation-only scheduling model and XCTest suite. The app compiles the same model source directly. Tests cover missed days, repeated reconciliation, local midnight and daylight-saving transitions, events/completed/future tasks, parent links, overnight visibility, validation, deletion choices, completion suggestions, rescheduling and JSON/file persistence.

Command-line application build without signing:

```sh
xcodebuild -project Timo.xcodeproj -scheme Timo \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## Verification and remaining work

- The iPhone application target compiled successfully against the installed iOS 27.1 SDK.
- All 11 core XCTest tests passed on the Mac.
- Simulator launch and interactive visual verification were blocked by this automation session's connection to CoreSimulator. On-device testing, VoiceOver, maximum Dynamic Type, dark mode and reduced motion/transparency still need hands-on verification. Successful compilation does not establish visual quality.
- The interface uses native navigation/toolbar materials and a Liquid Glass add button. System accessibility preferences control the native materials; custom completion animation respects Reduce Motion.
- Untimed tasks currently follow creation order. Drag reordering is not implemented.
- No custom icon yet; the app uses the development placeholder.
- Syncing, recurrence, accounts, notifications, projects and AI remain out of scope. Nothing has been pushed to GitHub or deployed to Vercel.
