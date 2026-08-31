#!/usr/bin/env bash
#
# mtk worktree — give an agent a disposable copy of the repo to work in.
#
# A git worktree is a second folder checked out on its own branch, sharing the
# same repository. The agent edits there; your working folder never moves. When
# the work is done you either merge it or delete the folder, and deleting the
# folder is not the same as deleting the work.
#
# Usage:
#   worktree.sh new  <slug> [--no-link] create ../<repo>-mtk-<slug> on branch mtk/<slug>
#                                      and symlink node_modules from the main folder
#   worktree.sh path <slug>            print its path (nothing else, for scripting)
#   worktree.sh diff <slug>            what changed there, vs the branch it came from
#   worktree.sh list                   every mtk worktree of this repo
#   worktree.sh drop <slug> [--purge]  remove the folder; --purge also deletes the branch
#
# All local. No network, no GitHub, no push.
#
# Exit codes: 0 ok · 1 usage error · 2 not a git repo · 3 refused (unsafe)

set -uo pipefail

CMD="${1:-}"; shift || true

die()  { echo "worktree.sh: $*" >&2; exit "${2:-1}"; }
note() { echo "worktree.sh: $*" >&2; }

git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository" 2

# Resolve the MAIN working folder, not whichever worktree we are standing in.
# --git-common-dir points at the main repo's .git for every linked worktree, so
# its parent is the main root. Without this, running any command from inside a
# worktree computes paths against that worktree and finds nothing.
COMMON=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
if [ -n "${COMMON:-}" ] && [ "$(basename "$COMMON")" = ".git" ]; then
  REPO_ROOT=$(dirname "$COMMON")
else
  REPO_ROOT=$(git rev-parse --show-toplevel)
fi
REPO_NAME=$(basename "$REPO_ROOT")
PARENT=$(dirname "$REPO_ROOT")

# Report to the observability server if one is listening. Never fails, never
# blocks more than 2s.
EVENT="$(cd "$(dirname "$0")" && pwd)/event.sh"
emit() { [ -x "$EVENT" ] && "$EVENT" "$@" >/dev/null 2>&1 || true; }

slugify() {  # keep it a safe folder and branch name
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9._-]\{1,\}/-/g' -e 's/^-*//' -e 's/-*$//' | cut -c1-40
}

wt_path()   { printf '%s/%s-mtk-%s' "$PARENT" "$REPO_NAME" "$1"; }
wt_branch() { printf 'mtk/%s' "$1"; }

case "$CMD" in

  new)
    RAW="${1:-}"; [ -n "$RAW" ] || die "usage: worktree.sh new <slug> [--no-link]"
    LINK=1; [ "${2:-}" = "--no-link" ] && LINK=0
    SLUG=$(slugify "$RAW"); [ -n "$SLUG" ] || die "slug '$RAW' reduces to nothing"
    PATH_="$(wt_path "$SLUG")"; BRANCH="$(wt_branch "$SLUG")"

    [ -e "$PATH_" ] && die "$PATH_ already exists — pick another slug, or drop that one" 3

    BASE=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || git rev-parse --short HEAD)
    [ -n "$BASE" ] || die "cannot determine the current branch" 3

    if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
      note "branch $BRANCH already exists — checking it out rather than creating it"
      git worktree add "$PATH_" "$BRANCH" >&2 || die "git worktree add failed" 3
    else
      git worktree add "$PATH_" -b "$BRANCH" >&2 || die "git worktree add failed" 3
    fi

    # A worktree checks out tracked files only, so anything gitignored -- most of
    # all node_modules -- is simply absent, and every check fails for a reason
    # that has nothing to do with the code. Link it rather than reinstalling.
    if [ "$LINK" -eq 1 ] && [ -d "$REPO_ROOT/node_modules" ] && [ ! -e "$PATH_/node_modules" ]; then
      ln -s "$REPO_ROOT/node_modules" "$PATH_/node_modules" \
        && note "linked node_modules from the main folder"
    fi

    # remember where it came from, so `diff` knows what to compare against
    git config "mtk.worktree.$SLUG.base" "$BASE"

    emit worktree_new slug="$SLUG" branch="$BRANCH" base="$BASE" path="$PATH_"
    note "created $BRANCH from $BASE"
    note "your working folder $REPO_ROOT was not touched"
    printf '%s\n' "$PATH_"          # stdout is the path, and only the path
    ;;

  path)
    SLUG=$(slugify "${1:-}"); [ -n "$SLUG" ] || die "usage: worktree.sh path <slug>"
    P="$(wt_path "$SLUG")"
    [ -d "$P" ] || die "no worktree for '$SLUG' (expected $P)" 3
    printf '%s\n' "$P"
    ;;

  diff)
    SLUG=$(slugify "${1:-}"); [ -n "$SLUG" ] || die "usage: worktree.sh diff <slug>"
    P="$(wt_path "$SLUG")"
    [ -d "$P" ] || die "no worktree for '$SLUG'" 3
    BASE=$(git config --get "mtk.worktree.$SLUG.base" || echo "")
    [ -n "$BASE" ] || BASE="HEAD"

    echo "### committed on $(wt_branch "$SLUG") since $BASE"
    git -C "$P" --no-pager log --oneline "$BASE..HEAD" 2>/dev/null || echo "  (none)"
    echo
    echo "### files changed vs $BASE"
    git -C "$P" --no-pager diff --stat "$BASE...HEAD" 2>/dev/null || echo "  (none)"
    echo
    echo "### not yet committed in the worktree"
    git -C "$P" --no-pager status --short 2>/dev/null || echo "  (clean)"
    ;;

  list)
    echo "mtk worktrees of $REPO_NAME:"
    git worktree list --porcelain \
      | awk -v p="$PARENT/$REPO_NAME-mtk-" '/^worktree /{w=substr($0,10); if (index(w,p)==1) print "  " w}'
    ;;

  drop)
    SLUG=$(slugify "${1:-}"); [ -n "$SLUG" ] || die "usage: worktree.sh drop <slug> [--purge]"
    PURGE=0; [ "${2:-}" = "--purge" ] && PURGE=1
    P="$(wt_path "$SLUG")"; BRANCH="$(wt_branch "$SLUG")"

    [ "$P" = "$REPO_ROOT" ] && die "refusing to remove the main working folder" 3
    [ -d "$P" ] || die "no worktree for '$SLUG'" 3

    if [ -n "$(git -C "$P" status --porcelain 2>/dev/null)" ]; then
      note "WARNING: $P has uncommitted changes; they will be lost"
    fi

    [ -L "$P/node_modules" ] && rm -f "$P/node_modules"   # our symlink, not their files
    git worktree remove --force "$P" >&2 || die "git worktree remove failed" 3
    emit worktree_drop slug="$SLUG" branch="$BRANCH" purge="$PURGE"
    note "folder removed: $P"

    if [ "$PURGE" -eq 1 ]; then
      git branch -D "$BRANCH" >&2 2>/dev/null && note "branch deleted: $BRANCH" \
        || note "branch $BRANCH not deleted (already gone, or checked out elsewhere)"
      git config --unset "mtk.worktree.$SLUG.base" 2>/dev/null || true
    else
      note "branch $BRANCH kept — the commits are still there"
      note "recreate the folder any time with: worktree.sh new $SLUG"
    fi
    ;;

  ""|-h|--help|help)
    sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
    ;;

  *)
    die "unknown command '$CMD' — try: new, path, diff, list, drop"
    ;;
esac
