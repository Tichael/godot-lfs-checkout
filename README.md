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

## Workflow

Right-click a file in the FileSystem dock:

| Status | Meaning | Actions |
| --- | --- | --- |
| *(none)* | Lockable and unlocked | Check Out, Hijack |
| **[Checked Out]** | You hold the lock | Unlock, Stage, Revert |
| **[Locked: name]** | Someone else holds the lock | View lock info, Hijack |
| **[Hijacked]** | Changed without the lock | Promote to Check Out, Revert |
| **[Untracked]** / **[Added]** | New file, not in the repo yet; no lock needed | Stage, Discard |

Status refreshes when the editor regains focus and every 60 seconds.

## License

[MIT](LICENSE)
