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
│   ├── Dockerfile.debian    # Debian 12 (apt)
│   └── awx-receptor/        # AWX execution node: awx-ee + podman (runs the jobs)
├── docker-compose.yml       # fleet nodes + optional AWX control plane
├── awx-config/              # settings/nginx/receptor/migration wiring AWX needs to run standalone
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
  (gitignored; override the directory with `-e patch_report_dir=...`), so
  you can see exactly **which node patched successfully, which didn't, and
  why**, and
- publishes that report with `set_stats` (`patch_report`,
  `patch_report_timestamp`), so under AWX it shows up on the job's
  **Artifacts** tab and is passed on to later workflow steps, and
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

This starts `awx-postgres`, `awx-redis`, two one-shot containers
(`awx-projects-perms` fixes volume ownership; `awx-migrations` runs DB
migrations, creates the admin user and registers the execution
environments, then exits), `awx-web` + `awx-task`, and an `awx-receptor`
sidecar that also executes the jobs. All of them share the `lab-net` bridge
network with the fleet nodes, so AWX reaches them directly by hostname.

Add `--build` (as `setup.sh --with-awx` does) whenever
`docker/awx-receptor/` changes; compose only builds that image when it's
missing.

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

### How jobs execute

Outside Kubernetes, AWX always runs a job as `podman run <execution
environment image> ansible-playbook ...` on the execution node. Here that
node is the `awx-receptor` sidecar:

```
awx-task ──(receptor.sock)──▶ awx-receptor ──podman run──▶ awx-ee:23.8.1 job container
   │                               │                              │
   └──── awx_job_data volume ──────┘ (job dir, same path)         └─ ssh ─▶ rhel/ubuntu/debian-node
```

What makes that work, and why (each one was a real failure):

| Piece | Where | Why |
|---|---|---|
| `awx-ee` + podman image, `privileged: true` | `docker/awx-receptor/`, compose | the stock `awx-ee` image has no podman |
| `cgroups = "disabled"` | `docker/awx-receptor/containers.conf` | podman can't create its own cgroups under cgroup v2 inside Docker (`conmon ... container create failed`) |
| `DEFAULT_CONTAINER_RUN_OPTIONS = ['--network', 'host']` | `settings.py` | AWX defaults to `slirp4netns`, which cuts job containers off from `lab-net` |
| `awx_job_data` volume at `AWX_ISOLATION_BASE_PATH` in both containers | compose, `settings.py` | for a local node AWX sends only the run parameters, not the job directory (`the playbook: patch.yml could not be found`) |
| `awx-task` runs as `user: "0"` | compose | ansible-runner writes root-owned `0600` artifacts into that shared dir, which `awx-task` must overwrite when the job ends |
| `awx-projects-perms` one-shot | compose | Docker creates the projects volume root-owned; AWX writes `<project>.lock` files there |
| `CONTROL_PLANE_EXECUTION_ENVIRONMENT` / `GLOBAL_JOB_EXECUTION_ENVIRONMENTS` | `settings.py`, `migrate.sh` | registers `AWX EE (23.8.1)`; without an EE, jobs can't start |
| `./ansible` bind-mounted read-only as the project | compose | edits to `patch.yml` reach AWX immediately, no copy step |

Don't set `IS_K8S = True` to avoid podman: on AWX 23.x it only skips podman
for Kubernetes container groups, and it makes the dispatcher rewrite
`receptor.conf` with the operator's TLS/Kubernetes template, which crashes
`awx-task`.

The first job pulls the EE image (~1.5 GB) inside `awx-receptor` into the
`awx_receptor_containers` volume, so it shows "running" for a few minutes
before any output. Later runs start in seconds.

### Auto-provision AWX

```bash
./scripts/awx-configure.sh
```

Talks to the AWX REST API to create everything from the original concept:

1. **Credential** `Lab SSH Key` (Machine, user `root`, your `id_rsa_ansible` key)
2. **Inventory** `Local Multi-Distro Fleet` with the three fleet hosts in a
   `linux_cluster` group (the group `patch.yml` targets)
3. **Project** `Linux Patch Management` (manual project reading the
   bind-mounted `ansible/` folder, no git remote needed)
4. **Execution environment** `AWX EE (23.8.1)` as the organization default
5. **Job Template** `Weekly Enterprise Linux Patching` (that EE, prompt on
   launch for *limit*)
6. **Schedule** — every Sunday at 02:00 UTC

Requires `curl` and `jq` locally (WSL2/Git Bash on Windows). Idempotent —
safe to re-run. If you changed the admin password, pass it:
`AWX_ADMIN_PASSWORD=... ./scripts/awx-configure.sh`.

### Manual run vs. scheduled run

A Schedule is only an *additional* trigger — it never restricts a Job
Template to schedule-only. Once `awx-configure.sh` has run, you can launch
"Weekly Enterprise Linux Patching" any time, on top of its Sunday schedule:

- **From the UI:** Templates → *Weekly Enterprise Linux Patching* → **Launch**
- **From the API/CLI:**
  ```bash
  ./scripts/awx-run-now.sh                    # macOS/Linux/WSL2
  LIMIT=debian-node ./scripts/awx-run-now.sh  # a single node
  ./scripts/awx-run-now.ps1                    # Windows ($env:LIMIT works too)
  ```

Either way the job shows up under **Views → Jobs**, with the per-host
summary in its output and the JSON report on its **Artifacts** tab. (The
`reports/` file the playbook writes lands in the job's temporary directory
under AWX and is removed with it.)

> **Topology View** only shows AWX's own nodes (here one hybrid node,
> `awx`). The fleet nodes are managed hosts: see **Resources → Inventories →
> Local Multi-Distro Fleet → Hosts**.

To do either step by hand instead of via script, the same resources
are under **Resources** in the AWX left nav; `scripts/awx-configure.sh` and
`scripts/awx-run-now.sh` document the exact API calls if you want to see
what the UI is doing under the hood.

### Troubleshooting AWX jobs

```bash
docker compose --profile awx ps -a     # awx-migrations / awx-projects-perms: Exited (0)
docker compose logs awx-migrations --tail 30
docker logs awx-task --tail 50         # dispatcher / receptor errors
curl -s http://localhost:8050/api/v2/ping/   # instance capacity (0 for ~1 min after a restart is normal)
```

A job that ends in **Error** (rather than **Failed**) failed inside AWX, not
in the playbook; the traceback is in the job's details, or via
`docker exec awx-task awx-manage shell -c "from awx.main.models import Job; print(Job.objects.get(id=<id>).result_traceback)"`.

The OrbStack URL (`https://awx-web.linux-patching-concept.orb.local`)
returns a 502 for about 30 s after `awx-web` is recreated; reload.

## 3. Tear down

```bash
./scripts/teardown.sh            # macOS/Linux/WSL2 — stop fleet + AWX, keep data volumes
./scripts/teardown.sh --volumes  # also wipe AWX's data volumes (DB, job dirs, EE image cache)
./scripts/teardown.ps1            # Windows equivalents
./scripts/teardown.ps1 -Volumes
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
| `AWX_EE_IMAGE` | `quay.io/ansible/awx-ee:23.8.1` (base of the `awx-receptor` image; the EE that jobs run in is set in `awx-config/settings.py`) |

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
