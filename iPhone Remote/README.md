# Studio Session Remote (iPhone)

Shows what Studio Session on your Mac is doing (session, each drive, progress, speed,
last backup, warnings) and lets you start, pause or stop a backup from the phone.

## 1. Turn it on on the Mac (Studio Session 1.47+)

Studio Session menu > **iPhone Remote…** > turn on "Let paired iPhones see backups and
start them", then click **Pair an iPhone**. A six-digit code appears (works once, for 10 minutes).
Off by default; while it's off nothing on the Mac listens on the network.

## 2. Put the app on your iPhone

1. Open `StudioSessionRemote.xcodeproj` in Xcode.
2. Plug in the iPhone (or pick it over Wi-Fi), choose it as the run destination, press Run.
   Signing is set to your team (PBK2ZBS34N), automatic.
3. First launch: allow **Local Network** when iOS asks (that's how it finds the Mac).

Xcode 15.4 (what this Mac has now) can't install on iOS 18 or later. If the iPhone is on a
newer iOS, update Xcode from the App Store first; the project opens as-is.

## 3. Pair

Same Wi-Fi as the Mac: the Mac shows up in the list. Pick it, type the code, Pair.

## Away from the Wi-Fi (cellular)

The phone reaches the Mac through **Tailscale** (free for personal use):

1. Install Tailscale on the Mac and on the iPhone, sign in to the same account on both.
2. Pair once more, or not: if Tailscale was on when you paired, the app already knows the
   Mac's Tailscale address (100.x.y.z). Otherwise type it in the app's Settings > Other address,
   or on the pairing screen.

The app tries the last address that worked, then the Wi-Fi addresses, then Tailscale, and
shows which one it's using at the top ("Same Wi-Fi" / "Tailscale"). The Mac must be awake.

## What the phone can and can't do

- Back Up Now runs the same drive checks as the Mac. A slow link or non-APFS drive comes back
  to the phone as a warning with "Back Up Anyway". A backup folder that holds a different
  session's backup is refused; start that one at the Mac.
- A drive held by the removal guard shows on the phone; approving it stays on the Mac.
- Pause / Resume / Stop work like the Mac's Pause All / Stop All.

## Security

Pairing needs the code shown on the Mac's screen; 5 wrong codes close pairing. Each phone
gets its own random token (stored in the iPhone Keychain; the Mac keeps only a hash).
Remove a phone in the Mac's iPhone Remote window. Traffic on the Wi-Fi is plain HTTP, so
someone on the same network could read the status (not start a backup without the token,
though the token itself travels in the clear). Tailscale traffic is encrypted end to end.
