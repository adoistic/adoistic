#!/usr/bin/env bash
#
# update-commits.sh
# Counts Adnan's total commits since 2026-02-01 across all repos he can see
# (public + private, via STATS_PAT) and writes the result between sentinel
# markers in README.md.
#
# Designed to be durable: loops yearly windows because the GitHub GraphQL
# `contributionsCollection` field has a hard 1-year ceiling on (from, to).
#
# Hard-fails (exits non-zero, leaves README untouched) on:
#   * GraphQL returning 0 or empty
#   * Markers missing or duplicated in README
#   * New count strictly less than current count (per eng-review E2)
#
# Idempotent: if the new count equals the current count, exits 0 with no
# write. The workflow's commit step then skips the commit silently.

set -euo pipefail

# Ensure thousands-separator formatting works on Ubuntu runners.
export LC_ALL=en_US.UTF-8 || true

readonly README_PATH="${README_PATH:-README.md}"
readonly LOGIN="${GITHUB_LOGIN:-adoistic}"
readonly START_DATE="${START_DATE:-2026-02-01T00:00:00Z}"
readonly MARKER_START='<!--commits-start-->'
readonly MARKER_END='<!--commits-end-->'

if [ -z "${GH_TOKEN:-}" ]; then
  echo "ERROR: GH_TOKEN not set. Workflow must export STATS_PAT as GH_TOKEN." >&2
  exit 1
fi

# Marker integrity: exactly one of each, in order.
start_count=$(grep -c "$MARKER_START" "$README_PATH" || true)
end_count=$(grep -c "$MARKER_END" "$README_PATH" || true)
if [ "$start_count" != "1" ] || [ "$end_count" != "1" ]; then
  echo "ERROR: README markers wrong. start=$start_count end=$end_count (each must be 1)." >&2
  exit 1
fi

# Parse current count (between markers, comma-stripped, integer).
current_str=$(awk -v s="$MARKER_START" -v e="$MARKER_END" '
  { while (match($0, s)) {
      after = substr($0, RSTART + length(s));
      if (match(after, e)) { print substr(after, 1, RSTART-1); exit }
      $0 = after
  } }' "$README_PATH" | tr -d ',[:space:]')

if ! [[ "$current_str" =~ ^[0-9X]+$ ]]; then
  echo "ERROR: Current marker content not numeric (or X placeholder): '$current_str'" >&2
  exit 1
fi

# Treat the placeholder "X,XXX" / "XXXX" as 0 so the first run can write.
if [[ "$current_str" =~ ^X+$ ]]; then
  current=0
else
  current="$current_str"
fi

# GraphQL query, looped over yearly windows.
read -r -d '' QUERY <<'GQL' || true
query($login: String!, $from: DateTime!, $to: DateTime!) {
  user(login: $login) {
    contributionsCollection(from: $from, to: $to) {
      totalCommitContributions
    }
  }
}
GQL

iso_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cursor="$START_DATE"
total=0

# Helper: add 1 year (365 days) to an ISO date, capped at $iso_now.
add_year() {
  local input="$1"
  local cap="$2"
  python3 - "$input" "$cap" <<'PY'
import sys
from datetime import datetime, timedelta, timezone
inp = sys.argv[1].replace("Z", "+00:00")
cap = sys.argv[2].replace("Z", "+00:00")
c = datetime.fromisoformat(inp)
e = datetime.fromisoformat(cap)
w = min(c + timedelta(days=365), e)
print(w.strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}

while [ "$cursor" != "$iso_now" ]; do
  window_end=$(add_year "$cursor" "$iso_now")

  # Retry up to 3x on transient failures (5xx, network blips).
  attempt=0
  count=""
  while [ "$attempt" -lt 3 ]; do
    if count=$(gh api graphql \
      -F login="$LOGIN" \
      -F from="$cursor" \
      -F to="$window_end" \
      -f query="$QUERY" \
      --jq '.data.user.contributionsCollection.totalCommitContributions' \
      2>/dev/null); then
      [ -n "$count" ] && break
    fi
    attempt=$((attempt + 1))
    sleep 5
  done

  if [ -z "$count" ]; then
    echo "ERROR: GraphQL query failed for window $cursor → $window_end after 3 attempts." >&2
    exit 1
  fi

  total=$((total + count))

  if [ "$cursor" = "$window_end" ]; then
    # Defensive: avoid infinite loop if dates fail to advance.
    break
  fi
  cursor="$window_end"
done

if [ "$total" -le 0 ]; then
  echo "ERROR: GraphQL returned total=$total (must be > 0). Refusing to overwrite README." >&2
  exit 1
fi

# Decrease guard (E2): never write a smaller number than what's currently shown.
if [ "$current" -gt 0 ] && [ "$total" -lt "$current" ]; then
  echo "ERROR: New count ($total) is less than current count ($current). Suspicious — investigate." >&2
  exit 1
fi

# Idempotency: skip the commit if equal.
if [ "$total" = "$current" ]; then
  echo "No change: count is still $total. Skipping commit."
  exit 0
fi

# Format with thousands separator.
formatted=$(printf "%'d" "$total" 2>/dev/null || awk -v n="$total" 'BEGIN { s=""; while (n >= 1000) { s = sprintf(",%03d%s", n%1000, s); n = int(n/1000) } printf "%d%s\n", n, s }')

# Replace the value between markers, in place.
# Use a tmpfile + mv for atomic replacement (no partial-write risk).
tmpfile=$(mktemp)
awk -v s="$MARKER_START" -v e="$MARKER_END" -v val="$formatted" '
{
  out = ""
  rest = $0
  while (1) {
    si = index(rest, s)
    if (si == 0) { out = out rest; break }
    out = out substr(rest, 1, si - 1) s
    after = substr(rest, si + length(s))
    ei = index(after, e)
    if (ei == 0) { out = out after; break }
    out = out val e
    rest = substr(after, ei + length(e))
  }
  print out
}' "$README_PATH" > "$tmpfile"

mv "$tmpfile" "$README_PATH"

echo "Updated commit count: $current → $formatted"
