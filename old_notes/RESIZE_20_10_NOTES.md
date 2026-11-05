# Digi Suite 20.10: window resize lag

```bash
cd "$HOME/Downloads/DigiSuite_20_10" && bash build.command
```

Cause: Folder Compare stays loaded on every tab (so results survive tab
switches). Each resize step redrew it, and each redraw re-added every file
size in every column and, for each visible folder row, searched all results
for children. With a session of ~36,000 files that is millions of string
checks per frame, even while another tab was showing.

Fix:
- Column totals, loose-file totals and folder "has children" are computed
  once per scan (rebuildSummary) and read from cache.
- The comparison columns are only drawn while the tab is showing; results
  and expanded folders are kept. Scroll position resets on return.
- One shared byte formatter instead of a new one per label.
