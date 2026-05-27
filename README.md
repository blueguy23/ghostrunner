# ghostrunner

Self-hosted GitHub Actions runner infrastructure for [bill-tracker](https://github.com/blueguy23/bill-tracker). Two ephemeral runners + shared MongoDB in Docker Compose, designed for WSL2 on a single machine.

## Why this exists

**GitHub-hosted runners can't reach a local MongoDB.** The bill-tracker CI pipeline runs E2E tests against a real database — not mocks. GitHub-hosted runners would need either a cloud-hosted MongoDB (cost) or service containers that reset on every run (complexity). A self-hosted runner on the same Docker network as MongoDB is simpler and free.

**WSL2 introduces failure modes that don't exist elsewhere.** Clock drift after host sleep/wake breaks TLS. TCP keepalives default to 2 hours, so dead connections go undetected. DNS silently breaks after VPN cycles. Every sidecar in this stack exists to handle a specific WSL2 failure mode — see [INCIDENTS.md](INCIDENTS.md) for the ones we've actually hit.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  docker compose                                                     │
│                                                                     │
│  ┌──────────────┐  ┌──────────────┐                                 │
│  │  ci-runner-1  │  │  ci-runner-2  │  Ephemeral runners             │
│  │              │  │              │  Register → run 1 job → repeat  │
│  │  entrypoint  │  │  entrypoint  │                                 │
│  │  ├ chronyd   │  │  ├ chronyd   │  Clock sync (WSL2 drift)        │
│  │  ├ watchdog  │  │  ├ watchdog  │  Kill stuck retry loops         │
│  │  ├ token-wt  │  │  ├ token-wt  │  PAT expiry detection           │
│  │  └ run.sh    │  │  └ run.sh    │  GitHub runner binary           │
│  └──────┬───────┘  └──────┬───────┘                                 │
│         │                 │                                          │
│         └────────┬────────┘                                          │
│                  │                                                   │
│         ┌────────▼────────┐                                          │
│         │    ci-mongo      │  MongoDB 7.0 — shared test database     │
│         │    (mongo:27017) │  CI jobs connect here, not localhost     │
│         └─────────────────┘                                          │
│                                                                     │
│  ┌──────────────┐  ┌──────────────┐                                 │
│  │   autoheal    │  │  disk-watcher │  Sidecars                      │
│  │  Restarts     │  │  Prunes Docker│                                │
│  │  unhealthy    │  │  when disk    │                                │
│  │  containers   │  │  < 10GB free  │                                │
│  └──────────────┘  └──────────────┘                                  │
└─────────────────────────────────────────────────────────────────────┘
```

### Lifecycle of a single job

```
1. entrypoint.sh starts as root
2. preflight-check.sh validates PAT, scopes, binaries
3. chronyd starts, initial clock step, DNS fallback written
4. gosu drops to runner user
5. Background loops start (clock monitor, PAT re-validation)
6. Runner registers as ephemeral via GitHub API
7. run.sh picks up one job from the queue
8. Job completes → runner auto-deregisters (ephemeral)
9. Loop back to step 6
```

### Watchdog + circuit breaker

WSL2 silently drops long-poll connections. The runner enters a "Retrying until reconnected" loop that never self-recovers. The watchdog detects this pattern in the runner log and kills the process so the main loop re-registers fresh.

The circuit breaker prevents infinite restart loops: if the watchdog fires more than `WATCHDOG_MAX_FIRES` times within a 1-hour window, it backs off for 10 minutes before resetting. This stops thrashing when the root cause isn't recoverable by restarting (e.g., expired PAT, sustained network outage).

### Healthcheck layers

| Layer | What it checks | Action on failure |
|-------|---------------|-------------------|
| **Docker healthcheck** (`deep-healthcheck.sh`) | Queries GitHub API — is this runner actually "online"? | Marks container unhealthy after 3 consecutive failures |
| **Autoheal sidecar** | Watches for unhealthy containers | Restarts the container |
| **Watchdog** (in entrypoint) | Watches runner log for "Retrying until reconnected" | Kills runner process → main loop re-registers |
| **Token watch** (background loop) | Re-validates PAT against GitHub API every 6 hours | Writes `/tmp/token-invalid` sentinel → healthcheck reports it |
| **Clock monitor** (background loop) | Reads chronyd offset every 60 seconds | Warns if drift > 2 seconds (chronyd auto-corrects via `makestep 1.0 -1`) |

## Decision log

### Ephemeral over persistent runners

Persistent runners accumulate state: stale credentials files, leftover build artifacts, environment pollution between jobs. Ephemeral runners re-register after every job, so each CI run starts clean. The tradeoff is ~5 seconds of registration overhead per job — negligible against a 4-minute pipeline.

### Chrony over ntpdate

`ntpdate` is a one-shot sync — it corrects the clock once at boot and never again. WSL2 drifts every time the host sleeps, which can happen multiple times per day. `chronyd` runs as a daemon and auto-steps when drift exceeds 1 second (`makestep 1.0 -1`). The background loop only *monitors* drift — it doesn't correct it. See [INC-001](INCIDENTS.md#inc-001-clock-sync-loop-silently-failing-since-inception) for what happened when we tried to correct from userspace.

### Circuit breaker thresholds (5 fires / 1 hour / 10 min backoff)

These were tuned from real incidents. A healthy runner fires the watchdog 0-1 times per day (brief network blips). 5 fires in an hour means something systemic is wrong — clock drift, expired PAT, GitHub outage. The 10-minute backoff is long enough for transient GitHub issues to clear but short enough that the runner recovers within a reasonable window.

### SYS_TIME capability + Docker socket mount

Both are security tradeoffs documented as `RISK ACCEPTED` in `docker-compose.yml`:
- **SYS_TIME** is required for chrony to step the system clock. No alternative exists that preserves clock correction. Acceptable for a single-user local runner; do not replicate to shared environments.
- **Docker socket** grants effective root on the host. Acceptable because this runner only executes trusted code (our own repo). If the runner ever processes untrusted PRs (forks, external contributors), replace with `tecnativa/docker-socket-proxy`.

### TCP keepalive tuning (60/10/6)

WSL2's default keepalive is 7200 seconds — dead connections go undetected for 2 hours. The runner's long-poll to GitHub silently dies, and the process hangs until the OS timeout. `60/10/6` detects a dead connection within ~2 minutes (60s initial + 6 probes × 10s).

## Setup

### Prerequisites

- Docker and Docker Compose
- A GitHub PAT with `repo` scope
- The runner binary tarball (`actions-runner.tar.gz`) in the project root

### Quick start

```bash
# 1. Download the runner binary
curl -fsSL https://github.com/actions/runner/releases/download/v2.322.0/actions-runner-linux-x64-2.322.0.tar.gz \
  -o actions-runner.tar.gz

# 2. Configure environment
cp .env.example .env
# Edit .env — set GITHUB_PAT, REPO_OWNER, REPO_NAME, DOCKER_GID

# 3. Build and start
docker compose build
docker compose up -d

# 4. Verify runners are online
docker compose logs -f runner-1 runner-2
# Look for: "Runner registered. Waiting for a job..."
```

### Environment variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `GITHUB_PAT` | Yes | — | PAT with `repo` scope |
| `REPO_OWNER` | Yes | — | GitHub username or org |
| `REPO_NAME` | Yes | — | Repository name |
| `DOCKER_GID` | Yes | `1001` | GID of `/var/run/docker.sock` on host (`stat -c '%g' /var/run/docker.sock`) |
| `DOCKERHUB_USERNAME` | No | — | Prevents anonymous pull rate limits |
| `DOCKERHUB_TOKEN` | No | — | Docker Hub access token |
| `PRUNE_THRESHOLD_GB` | No | `10` | Disk watcher prunes below this |
| `RUNNER_CPUS` | No | `3.0` | CPU cap per runner container |
| `SESSION_CONFLICT_WAIT` | No | `30` | Seconds to wait on session conflict before retry |
| `WATCHDOG_MAX_FIRES` | No | `5` | Watchdog restarts before circuit breaker trips |

## Operations

```bash
# Start everything
docker compose up -d

# View logs (both runners)
docker compose logs -f runner-1 runner-2

# View single runner
docker compose logs -f runner-1

# Restart stuck runners (not `up -d` — that only starts stopped containers)
docker compose restart runner-1 runner-2

# Stop (deregisters runners from GitHub automatically)
docker compose down

# Check runner health
docker inspect --format='{{.State.Health.Status}}' ci-runner-1

# Check clock drift inside a runner
docker exec ci-runner-1 chronyc tracking
```

### Upgrading the runner binary

```bash
curl -fsSL <new-release-url> -o actions-runner.tar.gz
docker volume rm runner_runner-1-config runner_runner-2-config
docker compose build && docker compose up -d
```

Config volumes must be deleted — the old runner binary caches its version in the config directory.

### Shared volumes

| Volume | Purpose | Shared? |
|--------|---------|---------|
| `runner-N-config` | Runner binary + registration state | Per-runner |
| `runner-N-work` | Job workspace (`_work/`) | Per-runner |
| `playwright-cache` | Chromium binaries for E2E tests | Shared |
| `pnpm-store` | pnpm content-addressable store | Shared |
| `mongo-data` | MongoDB data directory | Shared |

Playwright and pnpm caches are shared to avoid downloading ~400MB of binaries on every job. `docker volume prune` is intentionally omitted from the disk watcher — it would wipe these caches.

## File map

```
ghostrunner/
├── Dockerfile              # Ubuntu 22.04 + Node 22 + runner binary + Playwright deps
├── docker-compose.yml      # 2 runners + MongoDB + autoheal + disk watcher
├── entrypoint.sh           # Root setup → gosu → ephemeral runner loop + watchdog
├── chrony.conf             # Aggressive NTP sync for WSL2 clock drift
├── deep-healthcheck.sh     # Queries GitHub API to verify runner is actually online
├── disk-watch.sh           # Sidecar: prunes Docker artifacts when disk is low
├── .env.example            # All configuration variables with descriptions
├── INCIDENTS.md            # Operational incident log
└── scripts/
    ├── registration.sh     # Token fetch, runner register/deregister (sourced)
    ├── background-loops.sh # Clock monitor + PAT re-validation loops (sourced)
    └── preflight-check.sh  # Validates PAT scopes, binaries, env vars before start
```
