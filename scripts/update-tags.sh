#!/usr/bin/env bash
# Create the version tag for a release and move the "latest" and major
# version tags to HEAD.
#
# Usage: update-tags.sh <version> [remote]
#
# Run from inside the checked-out repository with HEAD at the release
# commit. The script is idempotent: re-running it on a commit that is
# already tagged changes nothing on the remote. Moving tags are replaced
# with one atomic force-push rather than deleted and recreated, so there is
# never a moment when "latest" does not exist and the delete/recreate race
# that GitHub rejects with "missing necessary objects" is avoided.
set -euo pipefail

readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

readonly MAX_ATTEMPTS=3
readonly RETRY_DELAY=5

usage() {
    echo "Usage: $0 <version> [remote]" >&2
    exit 1
}

VERSION="${1:-}"
REMOTE="${2:-origin}"
[ -n "$VERSION" ] || usage

MAJOR="${VERSION%%.*}"
HEAD_SHA="$(git rev-parse HEAD)"

# Commit that a tag points at on the remote, or empty when the tag is absent.
# ls-remote prints the peeled "^{}" line after an annotated tag, so the last
# line is always the commit whether the tag is annotated or lightweight.
remote_commit() {
    git ls-remote --tags "$REMOTE" "refs/tags/$1" "refs/tags/$1^{}" \
        | tail -n 1 | cut -f 1
}

push_with_retry() {
    local attempt
    for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
        if git push "$@"; then
            return 0
        fi
        if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
            log_warn "Push failed (attempt $attempt/$MAX_ATTEMPTS), retrying in ${RETRY_DELAY}s"
            sleep "$RETRY_DELAY"
        fi
    done
    log_error "Push failed after $MAX_ATTEMPTS attempts"
    return 1
}

# --- Immutable version tag -------------------------------------------------

if [ -n "$(remote_commit "v$VERSION")" ]; then
    log_info "Tag v$VERSION already exists on $REMOTE, leaving it alone"
else
    log_info "Creating tag v$VERSION at ${HEAD_SHA:0:7}"
    git tag -f -a "v$VERSION" -m "Release v$VERSION"
    push_with_retry "$REMOTE" "refs/tags/v$VERSION"
fi

# --- Moving tags -----------------------------------------------------------

if [ "$(remote_commit latest)" == "$HEAD_SHA" ] && [ "$(remote_commit "v$MAJOR")" == "$HEAD_SHA" ]; then
    log_info "Tags latest and v$MAJOR already point at ${HEAD_SHA:0:7}, nothing to do"
    exit 0
fi

log_info "Moving tags latest and v$MAJOR to ${HEAD_SHA:0:7}"
git tag -f -a latest -m "Latest release: v$VERSION"
git tag -f -a "v$MAJOR" -m "Latest v$MAJOR release: v$VERSION"
push_with_retry --atomic --force "$REMOTE" refs/tags/latest "refs/tags/v$MAJOR"
