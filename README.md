# linux-patching-concept

A hands-on lab that simulates a multi-distribution enterprise Linux fleet
(RHEL/Rocky, Ubuntu, Debian) as Docker containers, and patches it with a
single OS-aware Ansible playbook — driven either from the CLI or from a
browser-reachable AWX (upstream Ansible Tower) control plane, also running
in containers.

```
linux-patching-concept/
├── docker/
│   ├── Dockerfile.rocky     # RHEL 9 stand-in (dnf)
│   ├── Dockerfile.ubuntu    # Ubuntu 22.04 (apt)
│   └── Dockerfile.debian    # Debian 12 (apt)
├── docker-compose.yml       # fleet nodes + optional AWX control plane
├── awx-config/              # settings/nginx/migration wiring AWX needs to run standalone
├── ansible/
│   ├── ansible.cfg
│   ├── inventory.ini        # for running ansible from your host (mapped SSH ports)
│   ├── inventory.awx.ini    # for running from inside AWX (internal docker network)
│   └── patch.yml            # the OS-aware patch playbook, with a pass/fail report
└── scripts/
    ├── setup.sh / setup.ps1             # generate SSH key, build + start the fleet (+ AWX)
    ├── awx-configure.sh                 # auto-provision AWX via its REST API
    ├── awx-run-now.sh / awx-run-now.ps1 # launch the job template on demand
    └── teardown.sh / teardown.ps1       # stop everything
```

## Platform support

| Platform | Docker/Compose | Running `ansible-playbook` itself |
|---|---|---|
| **macOS** | Docker Desktop or [OrbStack](https://orbstack.dev/) | Native (`brew install ansible`) |
| **Windows** | Docker Desktop (WSL2 backend) | From **WSL2** (Ubuntu) or Git Bash — Ansible has never supported a native Windows control node, this isn't specific to this lab |

The `docker compose` / container side of this lab works identically on both
OSes. `.sh` scripts are for macOS/Linux/WSL2; `.ps1` equivalents are provided
for native Windows PowerShell where the task is pure Docker (build/start/stop,
calling the AWX API) — anything that shells out to `ansible-playbook` needs
WSL2 on Windows, since that's an Ansible constraint, not a lab one.

## 1. Quick start — fleet only

```bash
./scripts/setup.sh              # macOS/Linux/WSL2
./scripts/setup.ps1              # Windows PowerShell
```

This generates `~/.ssh/id_rsa_ansible` if you don't already have one, stages
the public key into the build context as `id_rsa_ansible.pub` (gitignored —
never committed), and builds/starts the three fleet containers with their
SSH ports mapped to the host:

| Node          | Distro         | Host SSH port |
|---------------|----------------|---------------|
| `rhel-node`   | Rocky Linux 9  | 2221          |
| `ubuntu-node` | Ubuntu 22.04   | 2222          |
| `debian-node` | Debian 12      | 2223          |

Verify connectivity and run the playbook (from macOS/Linux/WSL2):

```bash
ansible linux_cluster -i ansible/inventory.ini -m ping
ansible-playbook -i ansible/inventory.ini ansible/patch.yml
```

### What the playbook reports

`patch.yml` gathers facts, branches on `ansible_os_family` (`dnf` security
updates on RedHat-family hosts, `apt` safe-upgrade on Debian-family hosts),
records success/failure per host with `block`/`rescue`, and finishes with a
consolidated report play that:

- prints a one-line-per-host summary table (distro, status, changed/no-op,
  reboot needed or not, message) to the console, and
- writes the same data as JSON to `reports/patch_report_<timestamp>.json`
  (gitignored), so you can see exactly **which node patched successfully,
  which didn't, and why**, and
- makes the whole playbook run **fail** (non-zero exit) if any host failed
  to patch — so this is safe to wire into CI/AWX and get a clear red/green
  signal instead of a silent partial success.

Example console output:

```
TASK [Print fleet patch summary] **********************************
ok: [localhost] => (item=rhel-node) => msg: rhel-node       Rocky Linux 9.3         success  changed   ok        Patched successfully (packages updated)
ok: [localhost] => (item=ubuntu-node) => msg: ubuntu-node     Ubuntu 22.04            success  no-op     ok        Patched successfully (already up to date)
ok: [localhost] => (item=debian-node) => msg: debian-node     Debian 12               failed   no-op     ok        <the actual dnf/apt error message>
```

> **Why the reboot logic doesn't actually reboot:** rebooting a container
> kills its PID 1 (`sshd`). Without a `restart` policy the container won't
> come back and you'll lose SSH access to that node. `reboot_required` is
> still computed and reported per host — just gate a real
> `ansible.builtin.reboot` task on that fact when you point this playbook
> at real VMs/bare metal instead of lab containers.

## 2. AWX control plane — reachable in your browser

Bring up AWX alongside the fleet:

```bash
./scripts/setup.sh --with-awx        # macOS/Linux/WSL2
./scripts/setup.ps1 -WithAwx          # Windows
# or, if the fleet is already running:
docker compose --profile awx up -d
```

This starts `awx-postgres`, `awx-redis`, a one-shot `awx-migrations`
container (runs DB migrations + creates the admin user, then exits),
`awx-web` + `awx-task`, and an `awx-receptor` sidecar (the Receptor mesh
daemon `awx-task` requires at startup) — all sharing the `lab-net` bridge network with the
fleet nodes so AWX can reach them directly by hostname.

Once `docker compose logs -f awx-web` shows `WSGI app 0 ... ready`, open:

**http://localhost:8050** — default login `admin` / `adminpassword`
(override via `AWX_ADMIN_USER` / `AWX_ADMIN_PASSWORD` env vars before
starting, and set `AWX_SECRET_KEY` for anything longer-lived than a lab).
This was verified end-to-end (HTTP 200 on the UI, working admin login,
`/api/v2/ping/` responding) against the exact compose file in this repo.

> **Why this needed extra wiring:** the published `ghcr.io/ansible/awx`
> image ships with no nginx/redis/Django config baked in — that's normally
> injected by the Kubernetes operator at deploy time. `awx-config/` supplies
> the missing pieces (`nginx.conf` proxying to uwsgi/daphne, a `settings.py`
> pointed at our Postgres/Redis, `receptor.conf` for the Receptor sidecar,
> and `migrate.sh` for first-boot setup) so
> the same image runs standalone under plain `docker compose`.
>
> **Known limitation:** this reconstruction gets you a fully working AWX
> UI/API — create credentials, inventories, projects, job templates,
> schedules, launch jobs — but actual playbook **execution** needs a
> container-capable execution environment, which this slim production image
> doesn't include (that's normally a separate Kubernetes-scheduled pod). If
> you need jobs to genuinely execute from inside AWX rather than from the
> CLI, use the officially supported `make docker-compose` devel environment
> from the [AWX source repo](https://github.com/ansible/awx) (bundles a
> real execution environment) or `kind`/`minikube` + `awx-operator`.
>
> In practice: a launched job (UI **Launch** button, the Sunday schedule, or
> `awx-run-now.sh`) is created and then fails with
> `Job could not start because no Execution Environment could be found.`
> That is this limitation, not a misconfiguration. Outside Kubernetes, AWX
> always runs jobs in a `podman` container, which this stack doesn't provide.
> To actually patch the fleet, run the playbook from the CLI (section 1).

### Auto-provision AWX

```bash
./scripts/awx-configure.sh
```

Talks to the AWX REST API to create everything from the original concept:

1. **Credential** `Lab SSH Key` (Machine, user `root`, your `id_rsa_ansible` key)
2. **Inventory** `Local Multi-Distro Fleet` with the three fleet hosts
3. **Project** `Linux Patch Management` (manual project — `patch.yml` is
   copied straight into AWX's project volume, no git remote needed)
4. **Job Template** `Weekly Enterprise Linux Patching`
5. **Schedule** — every Sunday at 02:00 UTC

Requires `curl` and `jq` locally (WSL2/Git Bash on Windows). Idempotent —
safe to re-run.

### Manual run vs. scheduled run

A Schedule is only an *additional* trigger — it never restricts a Job
Template to schedule-only. Once `awx-configure.sh` has run, you can launch
"Weekly Enterprise Linux Patching" any time, on top of its Sunday schedule:

- **From the UI:** Templates → *Weekly Enterprise Linux Patching* → **Launch**
- **From the API/CLI:**
  ```bash
  ./scripts/awx-run-now.sh        # macOS/Linux/WSL2
  ./scripts/awx-run-now.ps1        # Windows
  ```

Either way the job is queued and shows up under **Jobs**, but in this
standalone stack it fails at start with "no Execution Environment could be
found". See the known limitation above.

To do either step by hand instead of via script, the same five resources
are under **Resources** in the AWX left nav; `scripts/awx-configure.sh` and
`scripts/awx-run-now.sh` document the exact API calls if you want to see
what the UI is doing under the hood.

## 3. Tear down

```bash
./scripts/teardown.sh            # macOS/Linux/WSL2 — stop fleet + AWX, keep data volumes
./scripts/teardown.sh --volumes  # also wipe AWX's postgres/projects data
./scripts/teardown.ps1            # Windows equivalents
./scripts/teardown.ps1 -Volumes
```

## 4. Docker Compose command reference

The scripts above are thin wrappers around these commands; use them directly
when you want finer control. Run them from the repo root. They work the same
with Docker Desktop and OrbStack, and in PowerShell.

> The AWX services sit behind the `awx` compose profile. Any command that
> should see them (`ps`, `logs`, `down`, …) needs `--profile awx`; without
> it, compose only acts on the three fleet nodes.

> Building the fleet images needs `id_rsa_ansible.pub` in the repo root.
> `setup.sh` / `setup.ps1` stage it for you. If you build by hand, copy it
> first: `cp ~/.ssh/id_rsa_ansible.pub .`

**Start / stop**

```bash
docker compose up -d --build rhel-node ubuntu-node debian-node  # fleet only
docker compose --profile awx up -d                               # fleet + AWX
docker compose --profile awx stop                                # stop, keep containers
docker compose --profile awx start                               # start them again
docker compose --profile awx down                                # remove containers, keep AWX data
docker compose --profile awx down -v                             # also wipe AWX postgres/projects volumes
```

**Status and logs**

```bash
docker compose --profile awx ps -a              # state of every container (incl. exited awx-migrations)
docker compose logs -f awx-web                  # wait for "WSGI app 0 ... ready" before opening the UI
docker compose logs -f awx-task awx-receptor    # task dispatcher + Receptor sidecar
docker compose logs awx-migrations              # first-boot migrations / admin user creation
```

**Rebuild or restart one service**

```bash
docker compose up -d --build --force-recreate ubuntu-node   # rebuild a fleet node from its Dockerfile
docker compose --profile awx restart awx-task               # restart one AWX service
docker compose --profile awx up -d --force-recreate awx-migrations awx-task  # re-run first-boot setup
```

**Get a shell on a node**

```bash
docker compose exec rhel-node bash                           # via Docker
ssh -i ~/.ssh/id_rsa_ansible -p 2221 root@localhost          # via SSH, as Ansible does (2222 ubuntu, 2223 debian)
```

**Images and config**

```bash
docker compose --profile awx pull     # pull AWX/postgres/redis images ahead of time
docker compose --profile awx config   # print the fully resolved compose file (env vars applied)
```

Environment variables read by the compose file (all optional, lab defaults
shown):

| Variable | Default |
|---|---|
| `AWX_ADMIN_USER` / `AWX_ADMIN_PASSWORD` | `admin` / `adminpassword` |
| `AWX_SECRET_KEY` | `please-change-me-lab-only` |
| `AWX_POSTGRES_PASSWORD` | `awxpassword` |
| `AWX_IMAGE` | `ghcr.io/ansible/awx:23.8.1` |
| `AWX_EE_IMAGE` | `quay.io/ansible/awx-ee:23.8.1` |

Example: `AWX_ADMIN_PASSWORD=s3cret docker compose --profile awx up -d`
(PowerShell: `$env:AWX_ADMIN_PASSWORD="s3cret"` first, then the command).
Set these before the first start; the admin password and DB password are
baked into the AWX volumes on first boot, so changing them later requires
`down -v`.

## Security notes

- `id_rsa_ansible.pub` is copied into the Docker build context at setup
  time and is gitignored — don't remove that ignore rule and commit it or
  any private key material.
- The lab containers accept root SSH login with your real local key. Keep
  this stack off of untrusted networks, and don't reuse the generated key
  for anything beyond this lab if you didn't already have one.
- Default AWX admin credentials and `AWX_SECRET_KEY` in `docker-compose.yml`
  are lab placeholders — override them via environment variables for
  anything you leave running.
