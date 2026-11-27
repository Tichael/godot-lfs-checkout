#!/bin/sh
# LFS Checkout pre-commit check.
#
# Data files can only be committed on data branches. Data files are files
# marked `lockable` in .gitattributes, plus their Godot .import files.
#
# Data branches are listed in .lfscheckout at the repository root:
#
#   [lfs-checkout]
#       dataBranch = main
#       dataBranch = release/*
#
# Without that file, only `main` is a data branch.
#
# Merging a data branch into another branch is allowed: data files that match
# the merged commit exactly aren't counted.
#
# Emergency bypass:
#   git config lfs-checkout.bypass true      (this clone, until you unset it)
#   LFS_CHECKOUT_BYPASS=1 git commit ...     (a single command)

if [ "$LFS_CHECKOUT_BYPASS" = "1" ] || [ "$(git config --bool lfs-checkout.bypass)" = "true" ]; then
	echo "LFS Checkout: data branch check bypassed." >&2
	exit 0
fi

root=$(git rev-parse --show-toplevel) || exit 0

# Branch being committed to. HEAD is detached during a rebase, so use the
# branch being rebased.
branch=$(git symbolic-ref --short -q HEAD)
if [ -z "$branch" ]; then
	for state in rebase-merge rebase-apply; do
		head_name=$(git rev-parse --git-path "$state/head-name")
		if [ -f "$head_name" ]; then
			branch=$(sed 's#^refs/heads/##' "$head_name")
			break
		fi
	done
fi

patterns=$(git config -f "$root/.lfscheckout" --get-all lfs-checkout.dataBranch 2>/dev/null)
[ -z "$patterns" ] && patterns=main

# Patterns like release/* must not expand to file names (for the rest of the script)
set -f
for pattern in $patterns; do
	case "$branch" in
		$pattern) exit 0 ;;
	esac
done

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# Staged paths; renames count as a delete plus an add, so both paths are checked
git -c core.quotepath=false diff --cached --name-only --no-renames > "$tmp/staged"
[ -s "$tmp/staged" ] || exit 0

# The path whose lockable attribute decides: the file itself, or the asset an .import file belongs to
sed 's/\.import$//' "$tmp/staged" > "$tmp/owners"
git check-attr --stdin lockable < "$tmp/owners" | sed 's/.*: lockable: //' > "$tmp/values"

# Staged paths whose value is "set"
awk 'NR == FNR { value[FNR] = $0; next } value[FNR] == "set"' "$tmp/values" "$tmp/staged" > "$tmp/data"

merging=""
git rev-parse -q --verify MERGE_HEAD > /dev/null && merging=1

: > "$tmp/blocked"
while IFS= read -r path; do
	# Taken unchanged from the branch being merged
	if [ -n "$merging" ] && git diff --cached --quiet MERGE_HEAD -- "$path"; then
		continue
	fi
	printf '  %s\n' "$path" >> "$tmp/blocked"
done < "$tmp/data"

[ -s "$tmp/blocked" ] || exit 0

{
	echo "LFS Checkout: data files can only be committed on a data branch."
	echo
	echo "Branch:        ${branch:-(detached HEAD)}"
	echo "Data branches: $(echo $patterns)"
	echo
	echo "Data files in this commit:"
	cat "$tmp/blocked"
	echo
	echo "Commit them from a data branch instead, or unstage them:"
	echo "  git restore --staged -- <file>"
	echo
	echo "In an emergency, bypass the check for one commit:"
	echo "  LFS_CHECKOUT_BYPASS=1 git commit ..."
} >&2
exit 1
