#!/usr/bin/env bash
# Lets this account's other repositories call the reusable workflows here.
#
#   scripts/allow-callers.sh                 # defaults to uqiu/cicd
#   scripts/allow-callers.sh uqiu/cicd
#
# A reusable workflow in a *private* repository is invisible to other
# repositories until this is set. A caller that can't see it fails with
# "workflow was not found" before running a single step — which reads like a
# typo in the `uses:` line rather than a permission, so it's worth doing first.
#
# This is the API behind Settings → Actions → General → Access. Run it from a
# terminal signed in as the account that owns the repository; setting it needs
# ADMIN, which reading the repository does not imply.
set -euo pipefail

REPO=${1:-uqiu/cicd}

if ! gh auth status >/dev/null 2>&1; then
  echo "gh isn't signed in. \`gh auth login\`, or \`gh auth switch\` to the owner." >&2
  exit 1
fi

WHO=$(gh api user --jq .login 2>/dev/null || echo '?')

read -r VISIBILITY PERM <<<"$(
  gh repo view "$REPO" --json visibility,viewerPermission \
    --jq '[.visibility, .viewerPermission] | @tsv' 2>/dev/null || true
)"

if [ -z "${PERM:-}" ]; then
  echo "Signed in as '$WHO', which can't see $REPO." >&2
  echo "Switch accounts with \`gh auth switch\`." >&2
  exit 1
fi

# Checked before the permission: a public repository needs nothing done, so
# complaining about ADMIN would send you chasing a problem you don't have.
if [ "$VISIBILITY" = "PUBLIC" ]; then
  echo "$REPO is public — its reusable workflows are already callable from"
  echo "anywhere, and this setting doesn't apply. Nothing to do."
  exit 0
fi

if [ "$PERM" != "ADMIN" ]; then
  echo "Signed in as '$WHO', which has $PERM on $REPO — this needs ADMIN." >&2
  echo "Switch accounts with \`gh auth switch\`." >&2
  exit 1
fi

BEFORE=$(gh api "repos/$REPO/actions/permissions/access" --jq .access_level 2>/dev/null || echo unknown)

if [ "$BEFORE" = "user" ]; then
  echo "✅ $REPO already allows callers owned by the same account (access_level=user)."
  exit 0
fi

echo "$REPO access_level is currently '$BEFORE'; setting it to 'user'…"

# access_level: none = this repository only; user = any repository owned by the
# same account; organization = any in the org (org-owned repositories only).
gh api -X PUT "repos/$REPO/actions/permissions/access" -f access_level=user

AFTER=$(gh api "repos/$REPO/actions/permissions/access" --jq .access_level)
if [ "$AFTER" != "user" ]; then
  echo "❌ still '$AFTER' after the write — check the token's scopes (needs repo/admin)." >&2
  exit 1
fi

echo "✅ $REPO now allows callers owned by the same account (access_level=user)."
echo
echo "Next, for each project that deploys:"
echo "  scripts/seed-deploy-secrets.sh uqiu/<repo>   # six secrets, once per repo"
