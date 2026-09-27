#!/usr/bin/env bash
# The PostToolUse await-bot-reviews hook.
#
# GitHub is replaced by a fake `gh` that serves JSON fixtures shaped like real
# API responses (fields checked against a live CodeRabbit-reviewed PR). A
# fixture named <endpoint>.<n>.json answers the n-th call, falling back to
# <endpoint>.json, so a test can walk statuses from pending to settled.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

LOG="$TMPROOT/log"
DATA="$TMPROOT/data"
FAKE_GH="$TMPROOT/bin/gh"
mkdir -p "$TMPROOT/bin"
cat > "$FAKE_GH" <<'EOF'
#!/usr/bin/env bash
d="$FAKE_GH_DIR"
echo "$*" >> "$d/calls"
if [ "$1 $2" = "pr view" ]; then
  name=pr
elif [ "$1" = api ]; then
  path="" jqexpr=""
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --jq) jqexpr="$2"; shift ;;
      -*) ;;
      *) path="$1" ;;
    esac
    shift
  done
  case "$path" in
    */status|*/status\?*) name=status ;;
    */check-runs*) name=check-runs ;;
    */pulls/*/reviews*) name=reviews ;;
    */pulls/*/comments*) name=pr-comments ;;
    */issues/*/comments*) name=issue-comments ;;
    *) exit 1 ;;
  esac
else
  exit 1
fi
n=$(( $(cat "$d/count-$name" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$d/count-$name"
f="$d/$name.$n.json"; [ -f "$f" ] || f="$d/$name.json"
[ -f "$f" ] || { echo "no pull requests found" >&2; exit 1; }
if [ -n "${jqexpr:-}" ]; then jq -c "$jqexpr" "$f"; else cat "$f"; fi
EOF
chmod +x "$FAKE_GH"

SID="00000000-0000-4000-8000-0000000000aa"
SHA="1111111111111111111111111111111111111111"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OLD="2020-01-01T00:00:00Z"
case_n=0

# new_gh: a fresh fixture dir for one case - an open PR on a settled head with
# no feedback. Cases overwrite the endpoints they care about.
new_gh() {
  case_n=$((case_n + 1))
  GH_DIR="$TMPROOT/gh-$case_n"
  mkdir -p "$GH_DIR"
  rm -f "$DATA"/sessions/await-* "$TMPROOT/.claude-watchdog-skip"
  jq -n --arg sha "$SHA" '{number:7, headRefOid:$sha, url:"https://github.com/o/r/pull/7", state:"OPEN", isDraft:false}' > "$GH_DIR/pr.json"
  echo '{"state":"success","statuses":[]}' > "$GH_DIR/status.json"
  echo '{"total_count":0,"check_runs":[]}' > "$GH_DIR/check-runs.json"
  echo '[]' > "$GH_DIR/reviews.json"
  echo '[]' > "$GH_DIR/pr-comments.json"
  echo '[]' > "$GH_DIR/issue-comments.json"
}

pending_status() {
  jq -n '{state:"pending", statuses:[{context:"CodeRabbit", state:"pending", description:"Review in progress"}]}'
}
settled_status() {
  jq -n '{state:"success", statuses:[{context:"CodeRabbit", state:"success", description:"Review completed"}]}'
}
inline_comment() { # <login> <type> <created_at> <path> <line> <body>
  jq -n --arg l "$1" --arg t "$2" --arg c "$3" --arg p "$4" --argjson n "$5" --arg b "$6" \
    '{user:{login:$l, type:$t}, created_at:$c, path:$p, line:$n, body:$b,
      html_url:("https://github.com/o/r/pull/7#discussion_" + $p)}'
}

payload() { # <command> [duration_ms]
  event_fixture post-tool-use-bash \
    "$(jq -n --arg sid "$SID" --arg cwd "$TMPROOT" --arg c "$1" --argjson d "${2:-0}" \
        '{session_id:$sid, cwd:$cwd, tool_input:{command:$c}, duration_ms:$d}')"
}

# await <command> [ENV=VAL ...] - enabled, hermetic, and with no waiting.
await() {
  local cmd="$1"; shift
  run_await "$(payload "$cmd")" \
    CLAUDE_WATCHDOG_AWAIT_REVIEWS=1 CLAUDE_WATCHDOG_GH="$FAKE_GH" FAKE_GH_DIR="$GH_DIR" \
    CLAUDE_WATCHDOG_TMP="$DATA" CLAUDE_WATCHDOG_LOG="$LOG" \
    CLAUDE_WATCHDOG_AWAIT_POLL_SECONDS=0 CLAUDE_WATCHDOG_AWAIT_GRACE_SECONDS=0 \
    CLAUDE_WATCHDOG_AWAIT_QUIET_SECONDS=0 "$@"
}

watcher_file() { echo "$DATA/sessions/await-$SID-o_r-7"; }
silent() { # <name>
  [ "$AWAIT_RC" -eq 0 ] || fail "$1" "expected exit 0, got $AWAIT_RC (stderr: $AWAIT_ERR)"
  [ -z "$AWAIT_ERR" ] || fail "$1" "expected no wake text, got '$AWAIT_ERR'"
}
calls() { cat "$GH_DIR/calls" 2>/dev/null || true; }

# --- Test 1: off by default -> never touches gh ---
new_gh
run_await "$(payload 'git push')" CLAUDE_WATCHDOG_GH="$FAKE_GH" FAKE_GH_DIR="$GH_DIR" CLAUDE_WATCHDOG_LOG="$LOG"
silent "default-off"
[ -z "$(calls)" ] || fail "default-off" "gh was called: $(calls)"
pass "default-off"

# --- Test 2: a command that neither pushes nor opens a PR -> no gh ---
new_gh
for cmd in 'git status' 'git log --oneline' 'gh pr view 7' 'echo pushed'; do
  await "$cmd"
  silent "non-push-$cmd"
done
[ -z "$(calls)" ] || fail "non-push" "gh was called: $(calls)"
pass "non-push-commands-ignored"

# --- Test 3: push with no PR for the branch -> silent ---
new_gh
rm "$GH_DIR/pr.json"
await 'git push -u origin HEAD'
silent "no-pr"
pass "no-pr-silent"

# --- Test 4: merged PR -> silent, no polling ---
new_gh
jq '.state = "MERGED"' "$GH_DIR/pr.json" > "$GH_DIR/pr.tmp" && mv "$GH_DIR/pr.tmp" "$GH_DIR/pr.json"
await 'git push'
silent "merged-pr"
calls | grep -q '^api' && fail "merged-pr" "polled a merged PR"
pass "merged-pr-silent"

# --- Test 5: pending -> settled with bot feedback -> wake with only new bot items ---
new_gh
pending_status > "$GH_DIR/status.1.json"
settled_status > "$GH_DIR/status.json"
jq -s . \
  <(inline_comment 'coderabbitai[bot]' Bot "$NOW" internal/config/config.go 1539 'Guard against a zero max_input_tokens.') \
  <(inline_comment 'coderabbitai[bot]' Bot "$OLD" old/file.go 1 'Stale bot comment from an earlier round.') \
  <(inline_comment 'someone' User "$NOW" human/file.go 2 'A human comment.') \
  > "$GH_DIR/pr-comments.json"
jq -n --arg c "$NOW" '[{user:{login:"coderabbitai[bot]", type:"Bot"}, state:"COMMENTED", submitted_at:$c,
  body:"<!-- hidden -->\n**Actionable comments posted: 1**\n\n<details><summary>Nitpick comments (1)</summary>\nUse errors.Is.\n</details>",
  html_url:"https://github.com/o/r/pull/7#pullrequestreview-1"}]' > "$GH_DIR/reviews.json"
await 'git add -A && git commit -qm fix && git push -q origin HEAD'
[ "$AWAIT_RC" -eq 2 ] || fail "wake" "expected exit 2, got $AWAIT_RC (stderr: $AWAIT_ERR)"
case "$AWAIT_ERR" in *"PR #7"*) ;; *) fail "wake-pr" "no PR number in '$AWAIT_ERR'" ;; esac
case "$AWAIT_ERR" in *"internal/config/config.go:1539"*"Guard against a zero"*) ;; *) fail "wake-inline" "inline comment missing: '$AWAIT_ERR'" ;; esac
case "$AWAIT_ERR" in *"Actionable comments posted: 1"*"Use errors.Is."*) ;; *) fail "wake-review" "review body missing: '$AWAIT_ERR'" ;; esac
case "$AWAIT_ERR" in *"Stale bot comment"*|*"A human comment"*|*"hidden"*) fail "wake-filter" "old, human or HTML-comment text leaked: '$AWAIT_ERR'" ;; esac
inline_at=$(printf '%s\n' "$AWAIT_ERR" | grep -n 'config.go:1539' | cut -d: -f1)
review_at=$(printf '%s\n' "$AWAIT_ERR" | grep -n 'review (' | cut -d: -f1)
[ "$inline_at" -lt "$review_at" ] || fail "wake-order" "inline comments must precede review bodies"
[ "$(grep -c '/status' "$GH_DIR/calls")" -eq 2 ] || fail "wake-polled" "expected 2 status polls: $(calls)"
[ "$(jq -r .wakes "$(watcher_file)")" = 1 ] || fail "wake-count" "watcher file: $(cat "$(watcher_file)")"
pass "settle-wakes-with-new-bot-feedback"

# --- Test 6: settled with no feedback and green checks -> silent ---
new_gh
settled_status > "$GH_DIR/status.json"
await 'gh pr create --fill'
silent "settled-quiet"
pass "settled-quiet-silent"

# --- Test 7: a failed check wakes even without bot comments ---
new_gh
jq -n '{total_count:2, check_runs:[
  {name:"Lint", status:"completed", conclusion:"failure", html_url:"https://github.com/o/r/runs/1"},
  {name:"Test", status:"completed", conclusion:"success", html_url:"https://github.com/o/r/runs/2"}]}' \
  > "$GH_DIR/check-runs.json"
await 'git push'
[ "$AWAIT_RC" -eq 2 ] || fail "failed-check" "expected exit 2, got $AWAIT_RC"
case "$AWAIT_ERR" in *"Lint"*"failure"*) ;; *) fail "failed-check" "got '$AWAIT_ERR'" ;; esac
case "$AWAIT_ERR" in *"Test"*) fail "failed-check" "passing check listed: '$AWAIT_ERR'" ;; esac
pass "failed-check-wakes"

# --- Test 8: round cap stops a review/fix loop ---
new_gh
jq -s . <(inline_comment 'coderabbitai[bot]' Bot "$NOW" a.go 1 'nit') > "$GH_DIR/pr-comments.json"
mkdir -p "$DATA/sessions"
jq -n '{sha:"0000000", pid:0, wakes:2}' > "$(watcher_file)"
await 'git push' CLAUDE_WATCHDOG_AWAIT_MAX_ROUNDS=2
silent "round-cap"
calls | grep -q '^api' && fail "round-cap" "polled past the cap"
grep -q 'round cap' "$LOG" || fail "round-cap" "no log line"
pass "round-cap-stops-loop"
rm -f "$(watcher_file)"

# --- Test 9: a live watcher on the same head -> second trigger is a no-op ---
new_gh
mkdir -p "$DATA/sessions"
jq -n --arg sha "$SHA" --argjson pid $$ '{sha:$sha, pid:$pid, wakes:0}' > "$(watcher_file)"
await 'gh pr create --fill'
silent "dedup"
calls | grep -q '^api' && fail "dedup" "second watcher polled"
pass "live-watcher-dedups"
rm -f "$(watcher_file)"

# --- Test 10: a newer push supersedes a running watcher ---
new_gh
pending_status > "$GH_DIR/status.json"
( await 'git push' CLAUDE_WATCHDOG_AWAIT_POLL_SECONDS=1 CLAUDE_WATCHDOG_AWAIT_TIMEOUT_SECONDS=30
  echo "$AWAIT_RC" > "$TMPROOT/superseded.rc" ) &
bg=$!
for _ in $(seq 50); do [ -s "$(watcher_file)" ] && break; sleep 0.1; done
jq '.sha = "2222222222222222222222222222222222222222"' "$(watcher_file)" > "$TMPROOT/w" && mv "$TMPROOT/w" "$(watcher_file)"
for _ in $(seq 50); do [ -f "$TMPROOT/superseded.rc" ] && break; sleep 0.1; done
[ -f "$TMPROOT/superseded.rc" ] || { kill "$bg" 2>/dev/null; fail "superseded" "watcher kept running after a newer push"; }
wait "$bg"
[ "$(cat "$TMPROOT/superseded.rc")" = 0 ] || fail "superseded" "rc=$(cat "$TMPROOT/superseded.rc")"
grep -q 'superseded' "$LOG" || fail "superseded" "no log line"
pass "newer-push-supersedes"
rm -f "$(watcher_file)"

# --- Test 11: never settles -> gives up silently at the timeout ---
new_gh
pending_status > "$GH_DIR/status.json"
await 'git push' CLAUDE_WATCHDOG_AWAIT_POLL_SECONDS=1 CLAUDE_WATCHDOG_AWAIT_TIMEOUT_SECONDS=1
silent "timeout"
grep -q 'TIMEOUT' "$LOG" || fail "timeout" "no log line"
pass "timeout-silent"

# --- Test 12: the plugin-config variable enables it too ---
new_gh
jq -s . <(inline_comment 'coderabbitai[bot]' Bot "$NOW" a.go 1 'nit') > "$GH_DIR/pr-comments.json"
run_await "$(payload 'git push')" CLAUDE_PLUGIN_OPTION_AWAIT_BOT_REVIEWS=true \
  CLAUDE_WATCHDOG_GH="$FAKE_GH" FAKE_GH_DIR="$GH_DIR" CLAUDE_WATCHDOG_TMP="$DATA" CLAUDE_WATCHDOG_LOG="$LOG" \
  CLAUDE_WATCHDOG_AWAIT_POLL_SECONDS=0 CLAUDE_WATCHDOG_AWAIT_GRACE_SECONDS=0
[ "$AWAIT_RC" -eq 2 ] || fail "plugin-option" "expected exit 2, got $AWAIT_RC"
pass "plugin-option-enables"
rm -f "$(watcher_file)"

# --- Test 13: fail open on garbage stdin and on a missing gh ---
new_gh
run_await "not json" CLAUDE_WATCHDOG_AWAIT_REVIEWS=1 CLAUDE_WATCHDOG_LOG="$LOG"
silent "garbage-stdin"
await 'git push' CLAUDE_WATCHDOG_GH="$TMPROOT/no-such-gh"
silent "missing-gh"
pass "fail-open"

# --- Test 14: .claude-watchdog-skip in the session cwd disables the watcher ---
new_gh
touch "$TMPROOT/.claude-watchdog-skip"
await 'git push'
silent "skip-file"
[ -z "$(calls)" ] || fail "skip-file" "gh was called: $(calls)"
pass "skip-file-honoured"

# --- Test 15: re-pushing a head whose round already concluded is a no-op ---
new_gh
jq -s . <(inline_comment 'coderabbitai[bot]' Bot "$NOW" a.go 1 'nit') > "$GH_DIR/pr-comments.json"
await 'git push'
[ "$AWAIT_RC" -eq 2 ] || fail "handled-head" "first round should wake, got $AWAIT_RC"
: > "$GH_DIR/calls"
await 'git push'
silent "handled-head"
calls | grep -q '^api' && fail "handled-head" "re-polled a handled head"
[ "$(jq -r .wakes "$(watcher_file)")" = 1 ] || fail "handled-head" "wake count moved: $(cat "$(watcher_file)")"
pass "handled-head-not-rewoken"

# --- Test 16: state is per repo - another repo's PR #7 at the cap does not block this one ---
new_gh
mkdir -p "$DATA/sessions"
jq -n '{sha:"0000000", pid:0, wakes:99}' > "$DATA/sessions/await-$SID-other_repo-7"
jq -s . <(inline_comment 'coderabbitai[bot]' Bot "$NOW" a.go 1 'nit') > "$GH_DIR/pr-comments.json"
await 'git push'
[ "$AWAIT_RC" -eq 2 ] || fail "per-repo-state" "expected exit 2, got $AWAIT_RC"
pass "per-repo-state"

# --- Test 17: the cutoff covers the Bash call's own runtime (duration_ms) ---
new_gh
FIVE_MIN_AGO=$(date -u -r $(( $(date +%s) - 300 )) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d @$(( $(date +%s) - 300 )) +%Y-%m-%dT%H:%M:%SZ)
jq -s . <(inline_comment 'coderabbitai[bot]' Bot "$FIVE_MIN_AGO" slow.go 3 'Posted while the command ran.') > "$GH_DIR/pr-comments.json"
run_await "$(payload 'git push && sleep 600' 600000)" \
  CLAUDE_WATCHDOG_AWAIT_REVIEWS=1 CLAUDE_WATCHDOG_GH="$FAKE_GH" FAKE_GH_DIR="$GH_DIR" \
  CLAUDE_WATCHDOG_TMP="$DATA" CLAUDE_WATCHDOG_LOG="$LOG" \
  CLAUDE_WATCHDOG_AWAIT_POLL_SECONDS=0 CLAUDE_WATCHDOG_AWAIT_GRACE_SECONDS=0
[ "$AWAIT_RC" -eq 2 ] || fail "duration-cutoff" "expected exit 2, got $AWAIT_RC"
case "$AWAIT_ERR" in *"slow.go:3"*) ;; *) fail "duration-cutoff" "comment missing: '$AWAIT_ERR'" ;; esac
pass "cutoff-covers-command-runtime"

# --- Test 18: every GitHub list call follows pagination ---
new_gh
jq -s . <(inline_comment 'coderabbitai[bot]' Bot "$NOW" a.go 1 'nit') > "$GH_DIR/pr-comments.json"
await 'git push'
[ "$AWAIT_RC" -eq 2 ] || fail "paginate" "expected exit 2, got $AWAIT_RC"
unpaged=$(grep '^api' "$GH_DIR/calls" | grep -v -- '--paginate' || true)
[ -z "$unpaged" ] || fail "paginate" "unpaginated calls: $unpaged"
pass "api-calls-paginate"

# --- Test 19: a stale lock from a crashed hook is taken over, a live one is not ---
new_gh
mkdir -p "$DATA/sessions"
jq -s . <(inline_comment 'coderabbitai[bot]' Bot "$NOW" a.go 1 'nit') > "$GH_DIR/pr-comments.json"
touch "$(watcher_file).lock"; set_mtime "$(watcher_file).lock" 60
await 'git push'
[ "$AWAIT_RC" -eq 2 ] || fail "stale-lock" "expected exit 2, got $AWAIT_RC"
[ ! -e "$(watcher_file).lock" ] || fail "stale-lock" "lock left behind"
new_gh
mkdir -p "$DATA/sessions"
touch "$(watcher_file).lock"
await 'git push'
silent "live-lock"
calls | grep -q '^api' && fail "live-lock" "polled without the lock"
pass "lock-stale-takeover-and-live-wait"

# --- Test 20: a status that just completed is not settled until it has been quiet ---
# CodeRabbit flips its status to "Review completed" ~40s before the review lands.
new_gh
jq -n --arg c "$NOW" '{state:"success", statuses:[{context:"CodeRabbit", state:"success", updated_at:$c}]}' > "$GH_DIR/status.json"
jq -s . <(inline_comment 'coderabbitai[bot]' Bot "$NOW" a.go 1 'nit') > "$GH_DIR/pr-comments.json"
: > "$LOG"
await 'git push' CLAUDE_WATCHDOG_AWAIT_QUIET_SECONDS=300 CLAUDE_WATCHDOG_AWAIT_POLL_SECONDS=1 CLAUDE_WATCHDOG_AWAIT_TIMEOUT_SECONDS=1
silent "quiet-period"
grep -q 'TIMEOUT' "$LOG" || fail "quiet-period" "settled inside the quiet period"
new_gh
jq -n --arg c "$OLD" '{state:"success", statuses:[{context:"CodeRabbit", state:"success", updated_at:$c}]}' > "$GH_DIR/status.json"
jq -s . <(inline_comment 'coderabbitai[bot]' Bot "$NOW" a.go 1 'nit') > "$GH_DIR/pr-comments.json"
await 'git push' CLAUDE_WATCHDOG_AWAIT_QUIET_SECONDS=300
[ "$AWAIT_RC" -eq 2 ] || fail "quiet-period" "old completion should settle, got $AWAIT_RC"
pass "quiet-period-after-last-completion"

echo "All await-reviews tests passed."
