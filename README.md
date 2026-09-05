# cicd

Shared deployment pipeline for my projects, all of which run as containers on
the same Armbian box at home, behind NAT, reachable over Tailscale.

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

The server and the secret store are one-time setup and already done — the two
sections near the bottom cover them for the day the box gets rebuilt. Per
project it is a file, a command, and a push.

### What the project needs first

| | |
|---|---|
| `Dockerfile` | At the repository root, or point the `dockerfile` input at it |
| a compose file | Any name `docker compose` accepts. Runs the published image: `image: ghcr.io/uqiu/<repo>:latest` |
| a health endpoint | Anything cheap that answers 200 once the app is up. `health-url` polls it. |
| a `HEALTHCHECK` | In the Dockerfile, hitting that same endpoint. Not required by the pipeline; add it anyway. |
| `.github/workflows/ci.yml` | The project's own tests, with `on: workflow_call` so `release.yml` can call them |

Bind the port to `127.0.0.1` in compose and pick one nothing else on the box
uses, so only the reverse proxy and the tailnet can reach it.

### The healthcheck

The deploy already polls `health-url`, so this looks redundant. It isn't — the
two answer different questions. The workflow asks *did this deploy work*, once,
and then the run ends. The image's `HEALTHCHECK` asks *is it still working*,
every thirty seconds, for as long as the container lives, and is what makes
`docker ps` say `healthy` rather than only `Up`.

Point it at the same endpoint `health-url` uses. Slim base images ship neither
`curl` nor `wget`, and installing one just for this is not worth the layer —
use the runtime that's already in there:

```dockerfile
# python:slim
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD ["python", "-c", "import urllib.request as u; u.urlopen('http://127.0.0.1:8081/api/health', timeout=4)"]
```

```dockerfile
# a Go or Rust binary on scratch/distroless — give the binary a health subcommand
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD ["/app", "healthcheck"]
```

Set `--start-period` to roughly how long a cold start takes; failures during it
don't count against `--retries`.

**It does not restart anything.** Docker's `restart:` policy reacts to a
container *exiting*, not to one going unhealthy, so a wedged-but-running
container stays up and unhealthy until something acts on it. What the
healthcheck buys is that `docker ps` tells you so, and that anything watching
the box can act on it.

### 1. The workflow file

`.github/workflows/release.yml` in the project, copied as-is:

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
    uses: ./.github/workflows/ci.yml           # the project's own tests

  ship:
    needs: test
    uses: uqiu/cicd/.github/workflows/ship.yml@main
    with:
      dir: /root/app/myproject                 # absolute, not ~/myproject
      health-url: http://127.0.0.1:8080/healthz
      runner: ubuntu-24.04-arm                 # public repositories only
      tag: ${{ inputs.tag }}
    secrets: inherit
```

That is the whole file. No `permissions:`, no secret plumbing, no build
configuration — step 2 is what makes that possible. Adjust `dir`,
`health-url`, `runner`, and see the inputs table for the rest.

**`dir` has to be an absolute path.** It is substituted into a double-quoted
`cd` on the server, where a leading `~` is not expanded, so `~/myproject` looks
for a directory literally named `~`.

### 2. One command

On the server, where the store lives and `gh` is already signed in as the
owner:

```bash
scripts/seed-deploy-secrets.sh uqiu/myproject
```

It does the two things the workflow file cannot do for itself:

- sets the six secrets — see "The six secrets"
- raises the repository's default `GITHUB_TOKEN` to read-write

The second is the non-obvious one. A called workflow's permissions are capped by
the calling job's and can only narrow, never grant, so `ship.yml` cannot be
handed the `packages: write` it needs to push the image unless the caller
already has it. As a repository setting that is done once and forgotten; as a
`permissions:` block it would be three lines in every project, and forgetting
them fails in the least readable way GitHub has — see the last section.
`scripts/allow-package-push.sh uqiu/myproject` is that half on its own.

It raises a *ceiling*, not a grant: the workflows here still pin their own
tokens down (`publish` to `contents: read` plus `packages: write`, `deploy` to
nothing at all), so a deploy holds no more than it did before.

**One consequence to handle:** every *other* workflow in the project now gets a
read-write token unless it says otherwise, so give each an explicit
`permissions:` block. Tests want `contents: read`.

### 3. Push to main

The first run builds the image, pushes it, clones the repository into `dir` on
the server by itself, and starts it. Nothing to do on the server — with one
exception, below.

Watch it once, since a first deploy is where a wrong port or a missing health
endpoint shows up:

```bash
gh run watch -R uqiu/myproject --exit-status
```

### Public or private

The one property of the project that changes any of the above:

| | public project | private project |
|---|---|---|
| `runner:` | `ubuntu-24.04-arm` — free, and builds aarch64 natively | omit it; builds on x86 under QEMU, several times slower |
| `diagnostics:` | leave it off — Actions logs are world-readable and `tailscale status` lists every device on the tailnet | safe to set `true` |
| first deploy | `auto-clone` handles it | anonymous HTTPS cannot clone it, so `git clone` into `dir` once by hand |
| the image | public; the server pulls anonymously | private; the server needs `docker login ghcr.io` (see server setup) |
| Actions minutes | free | billed against the monthly quota |

## The two workflows

| Workflow | Does |
|---|---|
| `ship.yml` | Build, push to GHCR, then deploy. What a project normally calls. |
| `deploy-to-server.yml` | Deploy only. For a redeploy, or an image built elsewhere. |

`ship.yml` inputs — `dir` and `health-url` are required, the rest have
defaults:

| Input | Default | Notes |
|---|---|---|
| `dir` | — | Directory on the server holding the compose file. Absolute. |
| `health-url` | — | Polled from inside the server after the restart |
| `compose-dir` | `.` | When compose.yaml isn't at the top of `dir` |
| `auto-clone` | `true` | Clone on the server when `dir` is missing (public repos) |
| `health-timeout` | `60` | Seconds before the deploy fails |
| `context` | `.` | Docker build context |
| `dockerfile` | `Dockerfile` | Path from the repository root |
| `platforms` | `linux/arm64` | The server is aarch64 |
| `runner` | `ubuntu-latest` | See "Public or private" |
| `build-args` | — | Extra args, one per line. `VERSION` is always passed |
| `tag` | — | Extra image tag besides `latest` |
| `diagnostics` | `false` | Print `tailscale status` on the deploy |

Every build is tagged with its commit sha as well as `latest`, so a rollback
has something to pin: `image: ghcr.io/uqiu/<repo>:<sha>` in compose. A manual
run of `release.yml` is also the way to redeploy without a code change.

Calls are pinned at `@main` rather than a tag, so a fix here reaches every
project on its next run with nothing to re-commit. The trade is that a mistake
here reaches every project too — this repository has no tests, so read twice.

## The six secrets

The same values for every project:

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
server is precisely what these secrets unlock. Set the store up once:

```bash
mkdir -p ~/.deploy-secrets && chmod 700 ~/.deploy-secrets
cat > ~/.deploy-secrets/env <<'EOF'
DEPLOY_HOST=my-server
DEPLOY_USER=deploy
TS_OAUTH_CLIENT_ID=k123...
TS_OAUTH_SECRET=tskey-client-...
EOF
chmod 600 ~/.deploy-secrets/env
cp ~/.ssh/deploy_ed25519 ~/.deploy-secrets/ssh_key   # optional; see below
chmod 600 ~/.deploy-secrets/ssh_key
```

Run on the server, the script finds that directory by itself. From a laptop,
`--from` reads the store over SSH and is remembered:

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

Already done on the current box; here for the next one.

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

## Why this repository is public

Not by preference — by requirement. A reusable workflow in a **private**
repository can only be called from other **private** repositories. The
"Accessible from repositories owned by the user" setting doesn't change that;
it grants access among private repositories only. A public caller gets
*"workflow was not found"* and fails before running a single step, which reads
like a typo in the `uses:` line rather than a permission problem.

Since at least one project here is public, this repository has to be public for
that project to use it. Private callers can call a public reusable workflow
with no setting at all, so public serves everything.

Nothing here is secret — only the shape of the pipeline. The values live on the
server in `~/.deploy-secrets` and in each repository's encrypted secret store,
neither of which is in git. Note that a project's own Actions logs are where
runtime detail would leak, and those follow the project's visibility, not this
repository's.

`scripts/allow-callers.sh` remains for the day this goes private again (it
flips the access policy, and says there's nothing to do while this is public).

## When a deploy fails

- **"This run likely failed because of a workflow file issue", three seconds,
  no jobs, no annotation** — `scripts/allow-package-push.sh` hasn't been run on
  the project. A called workflow can't hold a permission its caller lacks, so
  `publish`'s request for `packages: write` is refused before the run starts.
  The API exposes nothing at all for a startup failure — no logs, no
  annotation, no reason — so bisecting is the only way to find any other cause:
  strip the calling job down to `uses:` and add the keys back one at a time.
- **Workflow not found** — a typo in the `uses:` line, or the visibility rule
  above: a public repository cannot call a private repository's reusable
  workflow. Either way it fails before any step runs, so there are no logs.
- **`Unable to resolve action ... runner`** — `ubuntu-24.04-arm` on a private
  repository. Those runners are free for public repositories only; drop the
  `runner` input and it builds on x86 under QEMU.
- **`tailscaled is NeedsLogin, not Running`** — the OAuth client is invalid or
  `tag:ci` isn't in the tailnet policy file.
- **SSH times out but the tailnet check passed** — the ACL doesn't allow
  `tag:ci → server:22`, or `sshd` isn't listening on the tailscale interface.
- **`cd: ~/myproject: No such file or directory`**, or a directory named `~`
  appears on the server — `dir` was given as `~/…`. Use an absolute path.
- **Health check times out** — the container logs are printed in the same step.
  The service is likely up but slow, or the image is broken.
