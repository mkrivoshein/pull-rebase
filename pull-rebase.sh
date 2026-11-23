#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mikhail Krivoshein
# See https://github.com/mkrivoshein/pull-rebase/blob/main/LICENSE for the full license text.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Repository identity used as the log prefix and the summary key. It is set
# per repository before any output helper is called.
repo=""

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

info()    { printf '%b[%s]%b %s\n' "$CYAN" "$repo" "$RESET" "$*"; }
ok()      { printf '%b[%s]%b %s\n' "$GREEN" "$repo" "$RESET" "$*"; }
warn()    { printf '%b[%s]%b %s\n' "$YELLOW" "$repo" "$RESET" "$*"; }
error()   { printf '%b[%s]%b %s\n' "$RED" "$repo" "$RESET" "$*"; }
muted()   { printf '%b[%s]%b %b%s%b\n' "$CYAN" "$repo" "$RESET" "$DIM" "$*" "$RESET"; }

age_text_from_epoch() {
    local event_epoch="$1" present_label="$2" past_suffix="$3"

    if [[ "$event_epoch" =~ ^[0-9]+$ ]]; then
        local now_epoch age_days
        now_epoch="$(date -u +%s)"
        age_days=$(( (now_epoch - event_epoch) / 86400 ))
        if (( age_days < 0 )); then
            age_days=0
        fi
        if (( age_days == 0 )); then
            printf '%s\n' "$present_label"
        else
            printf '%sd %s\n' "$age_days" "$past_suffix"
        fi
    else
        printf '%s\n' "age unknown"
    fi
}

# ── Options ────────────────────────────────────────────────────────────────────
ROOT_DIR="$SCRIPT_DIR"
MAX_DEPTH="${PULL_REBASE_DEPTH:-3}"
IGNORE_FILE_NAME=".pull-rebase-ignore"

declare -a exclude_patterns=()
declare -a path_filters=()

usage() {
    cat <<EOF
Usage: pull-rebase.sh [options] [PATH...]

Options:
  --root DIR        Root directory to scan (default: the script's directory)
  --depth N         Maximum directory depth to search (default: ${MAX_DEPTH})
  --exclude GLOB    Skip paths matching GLOB (relative to the root); repeatable
  -h, --help        Show this help and exit

Positional arguments limit the sync to the given paths (relative to the root
or absolute), e.g. ./pull-rebase.sh owner-a/

Environment:
  PULL_REBASE_DEPTH            Default maximum search depth
  PULL_REBASE_IGNORE           Path to an ignore file (default: <root>/${IGNORE_FILE_NAME})
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --root)
            [[ -n "${2:-}" ]] || { echo "--root requires a directory" >&2; exit 2; }
            ROOT_DIR="$2"
            shift 2
            ;;
        --root=*)
            ROOT_DIR="${1#*=}"
            shift
            ;;
        --depth)
            [[ -n "${2:-}" ]] || { echo "--depth requires a number" >&2; exit 2; }
            MAX_DEPTH="$2"
            shift 2
            ;;
        --depth=*)
            MAX_DEPTH="${1#*=}"
            shift
            ;;
        --exclude)
            [[ -n "${2:-}" ]] || { echo "--exclude requires a pattern" >&2; exit 2; }
            exclude_patterns+=("$2")
            shift 2
            ;;
        --exclude=*)
            exclude_patterns+=("${1#*=}")
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            while (( $# > 0 )); do
                path_filters+=("$1")
                shift
            done
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            path_filters+=("$1")
            shift
            ;;
    esac
done

[[ "$MAX_DEPTH" =~ ^[0-9]+$ ]] || { echo "--depth must be a non-negative integer" >&2; exit 2; }

if [[ ! -d "$ROOT_DIR" ]]; then
    echo "Root directory not found: $ROOT_DIR" >&2
    exit 2
fi
ROOT_DIR="$(cd "$ROOT_DIR" && pwd)"

IGNORE_FILE="${PULL_REBASE_IGNORE:-$ROOT_DIR/$IGNORE_FILE_NAME}"
if [[ -f "$IGNORE_FILE" ]]; then
    while IFS= read -r pattern || [[ -n "$pattern" ]]; do
        pattern="${pattern%%#*}"
        pattern="${pattern#"${pattern%%[![:space:]]*}"}"
        pattern="${pattern%"${pattern##*[![:space:]]}"}"
        [[ -n "$pattern" ]] && exclude_patterns+=("$pattern")
    done < "$IGNORE_FILE"
fi

# ── Discovery ──────────────────────────────────────────────────────────────────
# Walks down from the root and stops at the first directory that contains a
# .git entry (a directory for regular clones, a file for worktrees and
# submodules), so nested checkouts are never treated as separate repositories.
# Matches a relative path against a shell glob pattern. The pattern matches
# the path itself, any of its ancestors, or the basename.
is_excluded() {
    local rel="$1" pattern prefix rest
    for pattern in "${exclude_patterns[@]}"; do
        # shellcheck disable=SC2053  # intentional glob match, not a literal prefix
        if [[ "$rel" == $pattern ]]; then
            return 0
        fi
        # shellcheck disable=SC2053
        if [[ "$(basename "$rel")" == $pattern ]]; then
            return 0
        fi
        # Literal prefix of the pattern (up to the first glob character) also
        # excludes everything below it, e.g. "archive/*" excludes "archive/a/b".
        prefix="${pattern%%[?*\[\\]*}"
        prefix="${prefix%/}"
        if [[ -n "$prefix" && ( "$rel" == "$prefix" || "$rel" == "$prefix"/* ) ]]; then
            return 0
        fi
        # An ancestor of the path matching the pattern excludes the path too.
        rest="$rel"
        while [[ "$rest" == */* ]]; do
            rest="${rest%/*}"
            # shellcheck disable=SC2053
            if [[ "$rest" == $pattern ]]; then
                return 0
            fi
        done
    done
    return 1
}

discover_repos() {
    local dir="$1" depth="$2" sub rel
    for sub in "$dir"/*/; do
        [[ -d "$sub" ]] || continue
        sub="${sub%/}"
        rel="${sub#"$ROOT_DIR"/}"
        [[ "$rel" == "$sub" ]] && rel="$(basename "$sub")"
        is_excluded "$rel" && continue
        if [[ -e "$sub/.git" ]]; then
            printf '%s\n' "$rel"
        elif (( depth < MAX_DEPTH )); then
            discover_repos "$sub" $(( depth + 1 ))
        fi
    done
}

declare -a all_repos=()
while IFS= read -r rel; do
    [[ -n "$rel" ]] && all_repos+=("$rel")
done < <(discover_repos "$ROOT_DIR" 1 | LC_ALL=C sort)

# Positional path filters restrict the sync to a part of the tree.
if (( ${#path_filters[@]} > 0 )); then
    declare -a filtered_repos=()
    for rel in "${all_repos[@]}"; do
        for filter in "${path_filters[@]}"; do
            filter="${filter%/}"
            filter="${filter#"$ROOT_DIR"/}"
            if [[ "$rel" == "$filter" || "$rel" == "$filter"/* ]]; then
                filtered_repos+=("$rel")
                break
            fi
        done
    done
    all_repos=("${filtered_repos[@]+"${filtered_repos[@]}"}")
fi

# Column width shared by both the welcome list and the summary table
max_len=4
for rel in "${all_repos[@]}"; do
    (( ${#rel} > max_len )) && max_len=${#rel}
done

# ── Check whether gh CLI is usable (once) ─────────────────────────────────────
gh_available=false
if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
    gh_available=true
fi

# ── Helper: resolve a GitHub owner/repo from a repo dir ───────────────────────
github_nwo_for_dir() {
    local d="$1"
    local remote_url
    remote_url="$(git -C "$d" config --get remote.origin.url 2>/dev/null || true)"
    [[ -z "$remote_url" ]] && remote_url="$(git -C "$d" remote get-url origin 2>/dev/null || true)"
    [[ -z "$remote_url" ]] && return 1

    # Accept both SSH (git@github.com:owner/repo.git) and HTTPS
    if [[ "$remote_url" =~ github\.com[:/]([^/]+/[^/]+)(\.git)?$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]%.git}"
        return 0
    fi

    return 1
}

# ── Helper: fetch GitHub metadata for a repo dir ──────────────────────────────
# Sets gh_badge (icon string) and gh_desc (description) in caller's scope.
fetch_gh_meta() {
    local d="$1"
    gh_badge=""
    gh_desc=""

    local nwo
    nwo="$(github_nwo_for_dir "$d")" || return 0

    $gh_available || return 0

    local json
    json="$(gh repo view "$nwo" \
        --json nameWithOwner,description,isArchived,isPrivate 2>/dev/null)" || return 0

    local is_private is_archived description
    is_private="$(  echo "$json" | grep -o '"isPrivate":[^,}]*'  | cut -d: -f2 | tr -d ' "' || true)"
    is_archived="$( echo "$json" | grep -o '"isArchived":[^,}]*' | cut -d: -f2 | tr -d ' "' || true)"
    description="$( echo "$json" | sed 's/.*"description":"\([^"]*\)".*/\1/')"
    [[ "$description" == "null" || "$description" == "$json" ]] && description=""

    local vis_icon arc_icon
    [[ "$is_private"  == "true" ]] && vis_icon="🔒" || vis_icon="🌐"
    [[ "$is_archived" == "true" ]] && arc_icon="📦" || arc_icon="✅"

    gh_badge="${vis_icon} ${arc_icon}"
    gh_desc="$description"
    return 0
}

# ── Helpers: print pull request context ───────────────────────────────────────
print_open_prs() {
    local nwo="$1"

    $gh_available || {
        warn "  pull request report unavailable — gh CLI is not authenticated"
        return 0
    }
    [[ -n "$nwo" ]] || {
        return 0
    }

    local prs
    prs="$(gh pr list --repo "$nwo" --state open --limit 100 \
        --json number,title,headRefName,author,createdAt,updatedAt,mergeable,mergeStateStatus,statusCheckRollup \
        --jq 'def check_state: (.conclusion // .state // .status // "");
        .[] | .statusCheckRollup as $checks | (.author.login? // "unknown") as $author | [
            if (.mergeable == "CONFLICTING" or .mergeStateStatus == "DIRTY") then "CONFLICT" else "OK" end,
            $author,
            (.createdAt | fromdateiso8601 | tostring),
            (.updatedAt | fromdateiso8601 | tostring),
            if (($checks // []) | length) == 0 then "CI -"
            elif any($checks[]; (check_state == "FAILURE" or check_state == "ERROR" or check_state == "TIMED_OUT" or check_state == "CANCELLED" or check_state == "ACTION_REQUIRED" or check_state == "STARTUP_FAILURE")) then "CI ❌"
            elif any($checks[]; (check_state == "PENDING" or check_state == "QUEUED" or check_state == "IN_PROGRESS" or check_state == "REQUESTED" or check_state == "WAITING")) then "CI ⏳"
            elif all($checks[]; (check_state == "SUCCESS" or check_state == "SKIPPED" or check_state == "NEUTRAL")) then "CI ✅"
            else "CI ❔"
            end,
            "#\(.number) \(.title) [" + .headRefName + "] @" + $author
        ] | @tsv' \
        2>/dev/null || true)"

    if [[ -z "$prs" ]]; then
        return 0
    fi

    info "  open pull requests:"
    local now_epoch pr_status pr_author pr_created_epoch pr_updated_epoch pr_ci_text pr_line
    local pr_age_days pr_activity_days pr_age_text pr_meta_text pr_activity_text
    now_epoch="$(date -u +%s)"
    while IFS= read -r pr; do
        IFS=$'\t' read -r pr_status pr_author pr_created_epoch pr_updated_epoch pr_ci_text pr_line <<< "$pr"
        pr_age_text="$(age_text_from_epoch "$pr_created_epoch" "new" "old")"
        if [[ "$pr_created_epoch" =~ ^[0-9]+$ ]]; then
            pr_age_days=$(( (now_epoch - pr_created_epoch) / 86400 ))
            if (( pr_age_days < 0 )); then
                pr_age_days=0
            fi
        else
            pr_age_days=0
        fi
        if [[ -n "$pr_ci_text" ]]; then
            pr_meta_text="${pr_age_text}, ${pr_ci_text}"
        else
            pr_meta_text="$pr_age_text"
        fi

        if (( pr_age_days >= 30 )); then
            if [[ "$pr_updated_epoch" =~ ^[0-9]+$ ]]; then
                pr_activity_days=$(( (now_epoch - pr_updated_epoch) / 86400 ))
                if (( pr_activity_days <= 0 )); then
                    pr_activity_text="recent activity"
                elif (( pr_activity_days < 30 )); then
                    pr_activity_text="last activity ${pr_activity_days}d ago"
                else
                    pr_activity_text="appears abandoned"
                fi
            else
                pr_activity_text="appears abandoned"
            fi
            if [[ "$pr_status" == "CONFLICT" ]]; then
                error "    🚨 old open PR (${pr_meta_text}, ${pr_activity_text}), merge conflict: $pr_line"
            else
                error "    🚨 old open PR (${pr_meta_text}, ${pr_activity_text}): $pr_line"
            fi
        elif (( pr_age_days >= 7 )); then
            if [[ "$pr_status" == "CONFLICT" ]]; then
                warn "    ⚠️ aging open PR (${pr_meta_text}), merge conflict: $pr_line"
            else
                warn "    ⚠️ aging open PR (${pr_meta_text}): $pr_line"
            fi
        elif [[ "$pr_status" == "CONFLICT" ]]; then
            warn "    ⚠️ open PR (${pr_meta_text}), merge conflict: $pr_line"
        elif [[ "$pr_author" == "app/dependabot" || "$pr_author" == "dependabot" || "$pr_author" == "dependabot[bot]" ]]; then
            muted "    🕒 open PR (${pr_meta_text}): $pr_line"
        else
            info "    🕒 open PR (${pr_meta_text}): $pr_line"
        fi
    done <<< "$prs"
}

print_recent_merged_prs() {
    local d="$1" nwo="$2" range="$3"

    $gh_available || {
        return 0
    }
    [[ -n "$nwo" ]] || {
        return 0
    }

    local rev_args=("--first-parent" "--format=%s")
    if [[ -n "$range" ]]; then
        rev_args=("$range" "${rev_args[@]}")
    else
        rev_args=("--max-count=12" "${rev_args[@]}")
    fi

    local subjects
    subjects="$(git -C "$d" log "${rev_args[@]}" 2>/dev/null || true)"
    if [[ -z "$subjects" ]]; then
        info "  no recent pull request references"
        return 0
    fi

    local -a numbers=()
    local -A seen=()
    local subject token number
    while IFS= read -r subject; do
        while IFS= read -r token; do
            [[ -z "$token" ]] && continue
            number="${token#\#}"
            [[ -n "${seen[$number]:-}" ]] && continue
            seen[$number]=1
            numbers+=("$number")
        done < <(grep -Eo '#[0-9]+' <<< "$subject" || true)
    done <<< "$subjects"

    if [[ ${#numbers[@]} -eq 0 ]]; then
        info "  no recent pull request references"
        return 0
    fi

    info "  recently merged pull requests:"
    local pr_line
    for number in "${numbers[@]}"; do
        pr_line="$(gh pr view "$number" --repo "$nwo" \
            --json number,title,headRefName,author,mergedAt \
            --jq '(.author.login? // "unknown") as $author | (.mergedAt != null) as $is_merged | [
                if $is_merged then "merged" else "not-merged" end,
                (if $is_merged then (.mergedAt | fromdateiso8601 | tostring) else "" end),
                "#\(.number) \(.title) [" + .headRefName + "] @" + $author
            ] | @tsv' 2>/dev/null || true)"
        if [[ -n "$pr_line" ]]; then
            local pr_status pr_merged_epoch pr_subject
            IFS=$'\t' read -r pr_status pr_merged_epoch pr_subject <<< "$pr_line"
            if [[ "$pr_status" == "merged" ]]; then
                info "    ✅ merged PR ($(age_text_from_epoch "$pr_merged_epoch" "today" "ago")): $pr_subject"
            else
                info "    🔎 PR reference (not yet merged): $pr_subject"
            fi
        else
            info "    🔎 PR reference (details unavailable): #$number"
        fi
    done
}

print_pr_report() {
    local d="$1" range="$2"
    local nwo
    nwo="$(github_nwo_for_dir "$d" || true)"

    print_open_prs "$nwo"
    print_recent_merged_prs "$d" "$nwo" "$range"
}

merged_pr_for_branch() {
    local nwo="$1" branch="$2"

    $gh_available || return 1
    [[ -n "$nwo" ]] || return 1

    local pr
    pr="$(gh pr list --repo "$nwo" --state merged --head "$branch" --base main --limit 1 \
        --json number,title,headRefName,author,mergedAt \
        --jq '.[0] | select(. != null and .mergedAt != null) | [
            (.mergedAt | fromdateiso8601 | tostring),
            "#\(.number) \(.title) [" + .headRefName + "] @" + (.author.login? // "unknown")
        ] | @tsv' \
        2>/dev/null || true)"
    [[ -n "$pr" ]] || return 1

    local pr_merged_epoch pr_subject
    IFS=$'\t' read -r pr_merged_epoch pr_subject <<< "$pr"
    printf '✅ merged PR (%s): %s\n' \
        "$(age_text_from_epoch "$pr_merged_epoch" "today" "ago")" \
        "$pr_subject"
    return 0
}

# ── Welcome banner ─────────────────────────────────────────────────────────────
echo -e "${BOLD}pull-rebase — syncing git repositories in ${ROOT_DIR}${RESET}"
echo -e "${BOLD}─────────────────────────────────────────────────────────────────${RESET}"
echo -e "Found ${#all_repos[@]} repositor$([ ${#all_repos[@]} -eq 1 ] && echo y || echo ies):"

# Repositories are grouped by their parent directory so that nested layouts
# stay readable. The full relative path is still shown for every repository.
last_parent=""
for rel in "${all_repos[@]}"; do
    dir="$ROOT_DIR/$rel"
    parent="${rel%/*}"
    [[ "$parent" == "$rel" ]] && parent=""
    if [[ "$parent" != "$last_parent" ]]; then
        [[ -n "$parent" ]] && printf "  ${DIM}%s/${RESET}\n" "$parent"
        last_parent="$parent"
    fi
    fetch_gh_meta "$dir"
    badge_part=""
    [[ -n "$gh_badge" ]] && badge_part="  ${gh_badge}"
    desc_part=""
    [[ -n "$gh_desc"  ]] && desc_part="  ${gh_desc}"
    printf "  ${CYAN}%-*s${RESET}${badge_part}${desc_part}\n" "$max_len" "$rel"
done
echo

# ── summary_icon[repo] and summary_msg[repo] collected during the loop ─────────
declare -a summary_repos=()
declare -A summary_icon=()
declare -A summary_msg=()

record() {
    local icon="$1" msg="$2"
    summary_repos+=("$repo")
    summary_icon[$repo]="$icon"
    summary_msg[$repo]="$msg"
}

for rel in "${all_repos[@]}"; do
    dir="$ROOT_DIR/$rel"
    repo="$rel"
    switched_to_main=false
    started_on_main=false
    pr_history_base=""
    fetched_main_ref=""
    main_before_pull=""

    # In an <owner>/<repo> layout the directory path should match the GitHub
    # repository it points at. Note it when it does not (renamed or moved repo).
    # Only a single level of nesting maps onto the owner/repo convention.
    if [[ "$rel" == */* && "$rel" != */*/* ]]; then
        expected_nwo="$rel"
        actual_nwo="$(github_nwo_for_dir "$dir" || true)"
        if [[ -n "$actual_nwo" && "$actual_nwo" != "$expected_nwo" ]]; then
            muted "  path suggests ${expected_nwo}, origin is ${actual_nwo}"
        fi
    fi

    branch="$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || true)"
    if [[ -z "$branch" ]]; then
        warn "detached HEAD — skipping"
        record "?" "detached HEAD — skipped"
        continue
    fi

    if [[ "$branch" != "main" ]]; then
        info "on branch '$branch'"

        unstaged="$(git -C "$dir" diff --name-only 2>/dev/null)"
        staged="$(git -C "$dir" diff --cached --name-only 2>/dev/null)"
        untracked="$(git -C "$dir" ls-files --others --exclude-standard 2>/dev/null)"

        has_local_work=false
        work_detail=""

        if [[ -n "$unstaged" ]]; then
            warn "  unstaged changes:"
            while IFS= read -r f; do warn "    M  $f"; done <<< "$unstaged"
            has_local_work=true
            work_detail+="unstaged "
        fi

        if [[ -n "$staged" ]]; then
            warn "  staged (uncommitted) changes:"
            while IFS= read -r f; do warn "    A  $f"; done <<< "$staged"
            has_local_work=true
            work_detail+="staged "
        fi

        if [[ -n "$untracked" ]]; then
            warn "  untracked files:"
            while IFS= read -r f; do warn "    ?  $f"; done <<< "$untracked"
            has_local_work=true
            work_detail+="untracked "
        fi

        # Check for commits not yet pushed to remote
        unpushed=""
        branch_merged_to_main=false
        merged_pr=""
        if git -C "$dir" fetch --quiet origin main 2>/dev/null; then
            fetched_main_ref="FETCH_HEAD"
            if git -C "$dir" merge-base --is-ancestor HEAD FETCH_HEAD 2>/dev/null; then
                branch_merged_to_main=true
            fi
        fi

        remote_branch="$(git -C "$dir" for-each-ref --format='%(upstream:short)' \
            "refs/heads/$branch" 2>/dev/null)"
        if $branch_merged_to_main; then
            info "  branch is already merged into origin/main"
        elif [[ -n "$remote_branch" ]] && git -C "$dir" rev-parse --verify --quiet "$remote_branch" >/dev/null; then
            unpushed="$(git -C "$dir" log --oneline "${remote_branch}..HEAD" 2>/dev/null || true)"
        else
            unpushed="$(git -C "$dir" log --oneline HEAD 2>/dev/null | head -1 || true)"
        fi

        if [[ -n "$unpushed" ]]; then
            if merged_pr="$(merged_pr_for_branch "$(github_nwo_for_dir "$dir" || true)" "$branch")"; then
                info "  branch has a merged pull request:"
                info "    $merged_pr"
                branch_merged_to_main=true
                unpushed=""
            else
                warn "  unpushed commits:"
                while IFS= read -r line; do warn "    $line"; done <<< "$unpushed"
                has_local_work=true
                work_detail+="unpushed "
            fi
        fi

        if $has_local_work; then
            warn "  -> branch has unfinished work; leaving as-is"
            detail="$(echo "$work_detail" | xargs | tr ' ' '/')"
            record "!" "branch '$branch' — unfinished work (${detail})"
            continue
        fi

        info "  branch is safe to leave — switching to main"
        if [[ -n "$fetched_main_ref" ]]; then
            pr_history_base="$(git -C "$dir" merge-base "$branch" "$fetched_main_ref" 2>/dev/null || true)"
        else
            pr_history_base="$(git -C "$dir" merge-base "$branch" main 2>/dev/null || true)"
        fi
        git -C "$dir" checkout main
        switched_to_main=true
    else
        started_on_main=true
    fi

    $started_on_main && print_open_prs "$(github_nwo_for_dir "$dir" || true)"

    # Now on main; attempt fast-forward only pull
    remote_main="$(git -C "$dir" for-each-ref --format='%(upstream:short)' \
        refs/heads/main 2>/dev/null)"
    if [[ -z "$remote_main" ]]; then
        warn "main has no upstream configured — skipping pull"
        record "-" "main — no upstream configured"
        continue
    fi

    if [[ -z "$fetched_main_ref" ]]; then
        git -C "$dir" fetch --quiet origin main 2>/dev/null || {
            warn "fetch failed — skipping pull"
            record "!" "main — fetch failed"
            continue
        }
    fi

    main_before_pull="$(git -C "$dir" rev-parse --verify HEAD 2>/dev/null || true)"
    behind="$(git -C "$dir" rev-list --count HEAD..FETCH_HEAD 2>/dev/null)"
    ahead="$(git -C "$dir" rev-list --count FETCH_HEAD..HEAD 2>/dev/null)"

    pr_range=""
    if [[ -n "$pr_history_base" ]]; then
        pr_range="${pr_history_base}..HEAD"
    fi

    if [[ "$behind" -eq 0 ]]; then
        ok "main is up to date"
        if $switched_to_main; then
            print_pr_report "$dir" "$pr_range"
        fi
        record "✓" "main — already up to date"
    elif [[ "$ahead" -gt 0 ]]; then
        warn "main has diverged (${ahead} ahead, ${behind} behind) — fast-forward not possible; skipping pull"
        if $switched_to_main; then
            print_pr_report "$dir" "$pr_range"
        fi
        record "!" "main — diverged (${ahead} ahead / ${behind} behind), pull skipped"
    else
        git -C "$dir" merge --ff-only FETCH_HEAD
        ok "main fast-forwarded ${behind} commit(s)"
        if [[ -n "$main_before_pull" ]]; then
            pr_range="${main_before_pull}..HEAD"
        fi
        if $switched_to_main; then
            print_pr_report "$dir" "$pr_range"
        else
            print_recent_merged_prs "$dir" "$(github_nwo_for_dir "$dir" || true)" "$pr_range"
        fi
        record "↑" "main — fast-forwarded ${behind} commit(s)"
    fi
done

# ── Summary ────────────────────────────────────────────────────────────────────
(( ${#summary_repos[@]} == 0 )) && { echo; exit 0; }

echo
echo -e "${BOLD}Summary${RESET}"
echo -e "${BOLD}───────────────────────────────────────────────────────────────${RESET}"

mapfile -t sorted_repos < <(printf '%s\n' "${summary_repos[@]}" | sort)

for r in "${sorted_repos[@]}"; do
    icon="${summary_icon[$r]}"
    msg="${summary_msg[$r]}"
    case "$icon" in
        "✓"|"↑") color="$GREEN" ;;
        "!")      color="$YELLOW" ;;
        *)        color="$RESET" ;;
    esac
    printf "${color}%-*s  %s %s${RESET}\n" "$max_len" "$r" "$icon" "$msg"
done
echo
