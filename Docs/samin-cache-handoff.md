# Samin temp-cache / seamless playback — handoff

Written 2026-10-03. Resume from here.

---

## 1. Where things stand right now

**Updated 2026-10-03** (reconciled after build **0.5.6033** triggered).

**Branch:** `samin-temp-cache` (fork: `Saminahmed7/NuvioMobile`), **pushed**.
`git ls-remote origin refs/heads/samin-temp-cache` = `bf3f5d96` (local `origin/samin-temp-cache`
tracking ref was stale; run `git fetch` if needed).

**Last published release:** **`samin-v0.5.6032-6032`** (Nuvio Samin 0.5.6032).
**Build in progress:** **0.5.6033** (run `37146306907`) — includes the 6 post-6032 commits:
`98132fc9` delete dead constant, `c6caa3aa` align low-space 300 MB, `becc64b8` Step 2c preserve cache,
`1bdb4312` parked-client timeout, `2a9830b0` offload bridge to IO, `b41519e4` minResumeBytes comment.

**CI gate** (only verification possible — Windows/MSYS, no Xcode):
`xcrun --sdk iphoneos swiftc -parse iosApp/iosApp/Player/LocalCacheProxy.swift`,
`swiftc -parse iosApp/iosApp/Player/MPVPlayerBridge.swift`,
`./gradlew :composeApp:compileKotlinIosArm64`. Runs take **~45–80 min**.

**Install / check:**
```bash
# SideStore source (updates when run finishes):
#   https://raw.githubusercontent.com/Saminahmed7/NuvioMobile/samin-temp-cache/store-samin.json
gh run list -R Saminahmed7/NuvioMobile -w "Nuvio Samin sync and build" -L 3
gh release list -R Saminahmed7/NuvioMobile -L 3
```

---

## 2. DO THIS FIRST — test 0.5.6033 on the iPad when it finishes (~1 h)

0.5.6032 is already released. 0.5.6033 (build `37146306907`) adds the 6 items from the future-work queue:
dead constant removal, low-space alignment, Step 2c cache preservation, parked-client timeout,
bridge calls off main thread, minResumeBytes comment. Test the *"stream dies on sleep/wake"* causes:

1. Play an episode for ~2 minutes.
2. Screenshot → WhatsApp → back.
3. Lock iPad 1 min → unlock → back.
4. Close player, reopen same episode.

If any fail: **Playback & Cache Diagnostics → Refresh → Copy Report** (now includes session key,
free space, cached MB/%, HEAD vs GET, rate-limit state, write errors, reconnect counts).

1. Play an episode for ~2 minutes.
2. Take a screenshot → open WhatsApp → come back.
3. Lock the iPad for a minute → unlock → come back.
4. Close the player, reopen the same episode.

If all four pass, the worst problem is gone. If any fail: open **Playback & Cache Diagnostics**
(in the player), press **Refresh**, **Copy Report**, and save the text. That report now contains
app version/build, session key, free space, cached MB and percent, HEAD vs GET status, rate-limit
state, write errors and reconnect counts — enough to identify the cause instead of guessing.

---

## 3. STEP 2 — status: **ALL DONE** (in 0.5.6033)

Goal: **the player can never again be pointed at a dead address, and the cache survives an address change.**

### 2a. One address, for the life of the app — DONE
Landed in `c164cd6d` / `2cdcbea9`. `activeBoundPort = 19842` fixed for process lifetime; listener
rebuilds on same port, `listenerReady` gates URLs, `probeAccepting()` does real 0.75 s connect.

### 2b. Re-point the player on foreground — MOOT
Fixed port removes the stale-URL bug. `PlayerDestination.kt:50` still resolves once (`remember(launch)`);
foreground recovery handled by proxy/bridge (`handleForegroundWake`, `recoverListener`) +
`MPVPlayerBridge` retry. Revisit only if new "frozen after background" report appears.

### 2c. Stop a re-resolve from deleting the cache — **DONE in `becc64b8` (0.5.6033)**
`resolveProxiedSource` now **reuses the existing session key** for the same `launchId` instead of
calling `stopSession`. Swift `startSession` updates the upstream URL in-place via
`ProxySession.updateSourceUrl()` — cache directory and chunks preserved. Only a new `launchId`
(stream/episode switch) triggers teardown. Cache lives in `Caches/nuvio_proxy/<sessionKey>/`,
keyed by session, not port — bytes don't move.

**Guarantee now:** working cached stream or working uncached stream — never a frozen spinner.

---

## 4. STEP 3 — only if problems continue (bigger, riskier, untestable from here)

Remove the loopback HTTP server and drive MPV through **libmpv stream callbacks**
(`mpv_stream_cb_add_ro`, register a scheme like `samin://<launchId>`, implement `open/read/seek/size/close`)
over the existing chunk store. This deletes `NWListener`, `NWConnection`, `ProxyConnection`, the HTTP
parsing, port handling, session keys and the `queue.sync` + `Thread.sleep` retry loop. The bridge already
calls libmpv directly (`mpv_create`, `mpv_command` in
[MPVPlayerBridge.swift](../iosApp/iosApp/Player/MPVPlayerBridge.swift)).

Costs / risks: `read` runs on MPV's stream thread and must block until bytes exist (condition variable);
`size` must return the true total or seeking breaks; `seek` must handle the jump-to-end-to-read-index
pattern; `cancel` must be handled to avoid deadlock on teardown. It is an interop job that **cannot be
validated on this machine** — device only.

Alternatives considered:
- **MPV's own cache** (`cache=yes`, `cache-on-disk=yes`, `cache-dir`, `demuxer-max-bytes`,
  `demuxer-readahead-secs`): zero custom code, most robust, but a *rolling window* — loses instant
  rewind of already-watched material.
- **Download the file then play it**: does not work for "watch now". A finished file is finite/seekable;
  the player would hit a false EOF at the download edge (the `MPV_END_FILE_REASON_EOF` + `isPremature`
  reload handling in MPVPlayerBridge is the fingerprint of exactly that). Also MP4/MKV indexes sit at
  the end, so a partial file is not demuxable. This already exists as the offline **Downloads** feature —
  correct tool when the user is willing to wait.
- iOS cannot install a filesystem/FUSE layer to fake one growing 3 GB file.

---

## 5. Already fixed in 0.5.6029 (don't re-fix)

All in [LocalCacheProxy.swift](../iosApp/iosApp/Player/LocalCacheProxy.swift) unless noted:

1. **Sleep-blind idle detection.** Idle/stall timestamps used `ProcessInfo.systemUptime`
   (`mach_absolute_time`), which **freezes while the device sleeps**. After screen-lock the proxy judged
   a dead stream "healthy" and never reconnected. All such timestamps now use `saminNow()`
   (`mach_continuous_time`) — see the "Sleep-aware clock" section near the top of the file.
2. **Foreground wake with no forward downloader did nothing** — it now restarts from the chunk a parked
   client is waiting on (`ProxySession.handleForegroundWake`).
3. **Clients parked forever on first load.** `ForwardDownloader`'s response handler discovered the size
   from its own GET but never called `notifyHeadersAvailable()`, so a player that connected before the
   HEAD finished (or whose HEAD gave no `Content-Length`) waited forever with no response headers. Now it
   wakes them and captures the real `Content-Type`.
4. **Inflated `totalSize`.** For an HTTP 200 the code computed `total = streamOffset + Content-Length`,
   wrong whenever the host ignores `Range`; that scaled every cached range on the timeline. Now `len` for
   200, `offset + len` only for 206.
5. **Listener readiness gating.** `NWListener(using:on:)` does not throw on a taken port (failure arrives
   later as `.failed`), so the old code handed the player a URL before anything was bound. Now
   `ensureListener()` only reports true on a real `.ready`, stale `.ready` from a replaced listener is
   ignored, and `startSession` falls back to the direct URL instead of hanging.
6. **Seek tolerance is forward-only.** The 4 MB tolerance now only applies at/ahead of the write head; a
   request behind it that is not on disk falls through and repositions instead of waiting forever.
7. **Timeline drew only the first 8 cached spans** the proxy sent (it sends up to 32) —
   [PlayerTimeline.kt](../composeApp/src/commonMain/kotlin/com/nuvio/app/features/player/PlayerTimeline.kt).
8. **Diagnostics**: Refresh button + app/session context, free space, cached MB/%, HEAD vs GET,
   rate-limit state, write errors, reconnect counts —
   [PlayerDiagnosticsDialog.kt](../composeApp/src/commonMain/kotlin/com/nuvio/app/features/player/PlayerDiagnosticsDialog.kt)
   and `getDiagnosticReport` in TempPlaybackCache.kt.

Also present in 0.5.6029 from the same commit: HTTP 429/503 backoff with `Retry-After`
(`ProxyRetryAfter`), rate-limit-aware watchdog/probe/reconnect, and per-session diagnostic counters.

---

## 6. Known issues (status as of 0.5.6033)

- **Player's URL resolved once** in `PlayerDestination.kt:50` (`remember(launch)`); never re-resolved
  on foreground. Harmless while port fixed — see Step 2b.
- **MPV cache/readahead — DONE in `4aaafd49` (0.5.6031).** `cache=yes`,
  `demuxer-max-bytes=64 MB`, `demuxer-readahead-secs=30`. **Watch for conflict with proxy**
  (two layers buffering) on device test.
- **`saminProxyMinResumeBytes = 0`** — no shock absorber. Set to 0 in 0.5.6028 to fix 20 s seek stall;
  changing it risks stall returning. Comment clarified in `b41519e4`. Revisit if starved packets appear.
- **`saminProxySegmentBytes` — DELETED in `98132fc9` (0.5.6033).** Dead constant removed.
- **`queue.sync` on Kotlin main thread — OFFLOADED in `2a9830b0` (0.5.6033).** Bridge calls
  (`startSession`, `setPlayhead`, `diagnosticReport`, `cacheStatsJson`, `cachedRangesJson`) now run
  on `Dispatchers.IO` via `withContext` / `scope.launch`.
- **Low-space constants — ALIGNED in `c6caa3aa` (0.5.6033).** Proxy now uses 300 MB
  (`saminProxyLowSpaceBytes`), matching Kotlin `LOW_SPACE_STOP_BYTES`.
- **Parked client timeout — ADDED in `1bdb4312` (0.5.6033).** 15 s timer in
  `ProxyConnection.startHeadersWaitTimer()` fails the waiter if upstream never sends headers.

---

## 7. Build history: what each build changed, what it broke, what it fixed

Tag → the exact commit that was built (`git rev-parse <tag>`). The publish commit follows it.

| Release | Date | Player/cache content | Note |
|---|---|---|---|
| 0.5.3-135002 | 09-27 | `250c2dbd` gray saved segment on timeline | grey bar introduced |
| 0.5.3-samin1 | 09-27 | `b79ecd9d` revert MPV tuning to official; solid gray | **MPV buffering turned off here** |
| 0.5.3-samin2 | 09-28 | `3fe7c45d` drop official buffered tint | |
| 0.5.3005 | 09-28 | position-aware mirror from playhead; backward cache; eviction; `da54ccf4` named arg | build-break fixes |
| 0.5.3006 | 09-28 | `694d74bb` **loopback cache proxy introduced**; proof-of-life toasts | start of the proxy era |
| 0.5.4007 | 09-28 | `68dcad29` proxy audit: chunk-relative reads, 206 discipline, session validity, backpressure; + 6 Swift syntax fixes (`try` on NWListener, port type, closures, braces, loopback-only accept) | first proxy logic + compile breaks |
| 0.5.4008 | 09-28 | `b42abc2b` route **all** stream switches through the proxy | before this, switching stream silently bypassed cache |
| 0.5.4009–4011 | 09-28/29 | continuous forward prefetch → 32 MB chunks/buffering → `d1b7024d` single continuous forward downloader | throughput experiments begin |
| 0.5.4012 | 09-29 | cache speed + cached size indicator | |
| 0.5.4014 | 09-29 | `b999533d` align forward caching to playhead; `bc93dcf4` premature completion on next episode + prevent stalls | |
| 0.5.4015 | 09-29 | `19f438b2` conflicting sessionKey overloads (Kotlin compile break, CI failed in 4m20s); `fa8171dd` next-episode **session collision**, remove fsync, throughput | |
| 0.5.4016 | 09-30 | time display stuck on next episode | |
| 0.5.4017 | 09-30 | restore high-throughput URLSession + proxy queue bottlenecks | |
| 0.5.4018 | 09-30 | `8dfc75cc` start forward caching 1 s before playhead; restore skip intro/seeking | |
| 0.5.4019 | 09-30 | `bd34c8e7` restore URLSession delegate (Swift compile break); `3783b788` **fix background/foreground crash on device sleep** + slow next episode + buffering on seek | **attempt #1 at the sleep/wake symptom** |
| 0.5.4020 | 09-30 | `73e7d96b` import UIKit (Swift compile break); `61efd8b2` **diagnostics report** + fix seek thrashing | |
| 0.5.5021 | 09-30 | `ef87b658` stall watchdog, 32 MB bounded segments, pre-buffering margin | the hold-back that later caused a stall |
| 0.5.5022 | 10-01 | `773362db` 4-worker round-robin chunk downloader; `6001e251` **background suspension socket refusal** + sweep on start/close | **attempt #2 at the sleep/wake symptom** |
| 0.5.5023 | 10-01 | `a59fa8cc` sliding-window throttle, non-truncating resume, header probe, trickle watchdog | 4-worker replaced |
| 0.5.5024 | 10-01 | `8ad56b23` **revert to single continuous stream-to-disk**; `2944d21e` single-writer chunk mutex, 16 MB chunks, warm TCP pooling | the pendulum swings back |
| 0.5.5025 | 10-01 | (upstream only) | |
| 0.5.5026 | 10-02 | `22c9ab20` preload next episode sources, auto-play timeout blocking cached results | |
| 0.5.6027 | 10-02 | `a0b55d42` **auto-recover playback on sleep/wake** + seek latency work | **attempt #3 at the sleep/wake symptom** |
| 0.5.6028 | 10-02 | `7e0e7454` 4 MB bidirectional seek tolerance; `e8ef8c71` fix 20 s seek stall (EOF probe 8 MB→32 MB, remove pump hold-back) | |
| **0.5.6029** | 10-03 | `c164cd6d` the 8 fixes in section 5 | |
| 0.5.6030 | 10-03 | `2cdcbea9` rate-limit backoff (429/503 + `Retry-After`), foreground debounce, grey-bar byte↔time map (`pendingSeekByte`+`rateSamples`), `recoverListener()`; `e381da02` monotonic prefetcher + per-chunk dedicated fetches (kills index-vs-playhead ping-pong); `cccab099` `NWConnection.State.waiting` pattern match | |
| 0.5.6031 | 10-03 | `4aaafd49` seek fixes, pause-aware battery, grey bar via MPV stream-pos, MPV readahead cache re-added, unknown-size handling, chunk-fetcher diagnostics; `95cdab67`/`20732f18` brace/indent compile fixes; `f4404174`/`1f51ae83`/`cf279c83` gitmodules; `9c323b8c`/`f6e3a9a7` duplicate `getIsPlaying()` | |
| 0.5.6032 | 10-03 | `b273fb7a` keep forward downloader running during pause; `d6815b3e` match `setPlayhead` signature + CI caching; `761d63d6` backward-seek re-anchor, adaptive 32→128 MB window, skip cached runs, wire `streamPos` | |
| 0.5.6033 | 10-03 | **6 future-work items**: `98132fc9` delete dead constant `saminProxySegmentBytes`; `c6caa3aa` align low-space 300 MB; `becc64b8` Step 2c preserve cache on re-resolve; `1bdb4312` parked-client 15 s header timeout; `2a9830b0` offload bridge calls to IO; `b41519e4` minResumeBytes comment | building (`37146306907`) |

**What the history shows:**
- The **sleep/wake death was attempted three times in three different layers** (4019 "device sleep crash",
  5022 "background suspension socket refusal", 6027 "auto-recover on sleep/wake") and never fixed, because
  nobody changed the two invariants: (a) the URL given to MPV must point at a live server forever, and
  (b) "is the stream idle?" must be measured with a clock that counts sleep. 0.5.6029 fixes both.
- A **throughput ↔ stall pendulum** runs through the whole series: 5021 hold-back → 5022 multi-worker →
  5023 throttle → 5024 back to single stream → 6028 remove hold-back. Each fixed one symptom and moved
  the pressure elsewhere.
- Several builds were **compile-break fixes** (4007, 4019, 4020), which is why CI had hard failures on
  09-29 17:15 (4m20s — pre-flight/Kotlin) and 09-30 10:13 + 14:41 (long — xcodebuild).
- The **grey bar was attacked three times** (0.5.3, samin2, 4018) and never root-caused; the real causes
  were the byte-vs-duration mapping, the inflated `totalSize`, and the 8-span cap — all in 0.5.6029.

---

## 8. Commands and gotchas

```bash
# status of the running publish
gh run list -R Saminahmed7/NuvioMobile -w "Nuvio Samin sync and build" -L 3
gh run view <run-id> -R Saminahmed7/NuvioMobile

# trigger another publish (needs a push first — the runner builds the pushed branch)
git push origin HEAD:samin-temp-cache
gh workflow run samin-sync-and-build.yml -R Saminahmed7/NuvioMobile --ref samin-temp-cache

# release/tag that was produced
gh release list -R Saminahmed7/NuvioMobile -L 3
```

- **Cannot build iOS locally:** this machine is Windows/MSYS with no Xcode. The CI pre-flight
  (`swiftc -parse` for LocalCacheProxy.swift + `compileKotlinIosArm64`) is the syntax/compile gate.
  Semantic behaviour can only be confirmed on the device.
- **Samin-only files** (not in upstream, so upstream merges cannot conflict on them):
  `LocalCacheProxy.swift`, `TempPlaybackCache.kt`, `PlayerDiagnosticsDialog.kt`.
  `PlayerTimeline.kt` **is** upstream-owned — expect conflicts there eventually.
- The workflow merges `upstream/cmp-rewrite` before building and pushes the merge + a
  `chore(samin): publish X` commit to the branch. Expect `git pull --rebase` before pushing.
- Version numbering is automatic: `major.minor.(patch*1000 + release_count + 1)`; next build after
  0.5.6033 is 0.5.6034.


---

## 11. Current future-work queue (prioritized, update as you go)

> **Rule:** do one item, verify (CI pre-flight at minimum; device test if possible), update this list, commit, repeat. Don't stack changes.

| # | Item | File(s) | Risk | Notes |
|---|------|---------|------|-------|
| 1 | **Delete dead constant `saminProxySegmentBytes`** (64 MB, unused) | `LocalCacheProxy.swift:51` | Zero | **DONE** in `98132fc9` (0.5.6033). Safe removal; no callers. |
| 2 | **Align low-space constants** — proxy 500 MB vs Kotlin 300 MB | `LocalCacheProxy.swift:47`, `TempPlaybackCache.kt:79` | Low | **DONE** in `c6caa3aa` (0.5.6033). Proxy now uses 300 MB. |
| 3 | **Step 2c — preserve cache on same-stream re-resolve** | `TempPlaybackCache.kt:117–160`, `LocalCacheProxy.swift:423–458`, `ProxySession.updateSourceUrl` | Medium | **DONE** in `becc64b8` (0.5.6033). Kotlin reuses session key; Swift updates upstream URL in-place. |
| 4 | **Add timeout for parked clients** (upstream never responds) | `LocalCacheProxy.swift` `ProxyConnection.startHeadersWaitTimer` | Medium | **DONE** in `1bdb4312` (0.5.6033). 15 s timer fires if headers don't arrive. |
| 5 | **Offload `queue.sync` calls off Kotlin main thread** | `TempPlaybackCache.kt`, `PlayerScreenRuntimeEffects.kt`, `PlayerScreenRuntimeSourceActions.kt` | Medium | **DONE** in `2a9830b0` (0.5.6033). Bridge calls run on `Dispatchers.IO`. |
| 6 | **Evaluate `saminProxyMinResumeBytes = 0`** — risk of 20 s seek stall | `LocalCacheProxy.swift:50`, `ForwardDownloader` pump logic | Medium/High | **EVALUATED** in `b41519e4` (0.5.6033). Left at 0; comment clarified. |
| 7 | **Test MPV cache vs proxy conflict** (both buffering) | `MPVPlayerBridge.swift:519–520` | Medium | **Pending device test.** 0.5.6031 re-added `cache=yes`, `demuxer-max-bytes=64 MB`, `demuxer-readahead-secs=30`. Verify no double-buffer starvation on slow links. |
| 8 | **Step 3 — libmpv stream callbacks (`samin://` scheme)** | New Swift file, `MPVPlayerBridge.swift`, remove `LocalCacheProxyServer` | **High** | Major rewrite. Replaces NWListener/HTTP entirely. Requires device-only validation (blocking `read`, `seek`, `cancel` on MPV stream thread). Only if above items don't solve remaining issues. |

**Next action for this session:** Item 7 requires device test (MPV cache vs proxy conflict). Item 8 is a major rewrite — only if issues persist after 0.5.6033 device validation. Consider monitoring 0.5.6033 test reports first.

## 9. Gray bar byte↔time mapping — COMMITTED in `2cdcbea9`

**Symptom measured on-device (0.5.6029, Dept. Q S1E3, 3130 MB / 54:44).** Pixel-sampled the
screenshot track: the played bar ended at fraction **0.582** (= position 31:58/54:44 = 0.584, so
the played bar is exactly the playhead), but the gray saved span started at **0.594** — a
**1.2% (~39 s) dark gap** ahead of the playhead. Root cause is the byte-vs-duration mismatch: the
played bar is drawn in *time* while the saved spans were drawn in *byte* fractions, so on this VBR
file bytes ran ~1.6% ahead of seconds.

**Fix (in `LocalCacheProxy.swift`, landed in `2cdcbea9`):**
- Every FD reposition (`startNewForwardDownloader`) records the byte it targets as `pendingSeekByte`.
- The next playhead report (within 3 s, via `onPlayheadUpdated` -> `recordPlayheadSample`) pairs that
  byte with the reported time fraction into a `rateSamples` anchor, rejecting any pair whose |t - b|
  exceeds 0.10 (filters an index/moov probe at byte 0 or a stale pairing).
- `cachedRangesJson()` now runs each endpoint through `byteFractionToTime`: identity with no samples,
  a constant shift with one anchor, piecewise-linear (with slope extrapolation) with two or more.
- Verified numerically: anchor (t=0.584, b=0.600) maps byte 0.600 -> time 0.584, closing the gap.

**Built in 0.5.6030.** No Kotlin logic change was needed.

## 10. "Playback error ... Connection refused" on re-entry — FIXED in `c164cd6d` / `2cdcbea9`

Symptom (0.5.6029, after the screen-lock issue): re-entering the stream produced a fresh
launch `p3_3` whose URL `http://127.0.0.1:19842/s/p3_3/file` was refused:

```
[ffmpeg] tcp: Connection to tcp://127.0.0.1:19842 failed: Connection refused
[stream] Failed to open http://127.0.0.1:19842/s/p3_3/file
[mpv] loading failed
```

Root cause: iOS reclaims the listening socket when the app is suspended (screen lock)
but `NWListener` keeps reporting `.ready`, so `ensureListener()` returned true and
`startSession` handed MPV a dead localhost URL. MPV's loopback auto-retry (3x) then
failed against the same dead port and showed the fatal error screen. The old code also
rotated ports (19842..19849) after bind failures, which strands any URL MPV already holds.

Fix (all in `LocalCacheProxy.swift`, plus one call site in `MPVPlayerBridge.swift`):
1. One fixed loopback port for the process lifetime (`activeBoundPort = 19842`).
   Removed `preferredPorts`/`preferredPortIndex`/`listenerFailureStreak`/`advanceBoundPort`.
   `resetListener` now retries the SAME port (SO_REUSEADDR via `allowLocalEndpointReuse`).
2. `probeAccepting()`: a real synchronous loopback connect (0.75s) before `startSession`
   returns a URL. `.ready` alone is no longer trusted; if the port refuses, the listener
   is rebuilt and the probe retried.
3. Background awareness: `ensureForegroundObserver()` (registered once from `warmup`)
   sets `wentToBackground` on `didEnterBackgroundNotification`. Returning from a real
   background force-rebuilds the listener on the same fixed port, so an already-held
   URL keeps working. `ensureListener` no longer cancels a listener that is still
   `.setup`/`.waiting`, so the back-to-back willEnterForeground + didBecomeActive
   pair does not thrash the bind.
4. `recoverListener()`: public recovery entry point; `MPVPlayerBridge`'s `MPV_EVENT_END_FILE`
   loopback retry now calls it instead of `warmup()`, so the retry re-establishes the
   socket rather than hitting the dead address again.

Kotlin: no logic change needed. With a fixed port the URL never goes stale, so the
planned "re-resolve on foreground" is unnecessary for this failure.

**Built in 0.5.6029 / 0.5.6030.**
