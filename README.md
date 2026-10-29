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
- Turn on **Remind me** in an item and choose its notification time. The first use asks for notification permission. A blue alarm button filters the selected day to items with a reminder set; tap again or Show all to return. Filter buttons use separate circular glass controls with small orange/blue count badges. Active filters use tinted native Liquid Glass with coloured icons; inactive controls are neutral. The add button uses quiet plain glass and a secondary plus icon. The blue and orange filters are mutually exclusive. Reminder dates appear in the filtered rows, and a small blue dot marks configured reminders. Completed and elapsed reminders remain visible in this filter while set, but only future reminders for unfinished items notify.
- **Move to next day if unfinished** controls carry-over independently of the item’s time or duration. New items default to moving forward; turn it off for fixed appointments.
- Add optional **Locations** and **People** as separate text entries in the item editor. Use Add location / Add person for more, and the minus button to remove an entry. Blank entries are discarded and surrounding whitespace is trimmed on save. These are local text fields; existing items open with empty lists.
- Tap a circle to complete an item or undo completion. Completed items stay in place.
- Tap a title to edit dates, times, notes, carry-over, people or locations. Reschedule through its Day field.
- Linked-item controls and parent/child labels are temporarily hidden. Existing relationships are retained in saved data for future work; deleting an item keeps the other items.
- People and locations share one small, subdued line below the title, separated by a middle dot and tiny faint person/pin icons. Long details truncate visually; VoiceOver reads the full values and the editor shows every entry. Empty fields take no space.
- Items needing review have a small orange dot, alongside a blue dot when a reminder is set. Completion circles are neutral. The unused outline variant is retained for future use. The orange Liquid Glass button at the top right toggles a review filter in the same list, with complete / leave open / reschedule buttons under each item. Resolving an item removes it from the filtered list. Tap the toolbar button again or Show all to return to the full day; an All clear state also offers Show full day. The same list and item identities are retained while filtering: other rows collapse away and return when the filter clears. A visible count explains how many items are hidden. Reduce Motion disables list movement. The toolbar uses only a warning symbol, with the count available to VoiceOver. Review dots, the toolbar warning, review reasons and actions share the same orange. Review actions sit in one subtle grouped bar with equally sized, equally weighted Complete, Leave open and Reschedule controls and fine separators; accessibility text sizes stack the controls. Changing day clears the filter. Ended time ranges and elapsed point times can prompt a review.
- Rows use a compact layout with times beside titles when space permits; longer titles and larger text sizes wrap naturally. Tap a title to edit or delete, and use its circle to change completion. There are no row swipe actions. Deleting an item leaves other items intact.
- Use the larger bottom-centre glass date control: tap to open the calendar, hold to return to today, swipe left for the next day or right for the previous day. Horizontal swipes change one day per gesture with a directional page slide (no movement with Reduce Motion); vertical or short drags do nothing. VoiceOver exposes the same actions. The top calendar/Today buttons have been removed. The chevrons are tappable previous/next buttons, and the date control uses native interactive Liquid Glass feedback, without a custom positional offset. Short horizontal swipes (six points) register a day change; repeated swipes queue rather than being ignored while a page is animating. Day changes use a native horizontal UIPageViewController scroll transition, retaining the outgoing day until the new page finishes sliding in. Queued day changes advance when UIKit reports completion; SwiftUI list filtering does not control the page animation; the add button remains at the bottom right.

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

The version 4 format reads existing version 1, 2 and 3 plans without changing item IDs or schedules. Legacy tasks default to carry-over enabled and legacy events to disabled. The next successful write saves the new format.

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

- The iPhone application target compiled successfully against the installed iOS 27.1 SDK.
- The core XCTest suite covers migration, independent carry-over, duration editing and overnight scheduling alongside the original scheduling checks.
- Simulator launch and interactive visual verification were blocked by this automation session's connection to CoreSimulator. On-device testing, VoiceOver, maximum Dynamic Type, dark mode and reduced motion/transparency still need hands-on verification. Successful compilation does not establish visual quality.
- The interface uses native navigation/toolbar materials and a Liquid Glass add button. System accessibility preferences control the native materials; custom completion animation respects Reduce Motion.
- Untimed tasks currently follow creation order. Drag reordering is not implemented.
- No custom icon yet; the app uses the development placeholder.
- Syncing, recurrence, accounts, projects and AI remain out of scope. Nothing has been pushed to GitHub or deployed to Vercel.
