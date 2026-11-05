# DeskDash - project brief for Claude Code

DeskDash is a native macOS menu bar app plus desktop widget (Swift / SwiftUI, macOS 14+), inspired by Vorssaint.
First feature: disk usage per drive with category drill-down and suggestions. Second: live AI token usage
(Anthropic, OpenAI, Google); token usage lives in `LocalUsageLogs` / `AccountUsage` (core) and `TokenStore` / `TokenViews.swift` (app). Admin keys are kept in the Keychain (`Keychain.swift`).

## About the user
- New to programming and Terminal. Explain briefly, in plain language, no jargon. No emojis.
- UI rule: no looping/indeterminate animations (spinners, sliding progress bars). Show progress as text.

- iCloud storage card under the drives (`CloudStorage.swift`): space left comes from `brctl quota`; macOS doesn't
  give the plan size, so it's the smallest iCloud+ plan that fits (right-click the card to pick the real one).
  Google Drive: DeskDash signs in to Google itself (`GoogleDrive.swift`, `GoogleDriveConnection.swift`): Troy's own
  "Desktop app" client from console.cloud.google.com (project DeskDash, published "In production" so sign-in lasts),
  client file picked up from ~/Downloads/client_secret_*.json, browser sign-in back to 127.0.0.1 with PKCE, scope
  drive.file, `drive/v3/about` storageQuota. Client and refresh token live in the Keychain. Setup window: + next to Drives.

- Claude plan limits use Claude Code's sign-in, which expires after a few hours; when it has, `TokenStore` runs
  `claude auth status` (renews it, no model call, no tokens), at most every 10 minutes.

- Compact mode (`CompactViews.swift`, pie button in the widget header or the menu bar toggle): drives and online storage
  as rings in a grid, plan limits as small rings with "% left"; widget 250 wide instead of 360.

- AI section: each provider's plan limits (whole account) come first; token counts are smaller and say how far they
  reach. Counts are shared between Troy's Macs through iCloud Drive > "DeskDash Usage" (one `usage-<Mac>.json` per
  Mac, hourly buckets, `SharedUsage.swift`), so with both Macs on they read "on all your Macs". The Claude app and
  website keep no counts on the Mac, so they're never in the counts (they are in the limits).

- API web searches: Troy's own apps (Even Quicker first) append one line per Claude API reply to
  `~/Library/Application Support/DeskDash/API Usage/<app>.jsonl` (`date`, `app`, `model`, and the reply's `usage`).
  DeskDash adds those tokens to the Anthropic counts and shows "Web searches: N today · N in 30 days · $X" at
  $10 per 1,000 (`WebSearchPrice`). Searches from the account report count too; Claude Code's don't (its plan covers them).
  Below that, "API charges: $X today · $Y in 30 days (estimate)": API-key use (apps + account report) priced by
  model at list price (`APIPrice`, update when prices change) plus searches. Plan use is never priced.

## Layout
- Swift package, no Xcode project. `DeskDashCore` = drives, scanning, categories, suggestions (tested).
  `DeskDash` = the app (menu bar, desktop widget panel, details window).
- The desktop widget is an `NSPanel` at desktop-icon level + 1 (below normal windows, on all Spaces).
- The details window is AppKit-managed (`DetailsWindowController`) so both the widget and the menu bar can open it.

## Rules
- Trash only via FileManager.trashItem, always after a confirmation. Never delete outright.
- Build files never go inside the project folder: use `Tools/deskdash.sh build|run|test|install`
  (everything builds into `~/Library/Developer/DeskDash`).
- Bundle id `com.troyhomenchuk.DeskDash`. Signing: Troy's "Apple Development" certificate (team DA9YJ36D24)
  when present, else local-only.
- Project at `~/Projects/DeskDash` on each Mac. After finishing work: commit and push.
