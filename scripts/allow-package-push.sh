#!/usr/bin/env bash
# Raises a caller repository's default GITHUB_TOKEN to read-write, so its
# `ship:` job can hand `ship.yml` the `packages: write` that pushing to GHCR
# needs.
#
#   scripts/allow-package-push.sh uqiu/myproject
#
# Why this is a repository setting and not a line in the project's workflow:
# a called workflow's permissions are capped by the calling job's, and they can
# only narrow — never grant. So `publish`'s request for `packages: write` is
# refused unless the caller already has it. The caller could grant it inline
# with a `permissions:` block on its `ship:` job, but that is three lines every
# project has to remember, and forgetting them fails in the least readable way
# GitHub has: the run ends in about three seconds having created no jobs, with
# no annotation and nothing in the API that names the permission. Doing it once
# per repository keeps the project's workflow to the fifteen lines in the
# README.
#
# What this widens: only the *default* for workflows in that repository that
# declare no `permissions:` of their own. It is a ceiling, not a grant — the
# workflows here still pin themselves down (`publish` takes `contents: read`
# plus `packages: write`, `deploy` takes nothing at all), so the token a
# deployment actually runs with is unchanged. But any *other* workflow in the
# caller that omits `permissions:` will now get a read-write token, so give
# those an explicit block; a test workflow wants `contents: read`.
#
# This is the API behind Settings → Actions → General → Workflow permissions.
# Setting it needs ADMIN, which reading the repository does not imply.
set -euo pipefail

REPO=${1:-}

if [ -z "$REPO" ]; then
  echo "usage: $0 <owner/repo>" >&2
  exit 2
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "gh isn't signed in. \`gh auth login\`, or \`gh auth switch\` to the owner." >&2
  exit 1
fi

PERM=$(gh repo view "$REPO" --json viewerPermission --jq .viewerPermission 2>/dev/null || true)

if [ -z "$PERM" ]; then
  WHO=$(gh api user --jq .login 2>/dev/null || echo '?')
  echo "Signed in as '$WHO', which can't see $REPO." >&2
  echo "Switch accounts with \`gh auth switch\`." >&2
  exit 1
fi

if [ "$PERM" != "ADMIN" ]; then
  WHO=$(gh api user --jq .login 2>/dev/null || echo '?')
  echo "Signed in as '$WHO', which has $PERM on $REPO — this needs ADMIN." >&2
  echo "Switch accounts with \`gh auth switch\`." >&2
  exit 1
fi

ENDPOINT="repos/$REPO/actions/permissions/workflow"
BEFORE=$(gh api "$ENDPOINT" --jq .default_workflow_permissions 2>/dev/null || echo unknown)

if [ "$BEFORE" = "write" ]; then
  echo "✅ $REPO already gives workflows a read-write token by default."
  exit 0
fi

echo "$REPO default_workflow_permissions is '$BEFORE'; setting it to 'write'…"

# can_approve_pull_request_reviews is sent explicitly: the API resets omitted
# fields to their defaults, and letting Actions approve pull requests is not
# something this script should switch on as a side effect.
gh api -X PUT "$ENDPOINT" \
  -F default_workflow_permissions=write \
  -F can_approve_pull_request_reviews=false >/dev/null

AFTER=$(gh api "$ENDPOINT" --jq .default_workflow_permissions)
if [ "$AFTER" != "write" ]; then
  echo "❌ still '$AFTER' after the write — check the token's scopes (needs repo/admin)." >&2
  exit 1
fi

echo "✅ $REPO can now push packages from a called workflow."
echo
echo "Give any other workflow in $REPO an explicit \`permissions:\` block, so"
echo "this ceiling isn't what its token ends up with — tests want \`contents: read\`."
