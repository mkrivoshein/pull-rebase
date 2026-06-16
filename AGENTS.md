# pull-rebase

`pull-rebase` is a small Bash utility for synchronizing sibling GitHub
repositories. It reports pull request context via `gh`, safely leaves completed
feature branches, fast-forwards `main`, and summarizes repository status.

Keep changes focused and conservative. This script should not discard local
work, delete branches, create merge commits, or perform destructive Git actions.

## Commit Format

Use [Conventional Commits](https://www.conventionalcommits.org/) with GPG signing.

When adding an AI attribution trailer, use the one that matches the assistant
that made the change (adjust model version as appropriate).
