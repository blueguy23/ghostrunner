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

### Fix
- Added `bindcmdaddress 127.0.0.1` and `cmdallow 127/8` to `chrony.conf` so `chronyd` accepts commands from any local user over the loopback interface
- Updated `background-loops.sh` to use `chronyc -h 127.0.0.1` to connect via the network command socket instead of the Unix socket
- Explicitly passed `-f /etc/chrony/chrony.conf` to `chronyd` startup

### Lessons
1. **Silent failures are worse than crashes.** The loop logged a warning but never escalated — it should have counted consecutive failures and reported unhealthy after a threshold.
2. **Privilege boundaries need testing.** The clock sync was tested manually as root during development but never verified post-gosu. A simple `whoami` in the loop would have caught this immediately.
3. **The watchdog masked the root cause.** The watchdog restarted the runner process, which re-registered successfully (using the still-valid boot clock sync), hiding the fact that the ongoing sync was broken. Recovery looked healthy but the underlying condition was never fixed.

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
