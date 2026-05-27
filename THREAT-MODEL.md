# Security Threat Model

Threat model for ghostrunner — a self-hosted GitHub Actions runner stack running on a single-user WSL2 machine. This document formalizes the `RISK ACCEPTED` comments in `docker-compose.yml` into a structured analysis.

## Scope

- 2 ephemeral runner containers + 1 MongoDB + 2 sidecars (autoheal, disk-watcher)
- Runs on a personal development machine (WSL2 on Windows)
- Executes only trusted code from a single private repository
- No external contributors, no fork PRs, no public-facing network services

## Trust assumptions

1. **The repository is private and single-owner.** All code that runs on these runners was committed by the repo owner. If the repo accepts external PRs, this model breaks.
2. **The host machine is single-user.** No other users have shell access to the WSL2 instance.
3. **The network is a home network behind NAT.** Containers are not exposed to the internet.

---

## T-001: Docker socket mount — container escape to host root

**Asset:** Host filesystem, host Docker daemon
**Threat:** A compromised runner container can use the mounted Docker socket to spawn a privileged container, mount the host filesystem, and achieve full root access.
**Likelihood:** Low — requires either a supply-chain attack in a CI dependency or a malicious commit to the repo.
**Impact:** Critical — full host compromise.

**Current control:** Only trusted code (single-owner private repo) is executed.

**Risk status:** ACCEPTED for single-user local runner executing only trusted code.

**Escalation trigger:** Before running untrusted PRs (forks, Dependabot with custom scripts, external contributors). Replace socket mount with `tecnativa/docker-socket-proxy` whitelisting only the required API calls (container create, image pull, image build).

---

## T-002: SYS_TIME capability — kernel attack surface

**Asset:** Host kernel
**Threat:** `SYS_TIME` allows the container to call `clock_settime()` and related syscalls. While primarily used for chrony clock correction, it broadens the kernel syscall surface available for container escape exploits.
**Likelihood:** Very low — requires a kernel vulnerability in the time subsystem that is exploitable from an unprivileged container with SYS_TIME.
**Impact:** High — potential container escape.

**Current control:** No mitigation available that preserves clock correction. Chrony requires `SYS_TIME` to step the system clock — without it, WSL2 clock drift accumulates until TLS breaks (see INC-001).

**Risk status:** ACCEPTED for local runner. The tradeoff is: SYS_TIME exposure vs. guaranteed TLS failures from clock drift.

**Escalation trigger:** Before replicating this runner pattern to shared or cloud environments. In multi-tenant setups, consider running chrony on the host and syncing the container clock via `--pid=host` or a shared `/dev/shm` time file.

---

## T-003: GITHUB_PAT scope and lifetime

**Asset:** GitHub repository (actions, code, settings)
**Threat:** The PAT has `repo` scope — if leaked (logs, process listing, environment dump), it grants full read/write access to all private repos of the owning user.
**Likelihood:** Medium — PATs are long-lived and the token is present in the container's environment (visible via `/proc/*/environ`).
**Impact:** High — repository compromise, code tampering, secret exfiltration from other repos.

**Current controls:**
- PAT is injected via `.env` file (gitignored, never committed)
- Preflight check validates PAT scope at startup and logs a warning if it has excessive permissions
- Token watch loop re-validates every 6 hours and writes a sentinel if expired
- Container logs never print the token value (environment variables, not CLI args)

**Residual risk:** A process inside the container can read the PAT from its own environment. If a CI job runs `env` or `printenv`, the token appears in the job log (GitHub redacts known secrets, but the PAT format may not be in the redaction list for self-hosted runners).

**Recommendation:** When GitHub supports it, use fine-grained PATs scoped to a single repository with only `actions:write` permission. Until then, use a classic PAT on a machine account with access to only the target repo.

---

## T-004: MongoDB — unauthenticated access

**Asset:** CI test data in MongoDB
**Threat:** MongoDB runs with no authentication (`--bind_ip_all`, no `--auth`). Any container on the Docker network can read/write all databases.
**Likelihood:** Low — only containers in the compose network can reach MongoDB (no port mapping to host).
**Impact:** Low — the database contains only ephemeral CI test data, reset on every run.

**Current control:** No host port mapping. MongoDB is only accessible via the Docker compose network (`mongo:27017`).

**Risk status:** ACCEPTED. The data is ephemeral test fixtures with no sensitive content.

**Escalation trigger:** If MongoDB begins storing persistent state, runner metrics, or anything beyond throwaway test data, add `--auth` and a credentials file.

---

## T-005: Autoheal sidecar — Docker socket access

**Asset:** All containers managed by Docker
**Threat:** The autoheal sidecar has Docker socket access to restart unhealthy containers. If compromised, it could stop/remove any container on the host.
**Likelihood:** Very low — autoheal is a small, well-audited image pinned by SHA256 digest.
**Impact:** Medium — could disrupt all Docker workloads on the host.

**Current control:** Image pinned to a specific SHA256 digest (not a mutable tag). No code execution beyond the autoheal binary.

**Risk status:** ACCEPTED. The blast radius is limited to container lifecycle operations — no filesystem or network access beyond the socket.

---

## T-006: Supply-chain — CI dependency poisoning

**Asset:** Runner container, host (via Docker socket)
**Threat:** A compromised npm package, GitHub Action, or Playwright binary could execute arbitrary code inside the runner container. Combined with the Docker socket mount (T-001), this escalates to host compromise.
**Likelihood:** Low-medium — npm supply-chain attacks are frequent, but targeted attacks against a private repo are unlikely.
**Impact:** Critical (via T-001 escalation).

**Current controls:**
- `pnpm` uses a content-addressable store — packages are verified by hash
- Playwright cache is shared but the binary is downloaded from Microsoft's CDN
- Docker Hub auth uses a token (not password) with read-only scope
- No `npm install` runs as root

**Residual risk:** A compromised package that runs a postinstall script has full access to the container environment, including the Docker socket and GITHUB_PAT.

**Recommendation:** Consider adding `--ignore-scripts` to pnpm install in CI and running `pnpm audit` as a CI step (already in the bill-tracker pipeline).

---

## T-007: Log exposure — sensitive data in runner output

**Asset:** Credentials, API responses, user data
**Threat:** Runner logs (`/tmp/runner-output.log`, Docker container logs) may contain sensitive data from CI job output — API responses, database queries, test fixtures with PII.
**Likelihood:** Medium — depends on what the CI pipeline prints.
**Impact:** Medium — logs are local-only (no log aggregation service), but persist until container restart.

**Current controls:**
- Log rotation configured in Docker (`max-size: 50m`, `max-file: 5`)
- Runner logs are inside the container, not mounted to a host volume
- No external log shipping

**Residual risk:** `docker logs ci-runner-1` exposes all runner output to anyone with Docker access on the host (which, per T-001, is effectively anyone with container access).

---

## Attack surface summary

| ID | Threat | Likelihood | Impact | Status |
|----|--------|-----------|--------|--------|
| T-001 | Docker socket → host root | Low | Critical | ACCEPTED (trusted code only) |
| T-002 | SYS_TIME → kernel attack surface | Very low | High | ACCEPTED (no alternative) |
| T-003 | GITHUB_PAT leak → repo compromise | Medium | High | ACCEPTED (controls in place) |
| T-004 | MongoDB unauthenticated | Low | Low | ACCEPTED (ephemeral data) |
| T-005 | Autoheal socket access | Very low | Medium | ACCEPTED (pinned image) |
| T-006 | Supply-chain → container → host | Low-medium | Critical | ACCEPTED (pnpm hashing) |
| T-007 | Log exposure | Medium | Medium | ACCEPTED (local-only) |

## Escalation checklist

Review this threat model and re-evaluate accepted risks before any of the following:

- [ ] Accepting PRs from external contributors or forks
- [ ] Adding Dependabot with custom scripts
- [ ] Moving runners to a cloud or shared environment
- [ ] Storing persistent or sensitive data in MongoDB
- [ ] Exposing any container port to a network beyond localhost
- [ ] Adding a second repository to the runner registration
