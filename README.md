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
