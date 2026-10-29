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
- Tap **+** to create an item with a title and day. Optionally enable **Set a time**, then **Add an end time**. There is no Task/Event selector.
- Turn on **Remind me** in an item and choose its notification time. The first use asks for notification permission. A blue alarm button filters the selected day to unfinished items with a reminder set; tap again or Show all to return. Filter buttons use separate circular glass controls with small orange/blue count badges. Active filters use tinted native Liquid Glass with coloured icons; inactive controls are neutral. The add button uses quiet plain glass and a secondary plus icon. The blue and orange filters are mutually exclusive. Both filtered views share the same status-and-action panel below each item: a small coloured symbol, a caption and a tinted action bar. Reminder status shows a blue alarm and the reminder time (including its date when different from the viewed day); warning status shows an orange warning symbol and its reason. Reminder actions are Complete, Change time and Remove. Change time opens a focused date/time sheet; removal clears the reminder without deleting the item, and reminder edits/removal apply across a repeating series. Warning actions remain Complete, Leave open and Reschedule. A small blue dot marks configured reminders. Completing an item removes it from the reminder filter, its count and its blue row dot, just like resolving a warning. When none remain, the active filter shows All clear and offers Show full day. Undoing completion restores it to the reminder filter; the saved reminder is retained. Elapsed reminders remain in this filter while unfinished, but only future reminders notify.
- Choose **Repeat** → Every day, Every weekday, Every week, or Custom days in the editor (Never is the default). Work can repeat Monday–Friday with its start/end times, people, locations and reminder offset. Weekday/custom series start on the first matching date on or after the selected day. Each occurrence has independent completion/review state and stays on its scheduled day; repeating items do not carry over. All occurrences share one definition: editing the title, schedule, notes, people, locations or repeat pattern updates the entire series, including earlier days. Each day retains its own completion. Moving an occurrence to another day shifts the series by the same number of calendar days. Choose Never to keep only the edited occurrence as a standalone item. Deleting a repeating item deletes the whole series after confirmation. Older split series are reunited when edited. Future occurrences are generated as dates are opened, plus a rolling 60-day reminder window; the notification limit still applies.
- **Move to next day if unfinished** controls carry-over independently of the item’s time or duration. New items default to moving forward; turn it off for fixed appointments.
- Add optional **Locations** and **People** as separate text entries in the item editor. Use Add location / Add person for more, and the minus button to remove an entry. Blank entries are discarded and surrounding whitespace is trimmed on save. These are local text fields; existing items open with empty lists.
- Tap a circle to complete an item or undo completion. Completed items stay in place.
- Tap a title to edit dates, times, notes, carry-over, people or locations. Reschedule through its Day field.
- Linked-item controls and parent/child labels are temporarily hidden. Existing relationships are retained in saved data for future work; deleting an item keeps the other items.
- People and locations share one small, subdued line below the title, separated by a middle dot, without icons. Long details truncate visually; VoiceOver reads the full values and the editor shows every entry. Empty fields take no space.
- Items needing review have a small orange dot, alongside a blue dot when a reminder is set. Completion circles are neutral. The unused outline variant is retained for future use. The orange Liquid Glass button at the top right toggles a review filter in the same list, with complete / leave open / reschedule buttons under each item. Resolving an item removes it from the filtered list. Tap the toolbar button again or Show all to return to the full day; an All clear state also offers Show full day. The same list and item identities are retained while filtering: other rows collapse away and return when the filter clears. A visible count explains how many items are hidden. Reduce Motion disables list movement. The toolbar uses only a warning symbol, with the count available to VoiceOver. Review dots, the toolbar warning, review reasons and actions share the same orange. Review actions sit in one subtle grouped bar with equally sized, equally weighted Complete, Leave open and Reschedule controls and fine separators; accessibility text sizes stack the controls. Changing day clears the filter. Ended time ranges and elapsed point times can prompt a review.
- The bottom-left clock/list button switches between List and Time view and remembers the choice. A shared SwiftUI scroll surface and the same item views slide and spread from their compact positions into the timeline over half a second, without a separate List cell resizing underneath, while the scale and connectors fade in; switching back reverses the movement. Each item keeps two measured text layouts at fixed widths and crossfades between them as its position moves, avoiding per-frame text reflow. Only the active variant accepts taps, appears to VoiceOver and produces completion feedback. The fixed-size timeline scale is separate from the moving connectors, so row motion does not repeatedly format and draw hourly labels. A single animation drives row movement, content height and timeline visibility, including interrupted switches. Reduce Motion changes the layout immediately. Time view keeps natural item heights, with a quiet hourly rail, fine connectors to the scheduled times and narrow duration strokes. Overlapping ranges get separate parallel bars, each extending only over its own duration; longer events sharing a start stay closest to the axis. Tracks are reused once an event ends, and point tasks do not take up duration tracks. Gaps follow a one-point-per-minute scale; simultaneous/nearby items stack without overlapping and keep their exact timeline anchors. A current-time line appears for today. Any-time items stay in their own section, and reminder/review filters work in both views.
- Rows use a compact layout with times on the right, vertically centred against the full title and detail block; longer titles and larger text sizes wrap naturally. Tap a title to edit or delete, and use its circle to change completion. There are no row swipe actions. Deleting an item leaves other items intact.
- The bottom-centre glass date control shows the full weekday above the date. When viewing today, a cyan/blue/violet/pink rim sweeps around the capsule with a brief soft bloom on arrival, then settles after 1.35 seconds into a very faint slow orbit. The rim is part of the interactive glass content so it follows the capsule’s native stretch and press response; it disappears on other days, stays still with Reduce Motion, and pauses while inactive. The glow never intercepts taps or swipes; the top of the list only shows completion/filter information. A quiet relative date label appears above the control on opening and when changing days, then fades after 1.5 seconds. It shows Today, Tomorrow, Yesterday, Last/Next weekday within seven days, or a day count further away. Repeated navigation restarts the display time without queuing labels; VoiceOver always includes the relative date. Use the date control: tap to open the calendar, hold to return to today as soon as the half-second press is recognised (without waiting for release), swipe left for the next day or right for the previous day. Horizontal swipes change one day per gesture with a directional page slide (no movement with Reduce Motion); vertical or short drags do nothing. VoiceOver exposes the same actions. The top calendar/Today buttons have been removed. The dock observes swipes simultaneously with the central date’s hold gesture, so a stationary hold can fire before release. The chevrons are tappable previous/next buttons, and the date control uses native interactive Liquid Glass feedback, without a custom positional offset. Short horizontal swipes (six points) register a day change; repeated swipes immediately interrupt the current slide and move to the next selected day, without queuing. Day changes use a short (0.18-second) UIKit slide, starting from a snapshot of the current visual position when interrupted. Reduce Motion changes days immediately. SwiftUI list filtering does not control the page animation; the add button remains at the bottom right.

## Scheduling decisions

- One item model with a local day, optional start time, optional end time, completion and an independent carry-over preference. There is no stored task/event type in the new format.
- Calendar.current determines local days, including across daylight-saving transitions.
- Unfinished items with carry-over enabled move directly to today. Point-in-time items lose their old time; duration items retain their start time and elapsed duration on the new day. An overnight range still in progress stays put until it ends.
- Carry-over retains IDs, original scheduled dates, the first carried-from date and parent relationships.
- Carry-over runs at launch, foreground entry, every 30 seconds while active, and after edits/completion changes. It does not depend on background execution at midnight.
- Items with carry-over disabled remain on their original day. Completed and future items stay put.
- Past days contain the items still scheduled there, not a snapshot of the original plan. No historical copies are generated.
- Time ranges appear on every day they overlap; ending at midnight excludes the following day.
- Changing a start time or day preserves an existing duration. Removing the start time also removes the end time.
- Stored parent relationships are preserved, but linking controls and parent completion suggestions are temporarily disabled in the interface.
- Time-passed suggestions never change completion state. Leave open dismisses the suggestion until the schedule changes, completion is undone or carry-over occurs.
- Parent selection enforces one level of linked children and rejects missing parents and cycles.
- The screen follows today across midnight when viewing today; intentionally viewing another day does not jump back.

## Persistence

The plan is stored as an atomically written, versioned JSON document in the app's Application Support/Timo/plan.json. The plan is small and local; this keeps version one dependency-free and allows scheduling tests to run without an iOS runtime. SwiftData is not used in this implementation. A later storage migration can retain the existing item IDs.

The version 5 format stores repeat templates alongside occurrences and reads existing version 1, 2, 3 and 4 plans without changing item IDs or schedules. Legacy tasks default to carry-over enabled and legacy events to disabled. The next successful write saves the new format.

Writes complete before in-memory state is published. Save failures are surfaced. An unreadable or unsupported existing document is left untouched and saving is disabled. Deleting the app deletes its local plan. There is no backup/export UI yet.

## Reminders

Local notifications are scheduled after a successful save and refreshed at launch or foreground entry. Completion, deletion, disabling a reminder and time edits update pending notifications; notifications also present while the app is open. Notification delivery must still be checked on the iPhone, including permissions and Focus settings.

The nearest 64 future reminders are scheduled, replenished on subsequent saves or app entry. Carry-over clears expired reminders rather than repeating them. Changing an existing start shifts its reminder by the same amount; changing an untimed item's day shifts the reminder by calendar days. Removing an item's start preserves its explicitly set reminder.

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

- An earlier version of the iPhone application target compiled against the installed iOS 27.1 SDK. The latest recurrence UI passes Swift syntax checks; this session’s sandbox blocks the SwiftUI macro host needed for a full app build. Core scheduling tests and store type-checking run separately.
- The core XCTest suite covers migration, independent carry-over, duration editing, overnight scheduling and recurrence (patterns, DST, completion, persistence, distant dates, series edits and deletion).
- Simulator launch and interactive visual verification were blocked by this automation session's connection to CoreSimulator. On-device testing, VoiceOver, maximum Dynamic Type, dark mode and reduced motion/transparency still need hands-on verification. Successful compilation does not establish visual quality.
- The interface uses native navigation/toolbar materials and a Liquid Glass add button. System accessibility preferences control the native materials; custom completion animation respects Reduce Motion.
- Untimed tasks currently follow creation order. Drag reordering is not implemented.
- No custom icon yet; the app uses the development placeholder.
- Syncing, accounts, projects and AI remain out of scope. Nothing has been pushed to GitHub or deployed to Vercel.
