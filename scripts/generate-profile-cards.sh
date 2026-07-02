#!/usr/bin/env bash
# Renders profile/stats.svg and profile/top-langs.svg directly from the
# GitHub GraphQL API, with no third-party parsing/hosting dependency.
set -euo pipefail

GH_LOGIN="${GH_LOGIN:-Vedanshu7}"
OUT_DIR="${OUT_DIR:-profile}"
ACCENT="#58a6ff"     # legible on #ffffff and #0d1117 alike
TRACK="#8b949e"      # muted bar-track color, low opacity

: "${GH_TOKEN:?GH_TOKEN must be set (export it from secrets.PAT in the workflow step) with repo + read:user scopes}"

mkdir -p "$OUT_DIR"

fail() {
  echo "::error::$*" >&2
  exit 1
}

warn() {
  echo "::warning::$*" >&2
}

check_response() {
  local resp="$1" label="$2"
  if [ -z "$resp" ]; then
    fail "$label: empty response from GitHub API"
  fi
  if echo "$resp" | jq -e '.errors' >/dev/null 2>&1; then
    fail "$label: GraphQL error(s): $(echo "$resp" | jq -c '.errors')"
  fi
}

xml_escape() {
  sed -e 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

# ---- Date window: current GitHub calendar year to date ----
YEAR="$(date -u +%Y)"
FROM="${YEAR}-01-01T00:00:00Z"
TO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FROM_DATE="${YEAR}-01-01"
TO_DATE="$(date -u +%Y-%m-%d)"

# ---- GraphQL query (verified via live introspection against api.github.com) ----
read -r -d '' MAIN_QUERY <<'EOF' || true
query($login: String!, $cursor: String, $from: DateTime!, $to: DateTime!) {
  user(login: $login) {
    contributionsCollection(from: $from, to: $to) {
      totalCommitContributions
      restrictedContributionsCount
      totalPullRequestContributions
      totalIssueContributions
    }
    repositories(first: 100, after: $cursor, ownerAffiliations: [OWNER], isFork: false) {
      pageInfo { hasNextPage endCursor }
      nodes {
        name
        stargazerCount
        languages(first: 10, orderBy: { field: SIZE, direction: DESC }) {
          edges {
            size
            node { name color }
          }
        }
      }
    }
  }
}
EOF

echo "Fetching repositories + contributions for ${GH_LOGIN} (window ${FROM_DATE}..${TO_DATE})..." >&2

CURSOR=""
ALL_REPOS="[]"
CONTRIB_JSON=""
PAGE=0

while :; do
  PAGE=$((PAGE + 1))
  if [ -z "$CURSOR" ]; then
    RESP="$(gh api graphql -f query="$MAIN_QUERY" -f login="$GH_LOGIN" -f from="$FROM" -f to="$TO")" \
      || fail "GraphQL request (page $PAGE) failed — check PAT validity/rate limit/network"
  else
    RESP="$(gh api graphql -f query="$MAIN_QUERY" -f login="$GH_LOGIN" -f from="$FROM" -f to="$TO" -f cursor="$CURSOR")" \
      || fail "GraphQL request (page $PAGE) failed — check PAT validity/rate limit/network"
  fi
  check_response "$RESP" "repositories page $PAGE"

  if [ "$PAGE" -eq 1 ]; then
    CONTRIB_JSON="$(echo "$RESP" | jq -c '.data.user.contributionsCollection')"
    [ "$CONTRIB_JSON" != "null" ] || fail "contributionsCollection missing from response — did the login change or does the token lack read:user?"
  fi

  PAGE_NODES="$(echo "$RESP" | jq -c '.data.user.repositories.nodes')"
  ALL_REPOS="$(jq -c -n --argjson acc "$ALL_REPOS" --argjson page "$PAGE_NODES" '$acc + $page')"

  HAS_NEXT="$(echo "$RESP" | jq -r '.data.user.repositories.pageInfo.hasNextPage')"
  CURSOR="$(echo "$RESP" | jq -r '.data.user.repositories.pageInfo.endCursor')"
  [ "$HAS_NEXT" = "true" ] || break
done

REPO_COUNT="$(echo "$ALL_REPOS" | jq 'length')"
[ "$REPO_COUNT" -gt 0 ] || fail "Fetched 0 owned non-fork repositories for ${GH_LOGIN} — refusing to render an empty/broken card"
echo "Fetched ${REPO_COUNT} owned, non-fork repositories across ${PAGE} page(s)." >&2

# ---- Merged PR count (contributionsCollection only tracks *opened* PRs) ----
SEARCH_QUERY="author:${GH_LOGIN} is:pr is:merged merged:${FROM_DATE}..${TO_DATE}"
read -r -d '' MERGED_QUERY <<'EOF' || true
query($q: String!) {
  search(query: $q, type: ISSUE, first: 1) {
    issueCount
  }
}
EOF
MERGED_RESP="$(gh api graphql -f query="$MERGED_QUERY" -f q="$SEARCH_QUERY")" \
  || fail "GraphQL merged-PR search failed — check PAT validity/rate limit/network"
check_response "$MERGED_RESP" "merged PR search"
PRS_MERGED="$(echo "$MERGED_RESP" | jq -r '.data.search.issueCount')"

# ---- Aggregate stats ----
TOTAL_STARS="$(echo "$ALL_REPOS" | jq '[.[].stargazerCount] | add // 0')"
COMMITS_VISIBLE="$(echo "$CONTRIB_JSON" | jq -r '.totalCommitContributions')"
RESTRICTED="$(echo "$CONTRIB_JSON" | jq -r '.restrictedContributionsCount')"
TOTAL_COMMITS=$((COMMITS_VISIBLE + RESTRICTED))
PRS_OPENED="$(echo "$CONTRIB_JSON" | jq -r '.totalPullRequestContributions')"
ISSUES_OPENED="$(echo "$CONTRIB_JSON" | jq -r '.totalIssueContributions')"

if [ "$RESTRICTED" -gt $((COMMITS_VISIBLE * 3 + 10)) ]; then
  warn "restrictedContributionsCount ($RESTRICTED) is unusually high relative to visible commits ($COMMITS_VISIBLE) — likely SSO-protected org repos the PAT isn't authorized for."
fi

# ---- Top languages by aggregate byte size ----
LANGS_JSON="$(echo "$ALL_REPOS" | jq -c '
  [.[].languages.edges[] | {name: .node.name, color: .node.color, size}]
  | group_by(.name)
  | map({name: .[0].name, color: .[0].color, size: (map(.size) | add)})
  | sort_by(-.size)
')"
TOTAL_LANG_BYTES="$(echo "$LANGS_JSON" | jq '[.[].size] | add // 0')"
TOP_LANGS="$(echo "$LANGS_JSON" | jq -c --argjson total "$TOTAL_LANG_BYTES" '
  .[0:8] | map(. + {pct: (if $total > 0 then (.size / $total * 100) else 0 end)})
')"

echo "Totals: stars=$TOTAL_STARS commits=$TOTAL_COMMITS(visible=$COMMITS_VISIBLE+restricted=$RESTRICTED) prs_opened=$PRS_OPENED prs_merged=$PRS_MERGED issues_opened=$ISSUES_OPENED" >&2

# ================= Render stats.svg =================
STATS_W=440
ROW_H=30
STATS_ROWS=5
STATS_H=$((60 + STATS_ROWS * ROW_H))

render_stat_row() {
  local y="$1" label="$2" value="$3"
  cat <<SVGROW
  <text x="24" y="${y}" font-family="'Segoe UI', -apple-system, Ubuntu, sans-serif" font-size="14" fill="${ACCENT}">$(echo "$label" | xml_escape)</text>
  <text x="$((STATS_W - 24))" y="${y}" text-anchor="end" font-family="'SFMono-Regular', Consolas, monospace" font-weight="700" font-size="14" fill="${ACCENT}">$(echo "$value" | xml_escape)</text>
SVGROW
}

{
  cat <<SVGHEAD
<svg width="${STATS_W}" height="${STATS_H}" viewBox="0 0 ${STATS_W} ${STATS_H}" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="${GH_LOGIN} GitHub stats">
  <text x="24" y="34" font-family="'Segoe UI', -apple-system, Ubuntu, sans-serif" font-size="18" font-weight="700" fill="${ACCENT}">${GH_LOGIN}'s GitHub Stats</text>
  <line x1="24" y1="46" x2="$((STATS_W - 24))" y2="46" stroke="${ACCENT}" stroke-opacity="0.35" stroke-width="1"/>
SVGHEAD

  Y=76
  render_stat_row "$Y" "Total Stars Earned" "$TOTAL_STARS"; Y=$((Y + ROW_H))
  render_stat_row "$Y" "Total Commits (${YEAR})" "$TOTAL_COMMITS"; Y=$((Y + ROW_H))
  render_stat_row "$Y" "Total PRs Opened (${YEAR})" "$PRS_OPENED"; Y=$((Y + ROW_H))
  render_stat_row "$Y" "Total PRs Merged (${YEAR})" "$PRS_MERGED"; Y=$((Y + ROW_H))
  render_stat_row "$Y" "Total Issues Opened (${YEAR})" "$ISSUES_OPENED"; Y=$((Y + ROW_H))

  echo "</svg>"
} > "${OUT_DIR}/stats.svg"

# ================= Render top-langs.svg =================
LANG_W=440
LANG_ROW_H=26
LANG_COUNT="$(echo "$TOP_LANGS" | jq 'length')"
LANG_H=$((60 + LANG_COUNT * LANG_ROW_H))
BAR_X=170
BAR_MAX_W=$((LANG_W - BAR_X - 70))

{
  cat <<SVGHEAD
<svg width="${LANG_W}" height="${LANG_H}" viewBox="0 0 ${LANG_W} ${LANG_H}" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="${GH_LOGIN} top languages">
  <text x="24" y="34" font-family="'Segoe UI', -apple-system, Ubuntu, sans-serif" font-size="18" font-weight="700" fill="${ACCENT}">Top Languages</text>
  <line x1="24" y1="46" x2="$((LANG_W - 24))" y2="46" stroke="${ACCENT}" stroke-opacity="0.35" stroke-width="1"/>
SVGHEAD

  Y=64
  echo "$TOP_LANGS" | jq -c '.[]' | while IFS= read -r row; do
    NAME="$(echo "$row" | jq -r '.name' | xml_escape)"
    COLOR="$(echo "$row" | jq -r --arg fallback "$ACCENT" '.color // $fallback')"
    PCT="$(echo "$row" | jq -r '.pct')"
    PCT_LABEL="$(printf '%.1f' "$PCT")"
    BAR_W="$(awk -v p="$PCT" -v m="$BAR_MAX_W" 'BEGIN { w = p/100*m; if (w < 2) w = 2; printf "%.1f", w }')"
    TEXT_Y=$((Y + 14))
    cat <<SVGROW
  <text x="24" y="${TEXT_Y}" font-family="'Segoe UI', -apple-system, Ubuntu, sans-serif" font-size="13" fill="${ACCENT}">${NAME}</text>
  <rect x="${BAR_X}" y="$((Y + 3))" width="${BAR_MAX_W}" height="10" rx="5" fill="${TRACK}" fill-opacity="0.25"/>
  <rect x="${BAR_X}" y="$((Y + 3))" width="${BAR_W}" height="10" rx="5" fill="${COLOR}"/>
  <text x="$((LANG_W - 24))" y="${TEXT_Y}" text-anchor="end" font-family="'SFMono-Regular', Consolas, monospace" font-size="13" fill="${ACCENT}">${PCT_LABEL}%</text>
SVGROW
    Y=$((Y + LANG_ROW_H))
  done

  echo "</svg>"
} > "${OUT_DIR}/top-langs.svg"

echo "Wrote ${OUT_DIR}/stats.svg and ${OUT_DIR}/top-langs.svg" >&2
