#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mikhail Krivoshein
# See https://github.com/mkrivoshein/pull-rebase/blob/main/LICENSE for the full license text.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[${repo}]${RESET} $*"; }
ok()      { echo -e "${GREEN}[${repo}]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[${repo}]${RESET} $*"; }
error()   { echo -e "${RED}[${repo}]${RESET} $*"; }

# ── Discover repos (sorted) ────────────────────────────────────────────────────
declare -a all_dirs=()
for dir in "$SCRIPT_DIR"/*/; do
    [[ -d "$dir/.git" ]] && all_dirs+=("$dir")
done
mapfile -t all_dirs < <(printf '%s\n' "${all_dirs[@]}" | sort)

# Column width shared by both the welcome list and the summary table
max_len=4
for dir in "${all_dirs[@]}"; do
    r="$(basename "$dir")"
    (( ${#r} > max_len )) && max_len=${#r}
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
        --json number,title,headRefName,author,url,updatedAt,mergeable,mergeStateStatus \
        --jq '.[] | [
            if (.mergeable == "CONFLICTING" or .mergeStateStatus == "DIRTY") then "CONFLICT" else "OK" end,
            "#\(.number) \(.title) [" + .headRefName + "] @" + .author.login + " updated " + .updatedAt + " " + .url
        ] | @tsv' \
        2>/dev/null || true)"

    if [[ -z "$prs" ]]; then
        return 0
    fi

    info "  open pull requests:"
    local pr_status pr_line
    while IFS= read -r pr; do
        IFS=$'\t' read -r pr_status pr_line <<< "$pr"
        if [[ "$pr_status" == "CONFLICT" ]]; then
            warn "    ! merge conflict requires attention: $pr_line"
        else
            info "    $pr_line"
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
            --json number,title,mergedAt,url \
            --jq '"#\(.number) \(.title) (merged \(.mergedAt)) \(.url)"' 2>/dev/null || true)"
        if [[ -n "$pr_line" ]]; then
            info "    $pr_line"
        else
            info "    #$number"
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
        --json number,title,mergedAt,url \
        --jq '.[0] | select(. != null) | "#\(.number) \(.title) (merged \(.mergedAt)) \(.url)"' \
        2>/dev/null || true)"
    [[ -n "$pr" ]] || return 1

    printf '%s\n' "$pr"
    return 0
}

# ── Welcome banner ─────────────────────────────────────────────────────────────
echo -e "${BOLD}pull-rebase — syncing git repositories in ${SCRIPT_DIR}${RESET}"
echo -e "${BOLD}─────────────────────────────────────────────────────────────────${RESET}"
echo -e "Found ${#all_dirs[@]} repositor$([ ${#all_dirs[@]} -eq 1 ] && echo y || echo ies):"
for dir in "${all_dirs[@]}"; do
    fetch_gh_meta "$dir"
    name="$(basename "$dir")"
    badge_part=""
    [[ -n "$gh_badge" ]] && badge_part="  ${gh_badge}"
    desc_part=""
    [[ -n "$gh_desc"  ]] && desc_part="  ${gh_desc}"
    printf "  ${CYAN}%-*s${RESET}${badge_part}${desc_part}\n" "$max_len" "$name"
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

for dir in "${all_dirs[@]}"; do
    repo="$(basename "$dir")"
    switched_to_main=false
    started_on_main=false
    pr_history_base=""
    fetched_main_ref=""
    main_before_pull=""

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
