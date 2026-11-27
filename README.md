# LFS Checkout

A Godot editor plugin for teams working with large binary assets in Git LFS.
It brings the "check out before you edit" workflow of tools like Perforce to
the Godot editor:

- **Check out** an asset to take its Git LFS lock, so nobody else edits it at the same time.
- **Hijack** a file to edit it locally without the lock, for quick experiments.
  Hijacked files can't be staged until you check them out.
- See lock and change status right in the **FileSystem dock**.
- Stage, commit, pull and push from a **Source Control dock**.
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

## Data branches

A lock only stops two people from pushing the same file at once. It doesn't
know about branches: if a data change sits on a feature branch after its lock
is released, someone else can lock and change the same file on `main`, and
merging the branch later conflicts in a binary file that can't be merged.

So data stays on **data branches**, and code can use any branch:

- **Data files** are the files marked `lockable`, plus their Godot `.import` files.
- Data files can only be checked out and committed on a data branch. On other
  branches, hijack them to try changes locally.
- Checking out requires the latest version of the file, so you never lock an old copy.
- A lock can't be released while commits touching the file are unpushed.

By default, only `main` is a data branch. To add others, such as release
branches, commit a `.lfscheckout` file at the repository root:

```ini
[lfs-checkout]
	dataBranch = main
	dataBranch = release/*
```

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

## Workflow

Right-click a file in the FileSystem dock:

| Status | Meaning | Actions |
| --- | --- | --- |
| *(none)* | Lockable and unlocked | Check Out (on a data branch), Hijack |
| **[Checked Out]** | You hold the lock | Unlock, Stage, Revert |
| **[Locked: name]** | Someone else holds the lock | View lock info, Hijack |
| **[Hijacked]** | Changed without the lock | Promote to Check Out, Revert |
| **[Untracked]** / **[Added]** | New file, not in the repo yet; no lock needed | Stage, Discard |

Status refreshes when the editor regains focus and every 60 seconds.

## License

[MIT](LICENSE)
