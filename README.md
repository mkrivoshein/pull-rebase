# pull-rebase

`pull-rebase.sh` is a small Bash utility for keeping a directory of sibling or nested Git
repositories on `main` and up to date.

It is useful when you work across several related GitHub repositories and want a
single command that:

- lists all Git repositories below the root
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

Nested layouts are supported as well. The script walks down from the root and
stops at the first directory that contains a `.git` entry, so workspaces that
mirror GitHub paths work too:

```text
workspace/
  pull-rebase.sh
  owner-a/
    service-api/
      .git/
    infra/
      .git/
  owner-b/
    infra/
      .git/
```

Repositories are identified by their path relative to the root, so
`owner-a/infra` and `owner-b/infra` are reported separately.

Discovery never descends into a directory that already contains a `.git`
entry, which keeps vendored clones and submodules from being treated as
separate repositories. A `.git` **file** (worktrees and submodule checkouts)
is recognized as a repository too.

### Options

| Option | Purpose |
| --- | --- |
| `--root DIR` | Root directory to scan. Defaults to the script's directory. |
| `--depth N` | Maximum directory depth to search. Defaults to `3`. |
| `--exclude GLOB` | Skip matching relative paths. May be repeated. |
| `-h`, `--help` | Show usage information. |
| `PATH...` | Positional paths limit the sync to that part of the tree. |

```bash
./pull-rebase.sh --root ~/src --depth 4
./pull-rebase.sh --exclude 'archive/*' --exclude 'vendor'
./pull-rebase.sh owner-a/
```

The maximum depth can also be set through the `PULL_REBASE_DEPTH` environment
variable. Exclude patterns can be stored in a `.pull-rebase-ignore` file in
the root directory (one glob per line, `#` starts a comment); the file path
can be overridden with `PULL_REBASE_IGNORE`.

### Environment

| Variable | Purpose |
| --- | --- |
| `PULL_REBASE_DEPTH` | Default maximum search depth. |
| `PULL_REBASE_IGNORE` | Path to the ignore file. |

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

For each repository, the script checks the current branch.

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

Open pull request CI annotations use these markers:

- `CI ✅` all reported checks completed successfully, or were neutral/skipped
- `CI ❌` at least one reported check failed or requires attention
- `CI ⏳` at least one reported check is still pending or running
- `CI -` no status checks are configured or reported for the pull request
- `CI ❔` GitHub reported checks, but their combined state could not be classified

## Example

```text
pull-rebase - syncing git repositories in /home/user/workspace
-----------------------------------------------------------------
Found 3 repositories:
  service-api  private active  API service
  service-web  private active  Web app
  worker       private active  Background worker

[service-api]   open pull requests:
[service-api]     🕒 open PR (new, CI ✅): #12 chore(deps): bump dependency [dependabot/npm/pkg] @dependabot
[service-api]     ⚠️ open PR (2d old, CI ❌), merge conflict: #13 feat: update API [feat/api-update] @user
[service-api]     🕒 open PR (3d old, CI -): #14 docs: clarify setup [docs/setup] @user
[service-api]     🚨 old open PR (45d old, CI ✅, appears abandoned): #15 refactor: split auth flow [feat/auth-split] @user
[service-api]     🚨 old open PR (62d old, CI ⏳, last activity 3d ago): #16 feat: streaming export [feat/stream-export] @user
[service-api] main is up to date
[service-web] on branch 'feat/new-ui'
[service-web]   branch has a merged pull request:
[service-web]     ✅ merged PR (1d ago): #42 feat: new UI [feat/new-ui] @user
[service-web]   branch is safe to leave - switching to main
[service-web] main fast-forwarded 2 commit(s)
[service-web]   recently merged pull requests:
[service-web]     ✅ merged PR (1d ago): #42 feat: new UI [feat/new-ui] @user

Summary
---------------------------------------------------------------
service-api  OK main - already up to date
service-web  UP main - fast-forwarded 2 commit(s)
worker       OK main - already up to date
```

The real script uses colored output and compact symbols in the terminal.

With a nested layout the repositories are grouped by their parent directory
and identified by their path relative to the root:

```text
pull-rebase — syncing git repositories in /home/user/workspace
-----------------------------------------------------------------
Found 2 repositories:
  owner-a/
  owner-a/service-api  private active  API service
  owner-b/
  owner-b/service-api  private active  API service

[owner-a/service-api] main is up to date
[owner-b/service-api] main is up to date

Summary
---------------------------------------------------------------
owner-a/service-api  OK main - already up to date
owner-b/service-api  OK main - already up to date
```

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
