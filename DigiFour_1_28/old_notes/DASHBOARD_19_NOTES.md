# Digi Suite 19: session loading fix

```bash
cd "$HOME/Downloads/DigiSuite_19" && bash build.command
```

## Fixed: sessions needed to be opened twice

Choosing a session (Open Session… or "Use This Session") started the
Dashboard scan, then a session-changed handler immediately discarded that
scan as stale without starting a new one. The scan's "finished" step was
skipped, leaving the app stuck in a busy state:

- the Dashboard stayed empty until the session was chosen a second time,
- "Use This Session" was disabled or ignored,
- Save Workspace and auto-save refused to run ("Unsaved changes" stayed).

Now the handler recognizes a scan already running for the same session,
a stale scan always releases the busy state, and a new session choice can
replace a Dashboard scan of a previous session.

## Detected Capture One sessions sheet
- Return chooses "Use This Session"; Escape chooses "Not Now".
- Works while the Dashboard is still scanning a previous session.

## 20.7: Detect Session always answers
- Clicking Detect Session shows a short dialog when there is nothing to pick:
  Capture One not open, no session open in Capture One, or the only open
  session is already loaded. Return closes it. When sessions are found, the
  session picker appears as before. The automatic 12-second check stays quiet.
