# cicd

Shared deployment pipeline for my projects, all of which run as containers on
the same Armbian box at home, behind NAT, reachable over Tailscale.

Adding deployment to a project is a workflow file, one command, and nothing on
the server.

```
push / merge to main
   ↓
the project's own tests
   ↓
ship.yml → build the image → push to ghcr.io/<owner>/<repo>:latest
   ↓
        → runner joins the tailnet → SSH into the server
   ↓
          git pull + docker compose pull + up -d
   ↓
          poll the health URL from the server; on failure, print logs and fail
```

The image is built on GitHub's machines. The server only pulls a finished
image, so its CPU never compiles anything.

## Adding a project

**1. The workflow.** `.github/workflows/release.yml` in the project:

```yaml
name: Publish and deploy

on:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      tag:
        description: Additional image tag (e.g. v0.1.0).
        required: false

concurrency:
  # Back-to-back merges should deploy the last one, not race each other. Never
  # cancel a run in progress: a half-finished deploy is worse than a slow one.
  group: deploy-production
  cancel-in-progress: false

jobs:
  test:
    uses: ./.github/workflows/ci.yml      # the project's own tests

  ship:
    needs: test
    uses: uqiu/cicd/.github/workflows/ship.yml@main
    with:
      dir: ~/myproject                    # where it lives on the server
      health-url: http://127.0.0.1:8930/healthz
      tag: ${{ inputs.tag }}
    secrets: inherit
```

**2. The secrets.**

```bash
scripts/seed-deploy-secrets.sh uqiu/myproject
```

**3. The server: nothing.** The first deploy clones the repository into `dir`
itself. That works over anonymous HTTPS, so a private repository still needs
one manual `git clone` on the server — after that the deploy takes over.

Pick a port nothing else on the box uses and bind it to `127.0.0.1` in compose,
so only the reverse proxy and the tailnet can reach it.

## The two workflows

| Workflow | Does |
|---|---|
| `ship.yml` | Build, push to GHCR, then deploy. What a project normally calls. |
| `deploy-to-server.yml` | Deploy only. For a redeploy, or an image built elsewhere. |

`ship.yml` inputs — `dir` and `health-url` are required, the rest have
defaults:

| Input | Default | Notes |
|---|---|---|
| `dir` | — | Directory on the server holding the compose file |
| `health-url` | — | Polled from inside the server after the restart |
| `compose-dir` | `.` | When compose.yaml isn't at the top of `dir` |
| `auto-clone` | `true` | Clone on the server when `dir` is missing (public repos) |
| `health-timeout` | `60` | Seconds before the deploy fails |
| `context` | `.` | Docker build context |
| `dockerfile` | `Dockerfile` | Path from the repository root |
| `platforms` | `linux/arm64` | The server is aarch64 |
| `runner` | `ubuntu-latest` | See below |
| `build-args` | — | Extra args, one per line. `VERSION` is always passed |
| `tag` | — | Extra image tag besides `latest` |
| `diagnostics` | `false` | Print `tailscale status` on the deploy |

**Public repositories should set `runner: ubuntu-24.04-arm`.** GitHub's arm64
runners are free for public repositories and build aarch64 natively; the
default x86 runner emulates it under QEMU, which is several times slower.
Private repositories don't get them for free, hence the default.

**Leave `diagnostics` off in a public repository.** Actions logs there are
world-readable, and `tailscale status` lists every device on the tailnet.

Every build is tagged with its commit sha as well as `latest`, so a rollback
has something to pin: `image: ghcr.io/uqiu/<repo>:<sha>` in compose.

Calls are pinned at `@main` rather than a tag, so a fix here reaches every
project on its next run with nothing to re-commit. The trade is that a mistake
here reaches every project too — this repository has no tests, so read twice.

## The secrets

Six, the same values for every project:

| Secret | What it is |
|---|---|
| `TS_OAUTH_CLIENT_ID` | Tailscale OAuth client id, scoped to `tag:ci` |
| `TS_OAUTH_SECRET` | its secret |
| `DEPLOY_SSH_KEY` | private key of the deploy-only SSH keypair |
| `DEPLOY_KNOWN_HOSTS` | `ssh-keyscan <server>` output, pinning the fingerprint |
| `DEPLOY_HOST` | the server's tailnet hostname |
| `DEPLOY_USER` | the SSH user on the server |

The server directory is a workflow input, not a secret — it differs per project
and isn't sensitive.

**Actions secrets are write-only.** GitHub takes a value encrypted with the
repository's public key and offers no way to read one back; `gh secret list`
returns names and timestamps only. There is no copying them out of a repository
that already has them, so they have to live somewhere you control.

That somewhere is the server. You can read it over SSH, a new laptop needs no
setup, and the runner — which must never read it — can't, because reaching the
server is precisely what these secrets unlock. Set it up once:

```bash
mkdir -p ~/.deploy-secrets && chmod 700 ~/.deploy-secrets
cat > ~/.deploy-secrets/env <<'EOF'
DEPLOY_HOST=my-server
DEPLOY_USER=deploy
TS_OAUTH_CLIENT_ID=k123...
TS_OAUTH_SECRET=tskey-client-...
EOF
chmod 600 ~/.deploy-secrets/env
cp ~/.ssh/hub_deploy ~/.deploy-secrets/ssh_key   # optional; see below
chmod 600 ~/.deploy-secrets/ssh_key
```

Then, from any machine with SSH access to it:

```bash
scripts/seed-deploy-secrets.sh uqiu/myproject --from me@my-server
scripts/seed-deploy-secrets.sh uqiu/other        # --from is remembered
```

`DEPLOY_KNOWN_HOSTS` isn't stored — the script runs `ssh-keyscan` at the time,
so a rebuilt server re-pins instead of failing a deploy months later with a
fingerprint mismatch. Values are piped over stdin rather than passed as
arguments, which would be visible in `ps`.

Keeping the deploy key in the store is optional; name a local file with
`DEPLOY_SSH_KEY_FILE` in the env file instead if you'd rather it never leave
your laptop. On the server it adds little exposure — that key only opens the
machine an attacker would already be on — and it means a new laptop needs
nothing but SSH access.

If a value is lost: the Tailscale OAuth **client id** is visible in the admin
console, but the **secret** is shown once at creation — generate a new client
(scoped to `tag:ci`) and delete the old one. The SSH key is whatever
`ssh-copy-id` put in the server's `authorized_keys`.

## One-time server setup

1. **Docker**

   ```bash
   curl -fsSL https://get.docker.com | sh
   sudo usermod -aG docker $USER    # log back in for this to take effect
   ```

2. **GHCR login**, only needed for private images:

   ```bash
   echo '<classic PAT with read:packages>' | docker login ghcr.io -u uqiu --password-stdin
   ```

3. **A deploy-only SSH key.** Generate it locally, don't reuse a personal one:

   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/deploy_ed25519 -C 'github-actions deploy'
   ssh-copy-id -i ~/.ssh/deploy_ed25519.pub <user>@<server>
   ```

4. **Tailscale ACL.** `tag:ci` needs to reach port 22 on the server, and `sshd`
   has to listen on the tailscale interface.

5. **A Tailscale OAuth client** scoped to `tag:ci`, for the runner to join the
   tailnet.

## This repository is private

A reusable workflow in a private repository is invisible to other repositories
until it grants them access. Run this once, signed in as the owner:

```bash
scripts/allow-callers.sh
```

That's the API behind **Settings → Actions → General → Access → "Accessible
from repositories owned by the user uqiu"**, if you'd rather click it. Without
it, every caller fails with *"workflow was not found"* before running a single
step — which reads like a typo in the `uses:` line rather than a permission, so
it is worth doing before the first deploy.

Making this repository public would retire that setting and the confusion with
it — nothing in here is secret, only the shape of the pipeline. The secrets
themselves live on the server and in each repository's encrypted store either
way. `allow-callers.sh` notices and tells you there's nothing to do.

## When a deploy fails

- **`tailscaled is NeedsLogin, not Running`** — the OAuth client is invalid or
  `tag:ci` isn't in the tailnet policy file.
- **SSH times out but the tailnet check passed** — the ACL doesn't allow
  `tag:ci → server:22`, or `sshd` isn't listening on the tailscale interface.
- **Health check times out** — the container logs are printed in the same step.
  The service is likely up but slow, or the image is broken.
- **Workflow not found** — the access setting above, or a typo in the `uses:`
  line. A private callee with access not granted fails before any step runs.

## Users

| Project | Directory on the server | Health |
|---|---|---|
| [forge](https://github.com/uqiu/forge) | `~/forge` | `:8081/api/health` |
