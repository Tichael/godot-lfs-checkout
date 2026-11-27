# LFS Checkout

A Godot editor plugin for teams working with large binary assets in Git LFS.
It brings the "check out before you edit" workflow of tools like Perforce to
the Godot editor:

- **Check out** an asset to take its Git LFS lock, so nobody else edits it at the same time.
- **Hijack** a file to edit it locally without the lock, for quick experiments.
  Hijacked files can't be submitted until you check them out.
- Group data changes in **changelists**, then **submit** them (commit, push and
  release the locks) or **shelve** them for later.
- Keep data on **data branches** like `main`, enforced by a pre-commit hook,
  while code uses any branch.
- See lock and change status right in the **FileSystem dock**.
- Manage changelists and code changes from a **Source Control dock**.
- Browse history in a **Git Graph** bottom panel.

## Requirements

- Godot 4.4 or later
- `git` and `git-lfs` on your `PATH`
- A remote that supports the [Git LFS locking API](https://github.com/git-lfs/git-lfs/blob/main/docs/api/locking.md)
  (GitHub, GitLab, Gitea, Forgejo and others)

## Installation

The repository root is the addon folder, so put it at `addons/lfs_checkout`.

As a git submodule (recommended if you want updates):

```sh
git submodule add https://github.com/Tichael/godot-lfs-checkout.git addons/lfs_checkout
```

Or download the repository and copy its contents to `addons/lfs_checkout`.

Then enable **LFS Checkout** in **Project > Project Settings > Plugins**.

## Setup

Mark the file types that need locking as `lockable` in your `.gitattributes`:

```gitattributes
*.png filter=lfs diff=lfs merge=lfs -text lockable
*.blend filter=lfs diff=lfs merge=lfs -text lockable
*.wav filter=lfs diff=lfs merge=lfs -text lockable
```

Git LFS keeps lockable files read-only until you lock them. Your Godot
project can be the repository root or a subfolder of it.

### Git LFS in each clone

Git LFS needs its filter configured and its hooks (`pre-push`,
`post-checkout`, `post-commit`, `post-merge`) installed in every clone. The
filter often comes from your global or system git config, but the hooks don't:
without `pre-push`, a push sends pointer files without uploading the LFS
files, and without the others, lockable files aren't made read-only.

When the project is opened, the addon checks this clone. If something is
missing, it warns in the Output panel and the dock, and offers to fix it. You
can also run **Project > Tools > Source Control: Set Up Git LFS in This Clone**.
The fix configures the filter for this clone if needed and adds the missing
hooks. It never replaces an existing hook: if one doesn't run Git LFS, run
`git lfs update --manual` to see the lines to add to it.

## Data branches

A lock only stops two people from pushing the same file at once. It doesn't
know about branches: if a data change sits on a feature branch after its lock
is released, someone else can lock and change the same file on `main`, and
merging the branch later conflicts in a binary file that can't be merged.

So data stays on **data branches**, and code can use any branch:

- **Data files** are the files marked `lockable`, plus their Godot `.import` files.
- Data files can only be committed on a data branch. On other branches, hijack
  them to try changes locally, or check them out if the repository allows it (see below).
- Checking out requires the latest version of the file, so you never lock an old copy.
- A lock can't be released while commits touching the file are unpushed.

By default, `main` and `master` are the data branches. To change the settings,
commit a `.lfscheckout` file at the repository root:

```ini
[lfs-checkout]
	# Data branches; listing any replaces the defaults
	dataBranch = main
	dataBranch = release/*
	# Allow checking out data on code branches (default: false)
	allowLockOnCodeBranches = true
```

### Data work on a code branch

With `allowLockOnCodeBranches = true`, a developer can check out and edit data
while on a feature branch, without committing it there:

1. Check out the data files. Your copy has to match the latest version on the
   primary data branch (the first one listed that exists, usually `main`). If
   your copy is unchanged but older, the addon loads the latest version first.
   If you've already edited an older version, checkout is refused.
2. Work on your code and data as usual. The data stays uncommitted, and you keep the locks.
3. **Submit** the changelist. The addon sets your other changes aside in a
   stash, switches to `main`, brings it up to date, commits and pushes the
   changelist, releases its locks, switches back and restores your other changes.

If any step fails, the addon stops, switches back and restores what it can,
and a dialog says what's left to do.

### Pre-commit hook

The addon installs a git `pre-commit` hook in each clone when the project is
opened in the editor. The hook applies the data branch rule to every commit,
including ones made from the command line, VS Code or other git tools. Merging
a data branch into a code branch is allowed.

The addon never replaces a `pre-commit` hook it didn't install. If you already
have one, add this line to it (the Output panel shows the exact path):

```sh
sh "$(git rev-parse --show-toplevel)/addons/lfs_checkout/hooks/pre-commit.sh" || exit 1
```

Use **Project > Tools > Source Control: Reinstall Pre-Commit Hook** if it goes missing.

### Emergency bypass

When data really has to go on another branch:

- **Project > Tools > Source Control: Toggle Data Branch Bypass** turns the
  rules off for your clone (it sets `git config lfs-checkout.bypass true`).
  The dock shows a warning until you turn it back off.
- `LFS_CHECKOUT_BYPASS=1 git commit ...` bypasses the hook for one command.

### Checking on the server

Hooks are local, so `git commit --no-verify` or a clone where nobody opened the
editor can still get around them. For a guarantee, add a check to your CI. For
example, on GitHub:

```yaml
name: Data branch check
on: pull_request
jobs:
  data-branch:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Fail if the pull request changes data files
        run: |
          data=$(git diff --name-only --no-renames "origin/${{ github.base_ref }}...HEAD" \
            | sed 's/\.import$//' | git check-attr --stdin lockable | grep ': lockable: set$' || true)
          if [ -n "$data" ]; then
            echo "Data files belong on a data branch, not in a pull request:"
            echo "$data"
            exit 1
          fi
```

## Changelists

Data files are organized in changelists in the Source Control dock. A file
goes in **Default** when you check it out or change it. Create named
changelists with the **+** button, and move files between them from the dock
or with **Move to Changelist** in the FileSystem right-click menu. A file's
`.import` file always stays with it.

Each changelist can be:

- **Submitted:** you describe the change, and the addon commits exactly the
  changelist's files, pushes, and releases their locks. Other staged or changed
  files aren't included. Named changelists are deleted once submitted. If the
  push fails, the changelist shows **[push pending]**; submit it again to retry.
- **Shelved:** its changes are stashed, and its locks are kept. Unshelve to
  bring them back. A file whose lock was lost in the meantime comes back hijacked.
  Shelves are local `git stash` entries, so teammates can't see them.

Changelists are stored in `.git/lfs-checkout/`, so they're local to your clone
and never committed. Code files aren't in changelists: they keep the usual
staged and unstaged lists and the commit box.

## Workflow

Right-click a file in the FileSystem dock:

| Status | Meaning | Actions |
| --- | --- | --- |
| *(none)* | Lockable and unlocked | Check Out, Check Out to Changelist, Hijack |
| **[Checked Out]** | You hold the lock | Unlock, Move to Changelist, Revert |
| **[Locked: name]** | Someone else holds the lock | View lock info, Hijack |
| **[Hijacked]** | Changed without the lock | Promote to Check Out, Revert |
| **[Untracked]** / **[Added]** | New file, not in the repo yet; no lock needed | Move to Changelist, Discard |

Status refreshes when the editor regains focus and every 60 seconds.

## License

[MIT](LICENSE)
