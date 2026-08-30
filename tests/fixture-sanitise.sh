#!/usr/bin/env bash
# Strip machine-specific and personal data from a captured fixture, in place.
#
#   bash tests/fixture-sanitise.sh <path.json|path.jsonl>   (or: just fixture-sanitise <path>)
#
# Rewrites absolute home paths, the repo root, usernames, hostnames, session
# ids/UUIDs, API keys and tokens, and email addresses. Output must still be
# valid JSON (.json) or JSONL (.jsonl); if it is not, the original is restored
# and the run fails, so a bad rule can never land a broken fixture.
#
# Deliberately conservative: it over-redacts rather than risk leaving a secret.
# Always eyeball the diff before committing a captured fixture.
set -euo pipefail

path="${1:-}"
if [ -z "$path" ] || [ ! -f "$path" ]; then
  echo "usage: fixture-sanitise <path.json|path.jsonl>" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
real_home="${HOME:-}"
real_user="${USER:-${LOGNAME:-}}"
real_host="$(hostname 2>/dev/null || echo '')"
real_host_short="${real_host%%.*}"

backup="$(mktemp)"
cp "$path" "$backup"
trap 'rm -f "$backup"' EXIT

sanitised="$(mktemp)"

REPO="$REPO_ROOT" HOMEDIR="$real_home" UNAME="$real_user" \
HOST="$real_host" HOSTSHORT="$real_host_short" \
perl -pe '
  BEGIN {
    %uuid = (); $n = 0;
    $repo = $ENV{REPO}; $home = $ENV{HOMEDIR};
    $uname = $ENV{UNAME}; $host = $ENV{HOST}; $hostshort = $ENV{HOSTSHORT};
  }

  # --- 1. credentials, before anything else can chew up their shape ---------
  s{-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----}{REDACTED-PRIVATE-KEY}gs;
  s{\bsk-ant-[A-Za-z0-9_-]{8,}}{sk-ant-REDACTED}g;
  s{\bsk-[A-Za-z0-9]{16,}}{sk-REDACTED}g;
  s{\bgh[pousr]_[A-Za-z0-9]{16,}}{ghp_REDACTED}g;
  s{\bgithub_pat_[A-Za-z0-9_]{16,}}{github_pat_REDACTED}g;
  s{\bxox[abprs]-[A-Za-z0-9-]{10,}}{xoxb-REDACTED}g;
  s{\bAKIA[0-9A-Z]{16}}{AKIAREDACTEDREDACTED}g;
  s{\bAIza[0-9A-Za-z_-]{20,}}{AIzaREDACTED}g;
  s{\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{4,}}{REDACTED.JWT.TOKEN}g;
  # key=value / "key": "value" forms - keep the key, drop the value
  s{((?i:authorization|bearer|api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password|passwd)\\?"?\s*[:=]\s*\\?"?)[A-Za-z0-9_\-\.\+/]{8,}}{$1REDACTED}g;
  # `Authorization: Bearer <token>` and bare `Bearer <token>` - space-separated
  s{\b(?i:bearer)\s+[A-Za-z0-9_\-\.\+/=]{8,}}{Bearer REDACTED}g;

  # --- 2. email addresses ---------------------------------------------------
  s{[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}}{user\@example.com}g;

  # --- 3. session ids and any other UUID, pseudonymised consistently --------
  # A stable per-file mapping keeps cross-references (event session_id vs the
  # ids inside the transcript it points at) pointing at each other.
  s{\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b}
   { $uuid{lc $&} ||= sprintf("00000000-0000-4000-8000-%012d", ++$n) }ge;

  # --- 4. paths: repo root first (most specific), then home, then generic ---
  s{\Q$repo\E}{/repo}g                     if $repo;
  s{\Q$home\E}{/Users/example}g            if $home;
  s{/private/var/folders/[^/"\s,)\]]+/[^/"\s,)\]]+}{/tmp/example}g;
  s{/var/folders/[^/"\s,)\]]+/[^/"\s,)\]]+}{/tmp/example}g;
  s{/Users/(?!example\b)[^/"\s,)\]\\]+}{/Users/example}g;
  s{/home/(?!example\b)[^/"\s,)\]\\]+}{/home/example}g;
  s{\\\\Users\\\\(?!example\b)[^\\\\"\s]+}{\\\\Users\\\\example}g;

  # Anything still absolute and outside /repo, /tmp, or the Claude state dir is a
  # path to some other checkout on the machine. Keep the basename (a transcript
  # that names no files is useless as a fixture), drop the directory chain.
  s{/Users/example/(?!\.claude\b)(?:[^/"\s,)\]\\]+/)*([^/"\s,)\]\\]+)}{/repo/$1}g;
  s{/home/example/(?!\.claude\b)(?:[^/"\s,)\]\\]+/)*([^/"\s,)\]\\]+)}{/repo/$1}g;

  # --- 5. bare username and hostname ---------------------------------------
  s{\b\Q$uname\E\b}{example}g              if $uname && $uname ne "example";
  s{\b\Q$host\E\b}{example-host}g          if $host;
  s{\b\Q$hostshort\E\b}{example-host}g     if $hostshort && $hostshort ne $host;
  s{\b[A-Za-z0-9\-]+\.local\b}{example-host.local}g;
' "$path" > "$sanitised"

# --- validate, or put the original back -------------------------------------
valid=1
case "$path" in
  *.jsonl)
    n=0
    while IFS= read -r line; do
      n=$((n + 1))
      case "$line" in "{"*) ;; *) continue ;; esac
      printf '%s\n' "$line" | jq -e . > /dev/null 2>&1 || { echo "$path:$n: sanitiser produced invalid JSON" >&2; valid=0; break; }
    done < "$sanitised"
    ;;
  *)
    jq -e . "$sanitised" > /dev/null 2>&1 || { echo "$path: sanitiser produced invalid JSON" >&2; valid=0; }
    ;;
esac

if [ "$valid" -ne 1 ]; then
  cp "$backup" "$path"
  rm -f "$sanitised"
  echo "fixture-sanitise: FAILED, $path left unchanged" >&2
  exit 1
fi

cp "$sanitised" "$path"
rm -f "$sanitised"

if cmp -s "$backup" "$path"; then
  echo "fixture-sanitise: $path - nothing to redact"
else
  echo "fixture-sanitise: $path - redacted ($(diff <(tr ',' '\n' < "$backup") <(tr ',' '\n' < "$path") | grep -c '^<' || true) fragments changed)"
  echo "Review the diff before committing."
fi
