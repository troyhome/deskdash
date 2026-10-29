# DeskDash - project brief for Claude Code

DeskDash is a native macOS menu bar app plus desktop widget (Swift / SwiftUI, macOS 14+), inspired by Vorssaint.
First feature: disk usage per drive with category drill-down and suggestions. Next: live AI token usage
(Anthropic, OpenAI, Google); the placeholder is `AITokensPlaceholder` in `Sources/DeskDash/Components.swift`.

## About the user
- New to programming and Terminal. Explain briefly, in plain language, no jargon. No emojis.
- UI rule: no looping/indeterminate animations (spinners, sliding progress bars). Show progress as text.

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
