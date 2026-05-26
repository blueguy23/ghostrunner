# Incident Log

Operational incidents encountered while running ghostrunner. Each entry documents the symptoms, root cause, and fix — the kind of operational scar tissue that only comes from actually running infrastructure.

---

## INC-001: Clock sync loop silently failing since inception

**Date:** 2026-05-25
**Severity:** Medium
**Duration:** Present since initial deployment (undetected)

### Symptoms
- Both runners showed `[CLOCK] WARNING: chronyc makestep failed — drift may be accumulating` every 60 seconds
- After extended uptime (hours), runners entered "Retrying until reconnected" loop — TLS handshakes to GitHub API failed due to clock skew
- Runners appeared "online" in container healthcheck but were functionally dead
- Watchdog detected the retry loop but couldn't recover because the underlying clock drift persisted across re-registrations

### Root cause
The `entrypoint.sh` starts `chronyd` and runs the initial `chronyc makestep` **as root**, then drops privileges to the `garci` user via `gosu`. The `_clock_sync_loop` in `background-loops.sh` runs as `garci` and calls `chronyc makestep` every 60 seconds — but `makestep` requires root access to the chronyd command socket.

Every sync attempt after boot failed silently (logged a warning but took no corrective action). The initial boot sync was the only one that ever worked. Once WSL2 accumulated enough drift (typically after host sleep/wake), TLS broke and the runner couldn't reach GitHub.

### Root cause (three layers deep)

1. **`minpoll`/`maxpoll` as global directives crashed chronyd.** Chrony 4.2 treats these as per-source options. Having them standalone caused a parse error, preventing `chronyd` from starting at all. The `ntpdate` fallback masked the failure at boot — a one-shot sync succeeded but left no daemon running.

2. **`makestep` is a privileged command.** Even after fixing the config and getting `chronyd` to start, `chronyc makestep` requires root. `cmdallow` only authorizes connections, not write operations. The non-root background loop could never force a clock step.

3. **The background loop was unnecessary.** `chronyd` with `makestep 1.0 -1` in its config auto-steps whenever drift exceeds 1 second. The loop only needed to *monitor* drift (via read-only `chronyc tracking`), not *correct* it.

### Fix (three commits)
1. Moved `minpoll 4 maxpoll 8` onto the `pool` directives so chronyd parses the config successfully
2. Added `bindcmdaddress 127.0.0.1` and `cmdallow 127/8` so non-root users can connect to chronyd
3. Replaced `chronyc makestep` (privileged write) with `chronyc tracking` (read-only monitoring) — chronyd handles correction automatically

### Lessons
1. **Silent failures are worse than crashes.** The loop logged a warning but never escalated. `chronyd` failing to start was masked by the `ntpdate` fallback. Two separate silent failures compounded.
2. **Privilege boundaries need testing.** The clock sync was tested manually as root during development but never verified post-gosu.
3. **The watchdog masked the root cause.** The watchdog restarted the runner process, which re-registered successfully (using the still-valid boot clock sync), hiding the fact that the ongoing sync was broken.
4. **Understand what the daemon already does.** `chronyd` with `makestep 1.0 -1` auto-corrects drift. The background loop was trying to do what the daemon already handles — the loop's job was monitoring, not correction.

---

## INC-002: Ephemeral runner stuck after job completion

**Date:** 2026-05-25
**Severity:** Low
**Duration:** ~15 minutes (until manual restart)

### Symptoms
- After completing a CI job, both runners showed "Listening for Jobs" but didn't pick up a newly queued run
- GitHub Settings > Actions > Runners showed both runners as "offline"
- `docker compose up -d` reported "Running" (not "Started") — containers weren't restarting

### Root cause
The ephemeral runner loop re-registers after each job. After the PR CI job completed, the runners attempted to re-register but the accumulated clock drift (from INC-001) caused TLS failures on the GitHub API call to get a new registration token. The runners fell into the "Retrying until reconnected" state but the watchdog's 30-second grace period kept seeing brief "Listening for Jobs" messages and standing down.

`docker compose up -d` only starts stopped containers — since these were still running (just stuck), it reported "Running" and did nothing.

### Fix
`docker compose restart runner-1 runner-2` forced a full restart, triggering the entrypoint's root-level clock sync and fresh registration.

Long-term fix is INC-001 — once the background clock sync actually works, drift won't accumulate to TLS-breaking levels.

### Lessons
1. **`docker compose up -d` is not `restart`.** For stuck containers, you need `restart` or `down && up`.
2. **Cascading failures are subtle.** Clock drift (INC-001) caused TLS failure, which caused registration failure, which caused the runner to appear stuck, which caused the watchdog to flap between "stuck" and "recovered." Four layers deep from the root cause.
