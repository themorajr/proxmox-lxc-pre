# proxmox-script

Personal collection of automation scripts for Proxmox VE, inspired by
[community-scripts.org](https://community-scripts.org/). The goal is to
automate the repetitive setup steps you do every time you spin up a new LXC
container.

## Scripts

### `setup-lxc.sh`

All-in-one post-install script that runs **inside** a freshly created LXC
container (Debian/Ubuntu based). It will:

1. Install and enable **OpenSSH server**
   - Enables root login over SSH (`PermitRootLogin yes`)
   - Enables password authentication
   - Optionally sets the root password
2. Install **Docker Engine + Docker Compose plugin** via Docker's official
   apt repository
3. Enable the Docker service to start on boot
4. Optionally add a non-root user to the `docker` group
5. Print a summary (container IP, Docker version, SSH command) when done

## Requirements

- A Proxmox VE host with an LXC container already created (Debian or Ubuntu
  template)
- The container must be run with **nesting enabled** for Docker to work:

  ```bash
  pct set <CTID> -features nesting=1,keyctl=1
  pct reboot <CTID>
  ```

  (`setup-lxc.sh` reminds you of this at the end if you forget.)

## Usage

### Option 1 — push the script into the container and run it

From the Proxmox host, after the LXC is created and running:

```bash
# 1. Enable nesting on the container (only needed once)
pct set 200 -features nesting=1,keyctl=1
pct reboot 200

# 2. Copy the script into the container
pct push 200 setup-lxc.sh /root/setup-lxc.sh

# 3. Run it inside the container
pct exec 200 -- bash /root/setup-lxc.sh
```

### Option 2 — run with environment variables

```bash
pct exec 200 -- bash -c "ROOT_PASSWORD='YourStrongPass' EXTRA_USER='youruser' bash /root/setup-lxc.sh"
```

### Option 3 — curl one-liner

Repo: https://github.com/themorajr/proxmox-lxc-pre/blob/main/setup-lxc.sh

```bash
pct exec 200 -- bash -c "$(curl -fsSL https://raw.githubusercontent.com/themorajr/proxmox-lxc-pre/main/setup-lxc.sh)"
```

> Note: use the `raw.githubusercontent.com` link (not the `github.com/.../blob/...`
> page) with `curl`, otherwise you'll download the HTML page instead of the script.

### Option 4 — run directly from inside the container console

Open the container console (`pct enter <CTID>` or the Proxmox web UI
console), then:

```bash
chmod +x setup-lxc.sh
./setup-lxc.sh
```

## Environment variables

| Variable         | Default | Description                                                        |
| ---------------- | ------- | -------------------------------------------------------------------- |
| `ROOT_PASSWORD`  | (unset) | If set, sets/resets the root password so you can log in over SSH.    |
| `ALLOW_ROOT_SSH` | `yes`   | Set to `no` to skip enabling `PermitRootLogin yes`.                  |
| `EXTRA_USER`     | (unset) | Existing username to add to the `docker` group.                     |

## Security notes

- Enabling root SSH login with password auth is convenient for
  home-lab/local networks but **not recommended** if the container is
  reachable from the internet. Prefer SSH keys and set
  `ALLOW_ROOT_SSH=no` for anything internet-facing.
- Always use a strong `ROOT_PASSWORD` if you set one.

## Troubleshooting

- **`docker: Cannot connect to the Docker daemon`** — nesting is probably
  not enabled on the container. Run `pct set <CTID> -features
  nesting=1,keyctl=1` on the host, then `pct reboot <CTID>`.
- **Can't SSH in** — make sure the container has an IP address
  (`pct exec <CTID> -- hostname -I`) and that `ROOT_PASSWORD` was set or an
  SSH key was already present.
