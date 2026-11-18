# Digi Suite 20.9: Folder Compare scans when opened

```bash
cd "$HOME/Downloads/DigiSuite_20_9" && bash build.command
```

- Opening the Folder Compare tab starts a Quick or Standard comparison
  automatically. Previous results stay visible while it scans.
- Deep Verify does not start on its own (it reads every byte); the tab says
  to click Refresh.
- No automatic scan while a backup is running; Refresh still works.
- Nothing scans in the background on other tabs (unchanged).
- Empty sizes read "0 KB" instead of "Zero KB".
