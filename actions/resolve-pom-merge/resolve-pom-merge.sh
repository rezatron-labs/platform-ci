#!/usr/bin/env sh
# Resolve a pom.xml merge conflict whose only real difference is the project version.
#
# A GitFlow back-merge conflicts on <version> by construction: main carries the released
# version, develop carries the next -SNAPSHOT, and the merge base carries neither. Taking
# one side wholesale (`git checkout --ours` / `--theirs`) would silently discard the OTHER
# side's pom edits — a dependency added on develop while the release soaked, say — so this
# normalises the project version on all three sides, runs a genuine three-way merge, and
# writes the wanted version back afterwards.
#
# Anything that still conflicts once the version is out of the picture is a real
# disagreement about dependencies, plugins or properties. That is a human's call and this
# script refuses to guess at it.
#
# POSIX sh + awk + git only: the self-hosted runner is not guaranteed to have anything else.
#
# usage: resolve-pom-merge.sh <final-version>
#        run from the repo root, with a conflicted pom.xml in the index.

set -eu

FINAL_VERSION=${1:?usage: resolve-pom-merge.sh <final-version>}
PLACEHOLDER=0.0.0-MERGE-PLACEHOLDER

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Conflicted index stages: :1 merge base, :2 ours (branch being merged into), :3 theirs.
git show :1:pom.xml > "$WORK/base.raw"
git show :2:pom.xml > "$WORK/ours.raw"
git show :3:pom.xml > "$WORK/theirs.raw"

# The project version is the first <version> AFTER </parent> — the one before it belongs
# to the parent POM and must be left alone.
normalise() {
  awk -v ph="$PLACEHOLDER" '
    /<\/parent>/ { after_parent = 1 }
    !replaced && after_parent && /<version>/ {
      sub(/<version>[^<]*<\/version>/, "<version>" ph "</version>")
      replaced = 1
    }
    { print }
  ' "$1" > "$2"
  if ! grep -q "$PLACEHOLDER" "$2"; then
    echo "resolve-pom-merge: no project <version> found after </parent> in $1" >&2
    exit 1
  fi
}

normalise "$WORK/base.raw"   "$WORK/base.xml"
normalise "$WORK/ours.raw"   "$WORK/ours.xml"
normalise "$WORK/theirs.raw" "$WORK/theirs.xml"

if ! git merge-file -L ours -L base -L theirs \
     "$WORK/ours.xml" "$WORK/base.xml" "$WORK/theirs.xml"; then
  echo "resolve-pom-merge: pom.xml conflicts beyond the project version; resolve by hand" >&2
  exit 1
fi

awk -v ph="$PLACEHOLDER" -v v="$FINAL_VERSION" \
  '{ sub("<version>" ph "</version>", "<version>" v "</version>"); print }' \
  "$WORK/ours.xml" > pom.xml

echo "resolve-pom-merge: pom.xml merged cleanly, project version set to $FINAL_VERSION"
