# DeskDash

A small macOS app that lives in the menu bar and as a widget on the desktop.

Right now it shows:
- Every drive (the Mac's own disk, external drives, network shares) with a Disk Utility style bar.
- Click a drive to open the details window: what kinds of data use the space, the biggest folders and files,
  and suggestions for what to delete, move to another drive, or back up.
- A spot for AI token usage (Anthropic, OpenAI, Google), coming next.

Needs macOS 14 or newer and Xcode.

## Build and run

```
Tools/deskdash.sh run       # build and open
Tools/deskdash.sh install   # put an optimized copy in /Applications
Tools/deskdash.sh test      # run the tests
```

To see everything on the Mac's own disk, give DeskDash Full Disk Access in
System Settings > Privacy & Security > Full Disk Access. Without it, some folders are skipped (the app says how many).

Nothing is ever deleted outright: "Move to Trash" asks first, and you can put files back until you empty the Trash.

## Notarizing

`Tools/deskdash.sh install` signs DeskDash with the "Developer ID Application" certificate and, when a saved
Apple login named `DeskDash` is there, sends it to Apple to be checked (notarized) so macOS never warns about it.
Saving the login is a one-time step per Mac:

1. At https://account.apple.com, sign in, open "App-Specific Passwords" and make one (name it "DeskDash").
2. In Terminal run the line below, with your Apple Account email and that password:
   `xcrun notarytool store-credentials DeskDash --apple-id YOUR-EMAIL --team-id DA9YJ36D24 --password THE-APP-PASSWORD`
