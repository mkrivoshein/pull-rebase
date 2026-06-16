# pull-rebase

`pull-rebase.sh` is a small Bash utility for keeping a directory of sibling Git
repositories on `main` and up to date.

It is useful when you work across several related GitHub repositories and want a
single command that:

- lists all sibling Git repositories
- reports open pull requests
- highlights open pull requests with merge conflicts
- safely leaves completed feature branches and switches back to `main`
- fast-forwards `main` from `origin/main`
- prints recently merged pull requests included in the update
- ends with a compact per-repository summary

## Repository Layout

Put `pull-rebase.sh` in a parent directory that contains Git repositories as
direct child directories:

```text
workspace/
  pull-rebase.sh
  service-api/
    .git/
  service-web/
    .git/
  worker/
    .git/
```

Run it from that parent directory:

```bash
./pull-rebase.sh
```

Only direct child directories with `.git/` are processed.

## Requirements

- Bash
- Git
- GitHub CLI (`gh`) for repository metadata and pull request reporting

Authenticate `gh` before using the GitHub-related features:

```bash
gh auth login
gh auth status
```

The script still performs Git synchronization without usable `gh`, but pull
request metadata will be unavailable.

## What It Does

For each sibling repository, the script checks the current branch.

If the repository is already on `main`, it:

- prints open pull requests when any exist
- warns about open pull requests with merge conflicts
- fetches `origin/main`
- fast-forwards local `main` when possible
- prints recently merged pull requests included in the fast-forward

If the repository is on another branch, it first checks whether the branch is
safe to leave. A branch is considered safe when:

- there are no unstaged, staged, or untracked changes
- there are no unpushed commits that still need attention
- or the branch has already been merged into `origin/main`
- or GitHub reports a merged pull request for that branch into `main`

When the branch is safe, the script checks out `main`, fast-forwards it, and
prints relevant pull request context.

When the branch has unfinished work, the script leaves it untouched and reports
why.

## Safety Behavior

The script is intentionally conservative:

- it uses `git merge --ff-only FETCH_HEAD`
- it does not create merge commits
- it does not rebase branches
- it does not delete branches
- it does not stash changes
- it does not discard local work

Repositories are skipped or left as-is when the script cannot safely continue.

## GitHub Pull Request Reporting

When `gh` is authenticated and the repository remote points to GitHub, the
script prints:

- repository visibility, archived state, and description in the initial list
- open pull requests
- warnings for open pull requests with merge conflicts
- merged pull requests related to branches that are safe to leave
- merged pull requests included in fast-forward updates

Merge conflict warnings are based on GitHub pull request mergeability fields
reported by `gh pr list`.

## Example

```text
pull-rebase - syncing git repositories in /home/user/workspace
-----------------------------------------------------------------
Found 3 repositories:
  service-api  private active  API service
  service-web  private active  Web app
  worker       private active  Background worker

[service-api]   open pull requests:
[service-api]     🕒 open PR (new): #12 chore(deps): bump dependency [dependabot/npm/pkg] @dependabot
[service-api]     ⚠️ open PR (2d old), merge conflict: #13 feat: update API [feat/api-update] @user
[service-api] main is up to date
[service-web] on branch 'feat/new-ui'
[service-web]   branch has a merged pull request:
[service-web]     #42 feat: new UI (merged 2026-06-16T11:00:00Z) https://github.com/org/service-web/pull/42
[service-web]   branch is safe to leave - switching to main
[service-web] main fast-forwarded 2 commit(s)
[service-web]   recently merged pull requests:
[service-web]     #42 feat: new UI (merged 2026-06-16T11:00:00Z) https://github.com/org/service-web/pull/42

Summary
---------------------------------------------------------------
service-api  OK main - already up to date
service-web  UP main - fast-forwarded 2 commit(s)
worker       OK main - already up to date
```

The real script uses colored output and compact symbols in the terminal.

## Installation

Clone this repository or download the script:

```bash
git clone https://github.com/mkrivoshein/pull-rebase.git
```

Then copy or symlink `pull-rebase.sh` into the parent directory that contains
your repositories:

```bash
ln -s /path/to/pull-rebase/pull-rebase.sh /path/to/workspace/pull-rebase.sh
```

Make sure it is executable:

```bash
chmod +x /path/to/workspace/pull-rebase.sh
```

## License

MIT. See [LICENSE](LICENSE).
