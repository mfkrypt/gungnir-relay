#!/usr/bin/env bash
# js-watch.sh — detect JS chunk / bundle / sourcemap changes on live hosts.
#
# Emits ONE JSON OBJECT PER LINE on stdout. Silent when nothing changed, so it
# can be piped straight into js-watch-notify.py (or read by hand).
#
# Signals, in descending order of usefulness:
#   1. secret-hit      credential-shaped string, new here → reportable on sight
#   2. new-chunk       chunk filename not seen before   → new code shipped
#   3. changed-bundle  same URL, different content hash → in-place redeploy
#   4. new-sourcemap   a bundle now exposes a .map      → source-leak regression
#   5. chunk-gone      a previously-known chunk vanished → removed route/feature
#
# WHY THE STATE LIVES IN ~/.local/state/ AND NOT recon/<target>/js/:
#   Phase 11 deletes recon/<target>/js/raw/ as scratch, and the pipeline
#   rewrites hashes.txt from empty on every run — a monitor keyed to those
#   files would lose its baseline every time recon runs. State must outlive
#   both, and it must survive reboot (the /tmp baselines in the skill recipes
#   for subs/archive/commits silently reset on reboot — this does not).
#
# Design choice: the cheap signal is checked first and the expensive one is
# capped. A modern SPA ships 200–900 chunks; fetching them all daily across
# six hosts is ~5k requests to learn almost nothing. Manifests and the HTML
# name every chunk for ~3 requests, and a *new filename* is itself the signal
# (bundlers hash filenames, so new code almost always means a new name).
# Bundle *contents* are fetched only for a capped, ranked set — new filenames
# first (the freshest code, and the only tier that matters for catching a key
# shipped today), then known-sourcemap bundles, then first-party paths. That is
# where the in-place-redeploy, sourcemap-regression and secret cases live.

set -uo pipefail

HOSTS_FILE="${HOSTS_FILE:-$HOME/.config/js-watch/hosts.txt}"
PUBLIC_CDNS_FILE="${PUBLIC_CDNS_FILE:-$HOME/.config/js-watch/public-cdns.txt}"
STATE_ROOT="${STATE_ROOT:-$HOME/.local/state/js-watch}"
MAX_FETCH="${MAX_FETCH:-25}"        # bundles whose contents we hash + scan per host
MAX_HTML_BYTES="${MAX_HTML_BYTES:-2000000}"
TIMEOUT="${TIMEOUT:-20}"
UA="${UA:-Mozilla/5.0 (X11; Linux x86_64) js-watch/1.0}"
ALERT_FIRST_RUN=0
SEED_DIR=""
ONLY_HOST=""
SECRET_SCAN="${SECRET_SCAN:-1}"             # quick-win secret sweep over fetched bundles
MAX_SECRET_HITS="${MAX_SECRET_HITS:-10}"    # secret hits named in the alert, per host
SHOW_SECRETS="${SHOW_SECRETS:-0}"           # 1 = full values in alerts (default: masked)

log() { printf '%s\n' "$*" >&2; }

# emit <type> <host> <detail> [extra-json-object]
# The optional 4th arg must NOT be defaulted inline as "${4:-{}}" — bash's
# brace matching ends the expansion early there, leaving a stray literal '}'
# appended to the value. That produced '{...}}' and made jq reject the payload,
# so every alert carrying extra fields died silently while the one 3-arg alert
# (chunk-gone) kept working. Default via a named local instead.
emit() {
  local t="$1" h="$2" d="$3" x="${4:-}"
  [ -n "$x" ] || x='{}'
  jq -cn --arg t "$t" --arg h "$h" --arg d "$d" --argjson x "$x" \
     '{type:$t, host:$h, detail:$d} + $x'
}

usage() {
  cat >&2 <<'EOF'
usage: js-watch.sh [options]

  --hosts FILE      host list (default: ~/.config/js-watch/hosts.txt)
  --host HOST       run against a single host (overrides --hosts)
  --seed DIR        seed baseline from a recon dir, e.g. recon/example.com
                    (imports <DIR>/js/hashes.txt so run 1 does not alert on everything)
  --max-fetch N     bundles to fetch+hash per host (default 25)
  --alert-first-run emit alerts even with no prior state (default: seed silently)
  --no-secrets      skip the hardcoded-credential sweep over fetched bundles
  --dry-run         report what would change, but do not write state
  -h, --help        this text

env:
  SECRET_SCAN=0     disable the credential sweep (same as --no-secrets)
  MAX_SECRET_HITS   secret hits named in an alert, per host (default 10)
  SHOW_SECRETS=1    put full values in alerts; default masks them to a prefix
                    (full values are always written to <state>/secrets.raw.tsv)

signal secret-hit: a credential-shaped string that is NEW for this host. The
sweep anchors on ~115 credential keywords plus provider prefixes (AWS, GCP,
Stripe, GitHub, GitLab, Slack, Google OAuth, SendGrid, JWTs), and requires a
value that looks like a credential — a digit, or ≥24 chars — so labels such as
"credentials":"Credentials" and "changeme" do not fire.
EOF
}

DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --hosts) HOSTS_FILE="$2"; shift 2;;
    --host) ONLY_HOST="$2"; shift 2;;
    --seed) SEED_DIR="$2"; shift 2;;
    --max-fetch) MAX_FETCH="$2"; shift 2;;
    --alert-first-run) ALERT_FIRST_RUN=1; shift;;
    --no-secrets) SECRET_SCAN=0; shift;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) usage; exit 0;;
    *) log "unknown arg: $1"; usage; exit 2;;
  esac
done

command -v jq  >/dev/null || { log "js-watch: jq required"; exit 1; }
command -v curl >/dev/null || { log "js-watch: curl required"; exit 1; }

# hostname → safe directory key
hostkey() { printf '%s' "$1" | sed 's|^https\?://||; s|/.*$||; s|[:]|_|g'; }

# absolute-ise a possibly-relative script URL against a host root.
# MUST emit a trailing newline — every caller feeds this into `while read`
# and appends to a file. Without it the whole inventory collapses to one line.
absurl() { # absurl <base-origin> <maybe-relative>
  case "$1" in
    http*) printf '%s\n' "$1";;
    //*)   printf 'https:%s\n' "$1";;
    /*)   printf '%s%s\n' "$2" "$1";;
    *)    printf '%s/%s\n' "$2" "$1";;
  esac
}

# Resolve a _buildManifest.js entry to an absolute URL.
# Entries come in three shapes depending on Next version/assetPrefix:
#   "/_next/static/chunks/x.js"  → asset_root + entry
#   "/static/chunks/x.js"        → asset_root + "/_next" + entry   (assetPrefix builds)
#   "static/chunks/x.js"         → same, without the leading slash
# With no asset_root (non-Next site, or chunks served same-origin) they fall
# back to the site origin, which is correct for CRA/Vite asset-manifest.json.
resolve_next() { # resolve_next <entry> <asset_root> <origin>
  case "$1" in
    http*)    printf '%s\n' "$1";;
    /_next/*) printf '%s%s\n' "$2" "$1";;
    /*)  if [ -n "$2" ]; then printf '%s/_next%s\n' "$2" "$1"
                              else printf '%s%s\n' "$3" "$1"; fi;;
    *)   if [ -n "$2" ]; then printf '%s/_next/%s\n' "$2" "$1"
                              else printf '%s/%s\n' "$3" "$1"; fi;;
  esac
}

# Is this bundle served from a public package/analytics CDN? Used to suppress
# sourcemap alerts on artifacts that ship maps by design (every npm package on
# jsdelivr has one). Suffix-matched, so sub.cdn.example.com matches cdn.example.com.
is_public_cdn() { # is_public_cdn <url>
  [ -f "$PUBLIC_CDNS_FILE" ] || return 1
  local h; h=$(printf '%s' "$1" | sed 's|^https\?://||; s|/.*$||')
  [ -n "$h" ] || return 1
  local c
  while read -r c; do
    case "$c" in ''|'#'*) continue;; esac
    [ "$h" = "$c" ] && return 0
    case ".$h" in *".$c") return 0;; esac
  done < "$PUBLIC_CDNS_FILE"
  return 1
}

# -f is load-bearing: without it a 404 error page is saved as if it were the
# real file, and a 404 HTML page happily matches the `"[^"]+\.js"` grep used
# on _buildManifest.js — injecting garbage URLs from the error page itself.
fetch() { # fetch <url> <outfile>  → 0 on success
  curl -fsS -L --compressed --max-time "$TIMEOUT" -A "$UA" \
       --retry 2 --retry-delay 2 "$1" -o "$2" 2>/dev/null && [ -s "$2" ]
}

# ── quick-win secret sweep ───────────────────────────────────────────────────
# Finds hardcoded credentials in the bundles we already fetched for hashing.
# This is the highest-value signal js-watch can produce: a live key in shipped
# JS is reportable on sight, no exploitation required.

# THE KEYWORD LIST IS AN ANCHOR, NOT A MATCHER. `grep -oE "<keywords>"` alone
# returns identifiers, not secrets — on a minified bundle `config`, `apikey` and
# `credentials` appear thousands of times as property names with no value
# anywhere near them. Measured 2026-09-30 on five real minified libraries
# (570 KB): 49 bare keyword hits, zero real secrets. What carries the signal is
# the *whole*
# assignment, so the pattern requires keyword + separator + quoted value, and
# the value must look like a credential (see SECRET_VAL) rather than a label.
#
# Two branches of the original list contained a literal space ("api.googlemaps
# AIza", "bashrc password") — two keywords a documentation generator had joined
# with a space, which as a POSIX branch matches the literal string and so can
# never fire. They are split back into separate branches here.
SECRET_KW='(access_key|access_token|admin_pass|admin_user|algolia_admin_key|algolia_api_key|alias_pass|alicloud_access_key|amazon_secret_access_key|amazonaws|ansible_vault_password|aos_key|api_key|api_key_secret|api_key_sid|api_secret|api\.googlemaps|AIza|apidocs|apikey|apiSecret|app_debug|app_id|app_key|app_log_level|app_secret|appkey|appkeysecret|application_key|appsecret|appspot|auth_token|authorizationToken|authsecret|aws_access|aws_access_key_id|aws_bucket|aws_key|aws_secret|aws_secret_key|aws_token|AWSSecretKey|b2_app_key|bashrc|password|bintray_apikey|bintray_gpg_password|bintray_key|bintraykey|bluemix_api_key|bluemix_pass|browserstack_access_key|bucket_password|bucketeer_aws_access_key_id|bucketeer_aws_secret_access_key|built_branch_deploy_key|bx_password|cache_driver|cache_s3_secret_key|cattle_access_key|cattle_secret_key|certificate_password|ci_deploy_password|client_secret|client_zpk_secret_key|clojars_password|cloud_api_key|cloud_watch_aws_access_key|cloudant_password|cloudflare_api_key|cloudflare_auth_key|cloudinary_api_secret|cloudinary_name|codecov_token|config|conn\.login|connectionstring|consumer_key|consumer_secret|credentials|cypress_record_key|database_password|database_schema_test|datadog_api_key|datadog_app_key|db_password|db_server|db_username|dbpasswd|dbpassword|dbuser|deploy_password|digitalocean_ssh_key_body|digitalocean_ssh_key_ids|docker_hub_password|docker_key|docker_pass|docker_passwd|docker_password|dockerhub_password|dockerhubpassword|dot-files|dotfiles|droplet_travis_password|dynamoaccesskeyid|dynamosecretaccesskey|elastica_host|elastica_port|elasticsearch_password|encryption_key|encryption_password|heroku_api_key|sonatype_password|awssecretkey)'

# A value qualifies only if it carries a digit, or runs ≥24 chars. That single
# test is what kills the label i18n that otherwise dominates the output —
# {"credentials":"Credentials","config":"Configuration","password":"Password"}
# all die here, as do "changeme", "YOUR_API_KEY_HERE" and "com.example.app".
# NOTE the digit branch must be [ANY]*[0-9][ANY]* with digits *inside* the
# class: a class excluding digits cannot span "Sup3rS3cret" or "abc123", so that
# (wrong) form silently reported no match on the very keys it was written to
# find. It reads exactly like a quantifier bug, and was first mis-diagnosed as
# "{24,} vs {24,256}" — re-measured with the class fixed, both caps match
# identically. The bounded cap below is context-safety, not the fix.
SECRET_VAL='[A-Za-z0-9_+/.=~!@#$%^&*?-]'
SECRET_RE="(${SECRET_KW})[\"']?[[:space:]]*[:=][[:space:]]*[\"'](${SECRET_VAL}*[0-9]${SECRET_VAL}*|${SECRET_VAL}{24,256})[\"']"

# Provider tokens match WITHOUT a keyword near them — a Stripe key on its own
# line is still a live Stripe key. Deliberately short: these are the prefixes
# with a fixed, unmistakable shape. (jsluice and trufflehog cover the long tail
# during recon; this pass exists to catch a deploy at 03:00.)
SECRET_PROV='AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{33,40}|sk_live_[0-9A-Za-z]{16,99}|sk_test_[0-9A-Za-z]{16,99}|ghp_[0-9A-Za-z]{30,40}|gho_[0-9A-Za-z]{30,40}|ghs_[0-9A-Za-z]{30,40}|glpat-[0-9A-Za-z_-]{18,30}|xox[baprs]-[0-9A-Za-z-]{10,60}|ya29\.[0-9A-Za-z_.-]{20,200}|eyJ[A-Za-z0-9_-]{8,512}\.[A-Za-z0-9_-]{8,512}\.[A-Za-z0-9_-]{8,512}|SG\.[A-Za-z0-9_-]{16,64}\.[A-Za-z0-9_-]{16,64}|-----BEGIN [A-Z ]{0,40}PRIVATE KEY-----'

# Noise that survives the value test. Kept SHORT on purpose: every placeholder
# word added here is a real key it can swallow ("AKIAIOSFODNN7EXAMPLE" contains
# "EXAMPLE" and is a documented AWS sample, but a customer key can contain the
# same letters). Placeholders like YOUR_KEY are already killed by the
# digit/length test; what is left to catch is the shape of a non-secret.
#
# The path and hostname branches are not hypothetical — the first sweep against
# a REAL app bundle produced exactly those two and nothing else:
#   config":"/quartz/…(28 ch)          ← a URL path, survived via the ≥24-char
#                                        branch (length alone is not a secret)
#   config":"stat…(13 ch)              ← a lowercase dotted hostname
# Both came from a vendor bundle (js-na2.hsforms.net). Rejecting a quoted value
# that STARTS with `/`, and one that is entirely a lowercase dotted name, kills
# them without touching a single planted key in the test fixture — including the
# AWS-doc secret `wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY`, which has uppercase
# and slashes and so matches neither branch.
#
# A second live hit survived the first fix: `config":"static-1.1282"` — a
# HubSpot asset version token. All lowercase, so the hostname branch missed it
# (its `.1282` is digits, not a TLD). The general rule that kills it: a quoted
# value made only of lowercase letters, digits, `.`, `_` and `-`, and shorter
# than 16 chars, has no credential shape — that is where asset versions, slugs
# and tag names live. Hex keys in this pipeline are 32+; a 16-char floor keeps
# every one of them. (Cost: a genuine lowercase alnum key under 16 chars would
# be missed. Judged unlikely for anything worth alerting on, and the alternative
# is a channel that cries wolf on cache-busters.)
#
# The five-library precision result (0 hits/570 KB) did NOT predict either hit:
# npm libraries assign no paths or version tokens to `config`, web app bundles
# do. Measure the pattern on an app bundle before trusting it.
SECRET_Q="[\"']"   # one quote char, either kind — built once so the patterns
                   # below read as patterns instead of as quote gymnastics.
                   # (The nested '"'"' idiom used elsewhere in this file is
                   # correct but unreadable at this length, and a typo in it
                   # fails as an EMPTY pattern, which filters every hit away
                   # silently — the exact failure this sweep exists to avoid.)
SECRET_NOISE="://|^[^:]*[:=][[:space:]]*${SECRET_Q}[a-z0-9._-]{1,15}${SECRET_Q}\$|${SECRET_Q}/|${SECRET_Q}[a-z0-9][a-z0-9.-]*\.[a-z]{2,15}${SECRET_Q}\$|[A-Za-z0-9._%-]*\.(js|mjs|css|json|png|jpe?g|svg|gif|webp|woff2?|ttf|eot|ico|map)${SECRET_Q}|(^|[^A-Za-z0-9])127\.0\.0\.1|(^|[^A-Za-z0-9])localhost|AKIAIOSFODNN7EXAMPLE|wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY|AKIAI44QH8DHBEXAMPLE"

# minify-aware split: structural punctuation becomes newlines so a keyword and
# its value land on one short line. Without this, a single 6MB line makes every
# windowed regex skip matches it has already consumed (verified: windows around
# a keyword swallowed their neighbours, reporting 10 hits for 11 secrets).
SECRET_SPLIT=',;{}()[]'

# scan_secrets <file> → "keyword<TAB>value" and "prov:<prefix><TAB>value" lines
scan_secrets() {
  local f="$1" m k v
  {
    tr "$SECRET_SPLIT" '\n\n\n\n\n\n\n\n' < "$f" 2>/dev/null \
      | grep -oiE "$SECRET_RE" 2>/dev/null \
      | grep -viE "$SECRET_NOISE" 2>/dev/null \
      | while IFS= read -r m; do
          k=${m%%[:=]*}
          case "$k" in *\"|*\') k=${k%?};; esac  # `config"` → `config` (the regex
          case "$k" in \"*|\'*) k=${k#?};; esac  # match starts at the keyword, the
                                                 # quote before the separator sticks)
          v=${m#*[:=]}
          v=${v#"${v%%[![:space:]]*}"}          # leading spaces
          case "$v" in \"*|\'*) v=${v:1};; esac  # opening quote
          case "$v" in *\"|*\') v=${v%?};; esac  # closing quote
          [ -n "$v" ] || continue
          printf '%s\t%s\n' "$k" "$v"
        done
    grep -oE "$SECRET_PROV" "$f" 2>/dev/null \
      | grep -viE "$SECRET_NOISE" 2>/dev/null \
      | while IFS= read -r v; do printf 'prov:%s\t%s\n' "$(printf '%s' "$v" | cut -c1-4)" "$v"; done
  } | LC_ALL=C sort -u
}

# Discord is a third party. Default to a prefix + length so an alert is
# actionable ("which one is it") without publishing a live credential into a
# channel that may outlive the engagement. Full values land in
# <state>/secrets.raw.tsv (0600, never leaves the box) — that is the file to
# open when acting on a hit, and the file evidence-hygiene applies to.
mask_secret() {
  local v="$1" n
  if [ "${SHOW_SECRETS:-0}" = 1 ]; then printf '%s' "$v"; return 0; fi
  n=$((${#v} / 4)); [ "$n" -gt 8 ] && n=8; [ "$n" -lt 4 ] && n=4
  printf '%s…(%d ch)' "$(printf '%s' "$v" | cut -c1-"$n")" "${#v}"
}

secret_hash() { # stable identity for a (keyword, value) pair
  printf '%s|%s' "$1" "$2" | md5sum | cut -c1-16
}

# ── baseline seeding ─────────────────────────────────────────────────────────
# js-analyze Stage 1 already writes "<contenthash> <urlhash> <url>" per run.
# Importing it means the first watch run diffs against real prior knowledge
# instead of declaring every chunk on the site brand new.
seed_state() { # seed_state <seed_dir> <state_dir>
  local seed="$1" st="$2"
  [ -n "$seed" ] || return 0
  local hf="$seed/js/hashes.txt"
  [ -f "$hf" ] || { log "  seed: no $hf — skipping"; return 0; }
  : > "$st/hashes.tsv"
  while read -r ch uh url; do
    [ -n "${url:-}" ] || continue
    printf '%s\t%s\t%s\n' "$url" "$ch" "$(basename "${url%%\?*}")" >> "$st/hashes.tsv"
  done < "$hf"
  awk -F'\t' '{print $3}' "$st/hashes.tsv" | sort -u > "$st/chunks.txt"
  log "  seed: imported $(wc -l < "$st/hashes.tsv") bundles from $hf"
}

# ── per-host run ─────────────────────────────────────────────────────────────
run_host() {
  local raw="$1"
  local origin host st
  case "$raw" in
    http*) origin="${raw%/}";;
    *)     origin="https://${raw%/}";;
  esac
  host=$(printf '%s' "$origin" | sed 's|^https\?://||')
  st="$STATE_ROOT/$(hostkey "$origin")"

  local first_run=0
  [ -f "$st/.seeded" ] || first_run=1

  if [ ! -d "$st" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      log "== $host (dry-run, no state dir — nothing to diff)"
      return 0
    fi
    mkdir -p "$st" || return 1
  fi

  if [ "$first_run" = 1 ] && [ -z "$SEED_DIR" ] && [ "$ALERT_FIRST_RUN" != 1 ]; then
    log "== $host (first run — seeding baseline, no alerts)"
  else
    log "== $host"
  fi

  local tmp; tmp=$(mktemp -d) || return 1
  local html="$tmp/index.html"

  if ! fetch "$origin/" "$html"; then
    log "  ! root fetch failed — skipping host"
    rm -rf "$tmp"; return 0
  fi

  # ---- 1. inventory: HTML script tags + framework manifests ----------------
  local urls="$tmp/urls.txt"; : > "$urls"

  grep -oE '(src|href)="[^"]+\.(js|mjs)(\?[^"]*)?"' "$html" 2>/dev/null \
    | sed -E 's/^[a-z]+="//; s/"$//' \
    | while read -r u; do absurl "$u" "$origin"; done >> "$urls"

  # Next.js serves chunks from an assetPrefix that is frequently a DIFFERENT host
  # and path (web-assets.example.com/web-main/_next/...). _buildManifest.js lists
  # its entries relative to the _next root, not the site root — so resolving them
  # against the origin 404s, and on some hosts returns a 200 STUB, which would
  # quietly hash the wrong bytes and never change. Infer the asset root from any
  # absolute _next bundle URL we just collected and resolve against that.
  local asset_root=""
  asset_root=$(grep -oE 'https?://[^"]+/_next/static/' "$urls" 2>/dev/null \
               | head -1 | sed 's|/_next/static/$||')
  [ -n "$asset_root" ] && log "  next asset root: $asset_root"

  # Next.js: buildId → _buildManifest.js (authoritative chunk + route list)
  local buildid
  buildid=$(grep -oE '"buildId":"[^"]+"' "$html" 2>/dev/null | head -1 | cut -d'"' -f4)
  if [ -n "${buildid:-}" ]; then
    local mf="$tmp/_buildManifest.js"
    if { [ -n "$asset_root" ] && fetch "$asset_root/_next/static/$buildid/_buildManifest.js" "$mf"; } \
       || fetch "$origin/_next/static/$buildid/_buildManifest.js" "$mf"; then
      grep -oE '"[^"]+\.js"' "$mf" | tr -d '"' \
        | while read -r u; do resolve_next "$u" "$asset_root" "$origin"; done >> "$urls"
    fi
  fi

  # CRA / Vite: asset-manifest.json is the full chunk list
  if fetch "$origin/asset-manifest.json" "$tmp/asset-manifest.json"; then
    jq -r '.. | strings | select(test("\\.(js|mjs)$"))' "$tmp/asset-manifest.json" 2>/dev/null \
      | while read -r u; do absurl "$u" "$origin"; done >> "$urls"
  fi

  # LC_ALL=C throughout: `sort` under a UTF-8 locale orders case-insensitively
  # (osano.js before ScrollTrigger.min.js) while `comm` compares bytes. Mismatched
  # collation makes comm silently drop matches — every diff below depends on this.
  sed 's/[?#].*$//' "$urls" | LC_ALL=C sort -u > "$tmp/urls.clean"
  local nurls; nurls=$(wc -l < "$tmp/urls.clean")
  log "  inventory: $nurls JS URLs"

  [ "$nurls" -gt 0 ] || { rm -rf "$tmp"; log "  ! no JS found — nothing to watch"; return 0; }

  # ---- 2. new-chunk / chunk-gone (filename diff — the cheap high-signal one) -
  local names_now="$tmp/chunks.now"
  awk -F/ '{print $NF}' "$tmp/urls.clean" | LC_ALL=C sort -u > "$names_now"

  local known_names="$st/chunks.txt"
  [ -f "$known_names" ] || : > "$known_names"

  local quiet=0
  { [ "$first_run" = 1 ] && [ "$ALERT_FIRST_RUN" != 1 ]; } && quiet=1

  # Computed BEFORE the quiet gate: the alert is gated, the fetch ranking in
  # section 3 is not. A first run has no known names, so every URL ranks as new
  # and the order degenerates to the unranked one — harmless, and it means the
  # seeding run already fetches the right things.
  local new_names="$tmp/new-chunks"
  LC_ALL=C comm -13 <(LC_ALL=C sort -u "$known_names") \
                  <(LC_ALL=C sort -u "$names_now") > "$new_names"

  if [ "$quiet" = 0 ]; then
    while read -r c; do
      [ -n "$c" ] || continue
      local src
      src=$(grep -F "/$c" "$tmp/urls.clean" | head -1)
      emit new-chunk "$host" "$c" "$(jq -cn --arg u "$src" '{url:$u}')"
    done < "$tmp/new-chunks"

    LC_ALL=C comm -23 <(LC_ALL=C sort -u "$known_names") \
                    <(LC_ALL=C sort -u "$names_now") > "$tmp/gone-chunks"
    while read -r c; do
      [ -n "$c" ] || continue
      emit chunk-gone "$host" "$c"
    done < "$tmp/gone-chunks"
  fi

  # ---- 3. content hash + sourcemap check on a capped, RANKED subset --------
  # Ranking, highest first:
  #   (0) filenames we have never seen — the freshest code on the host
  #   (a) bundles we already know expose a .map (regression check)
  #   (b) first-party-looking paths   (c) everything else
  #
  # Tier 0 is the whole point of the ordering. Without it the cap is spent
  # alphabetically, so a chunk deployed today competes for a slot with one that
  # has not changed in months — and the freshest code is exactly what a change
  # monitor should be looking at. It costs nothing: the filename diff is already
  # computed above for the new-chunk alert. Tier 0 is also self-limiting, since
  # it only holds what changed since the last run; on a steady-state host it is
  # empty and the order is the pre-existing one.
  local known_sm="$st/sourcemaps.txt"; [ -f "$known_sm" ] || : > "$known_sm"
  local cand="$tmp/cand.txt"; : > "$cand"

  # (0) new filenames — one awk pass over the inventory (a basename lookup), not
  # one grep per name, so a 200-new-chunk deploy does not fork 200 processes.
  LC_ALL=C awk -F/ 'NR==FNR { fresh[$1]=1; next } ($NF in fresh)' \
      "$new_names" "$tmp/urls.clean" >> "$cand"

  # (a) previously sourcemap-exposing bundles
  while read -r u; do
    [ -n "$u" ] || continue
    grep -Fxq "$u" "$tmp/urls.clean" && printf '%s\n' "$u" >> "$cand"
  done < "$known_sm"

  # (b) first-party-looking, (c) the rest
  grep -Ev '/(vendor|node_modules|npm\.|polyfills|chunk-vendors)[./]' "$tmp/urls.clean" >> "$cand"
  cat "$tmp/urls.clean" >> "$cand"
  awk '!seen[$0]++' "$cand" | head -n "$MAX_FETCH" > "$cand.capped"

  local hashes_now="$tmp/hashes.now"; : > "$hashes_now"
  local sm_now="$tmp/sm.now"; : > "$sm_now"
  local nfetched=0

  while read -r u; do
    [ -n "$u" ] || continue
    local bf="$tmp/b.js"
    fetch "$u" "$bf" || continue
    nfetched=$((nfetched+1))

    local ch; ch=$(md5sum < "$bf" | cut -c1-32)
    printf '%s\t%s\t%s\n' "$u" "$ch" "$(basename "${u%%\?*}")" >> "$hashes_now"

    # Quick-win sweep on bytes already paid for. Runs on every fetched bundle,
    # not just changed ones: the diff that matters is against state (has this
    # secret been reported before), not against the previous hash — which also
    # catches a secret that a re-seed or a hand-deleted state file lost track of.
    if [ "$SECRET_SCAN" = 1 ]; then
      while IFS=$'\t' read -r k v; do
        [ -n "$v" ] || continue
        printf '%s\t%s\t%s\t%s\n' "$(secret_hash "$k" "$v")" "$u" "$k" "$v" >> "$tmp/sec.cand"
      done < <(scan_secrets "$bf")
    fi

    # Is a sourcemap actually retrievable? Probe <bundle>.map with a range GET
    # (cheap, and works on servers that 405 a HEAD).
    #
    # Two traps here, both verified live:
    #   1. A range GET succeeds with 206 Partial Content, NOT 200 — testing for
    #      "200" only silently kills the entire probe.
    #   2. The status code still is not evidence. app.deephat.ai answers 206 for
    #      a .map that does not exist, with the body "Not Found" — so trusting the
    #      code alone marked 14 non-existent maps as exposed source.
    # A real sourcemap is JSON, so validate the payload: first byte must be '{'.
    # Deliberately NOT grepping the bundle for "sourceMappingURL" — webpack
    # compiles that literal into its runtime, so it matches chunks that ship no
    # map at all.
    local code
    code=$(curl -sS -o "$tmp/mapprobe" -w '%{http_code}' --max-time 10 -A "$UA" \
           -r 0-0 "${u}.map" 2>/dev/null)
    case "$code" in
      2*) [ "$(head -c 1 "$tmp/mapprobe" 2>/dev/null)" = "{" ] \
            && printf '%s\n' "$u" >> "$sm_now";;
    esac
    rm -f "$tmp/mapprobe"
    rm -f "$bf"
  done < "$cand.capped"

  log "  fetched $nfetched/$MAX_FETCH bundle(s) for hashing"

  if [ "$quiet" = 0 ]; then
    # in-place redeploy: same URL, new content hash
    if [ -f "$st/hashes.tsv" ]; then
      while IFS=$'\t' read -r u ch _; do
        [ -n "$u" ] || continue
        local old; old=$(awk -F'\t' -v k="$u" '$1==k{print $2; exit}' "$st/hashes.tsv")
        [ -n "$old" ] || continue
        [ "$old" = "$ch" ] && continue
        emit changed-bundle "$host" "$(basename "${u%%\?*}")" \
             "$(jq -cn --arg u "$u" --arg o "$old" --arg n "$ch" '{url:$u,old_hash:$o,new_hash:$n}')"
      done < "$hashes_now"

      # new sourcemap exposure — a source-leak regression (reportable, not just intel).
      # Public package CDNs (jsdelivr, unpkg, cdnjs…) ship .map files by design for
      # every npm package; alerting on those buries the signal that matters, which
      # is YOUR code leaking source. They stay tracked in state, but do not alert.
      LC_ALL=C sort -u "$sm_now" > "$tmp/sm.sorted"
      LC_ALL=C comm -13 <(LC_ALL=C sort -u "$known_sm") "$tmp/sm.sorted" > "$tmp/sm.new"
      while read -r u; do
        [ -n "$u" ] || continue
        is_public_cdn "$u" && { log "  (sourcemap on public CDN, tracked not alerted: $(basename "${u%%\?*}"))"; continue; }
        emit new-sourcemap "$host" "$(basename "${u%%\?*}")" \
             "$(jq -cn --arg u "$u" '{url:$u}')"
      done < "$tmp/sm.new"
    fi
  fi

  # ---- 3b. quick-win secrets — report only what is NEW for this host -------
  # The diff is against the secret's identity (keyword+value), not its URL: a
  # key that moves to a new chunk filename is the same key, and re-alerting it
  # every time the bundler renames a file is how a channel gets muted.
  if [ "$SECRET_SCAN" = 1 ] && [ -s "$tmp/sec.cand" ]; then
    LC_ALL=C sort -u "$tmp/sec.cand" > "$tmp/sec.uniq"
    awk -F'\t' '!seen[$1]++' "$tmp/sec.uniq" > "$tmp/sec.first"   # one URL per secret

    local known_sec="$st/secrets.tsv"; [ -f "$known_sec" ] || : > "$known_sec"
    awk -F'\t' -v known="$known_sec" '
      BEGIN { while ((getline l < known) > 0) { split(l, a, "\t"); seen[a[1]] = 1 } }
      !seen[$1] { print }' "$tmp/sec.first" > "$tmp/sec.new"

    local nnew; nnew=$(wc -l < "$tmp/sec.new")
    log "  secrets: $nnew new of $(wc -l < "$tmp/sec.first") hit(s) in $nfetched bundle(s)"
    [ "$nnew" -gt 0 ] && [ "$quiet" = 1 ] \
      && log "  (first run for this host — recorded, not alerted)"

    if [ "$nnew" -gt 0 ] && [ "$DRY_RUN" = 0 ]; then
      # Evidence first, alert second. The raw file is the one to open when
      # acting on a hit; the alert carries the path to it, not the value.
      # EVERY new hit is written here even when the alert is capped — the alert
      # is for attention, this file is for triage.
      [ -f "$st/secrets.raw.tsv" ] || : > "$st/secrets.raw.tsv"
      chmod 600 "$st/secrets.raw.tsv" 2>/dev/null
      while IFS=$'\t' read -r h u k v; do
        [ -n "$h" ] || continue
        printf '%s\t%s\t%s\t%s\n' "$(date -Is)" "$u" "$k" "$v" >> "$st/secrets.raw.tsv"
      done < "$tmp/sec.new"
    fi

    if [ "$nnew" -gt 0 ] && [ "$quiet" = 0 ]; then
      head -n "$MAX_SECRET_HITS" "$tmp/sec.new" | while IFS=$'\t' read -r h u k v; do
        [ -n "$h" ] || continue
        emit secret-hit "$host" "$(basename "${u%%\?*}"): $k ≈ $(mask_secret "$v")" \
             "$(jq -cn --arg u "$u" --arg k "$k" --arg p "$(mask_secret "$v")" \
                      --arg e "$st/secrets.raw.tsv" \
                      '{url:$u, keyword:$k, preview:$p, evidence:$e}')"
      done
      [ "$nnew" -gt "$MAX_SECRET_HITS" ] \
        && log "  (+$((nnew - MAX_SECRET_HITS)) more, all recorded in $st/secrets.tsv)"
    fi
  fi

  # ---- 4. commit state ----------------------------------------------------
  if [ "$DRY_RUN" = 0 ]; then
    cp "$names_now" "$st/chunks.txt"
    if [ -s "$tmp/sec.new" ]; then
      while IFS=$'\t' read -r h u k v; do
        [ -n "$h" ] || continue
        printf '%s\t%s\t%s\t%s\n' "$h" "$k" "$(mask_secret "$v")" "$u"
      done < "$tmp/sec.new" >> "$st/secrets.tsv"
      awk -F'\t' '!seen[$1]++' "$st/secrets.tsv" > "$tmp/sec.state" \
        && mv "$tmp/sec.state" "$st/secrets.tsv"
    fi
    if [ -s "$hashes_now" ]; then
      # merge: keep hashes for URLs we did not re-fetch this run
      awk -F'\t' 'NR==FNR{new[$1]=$0; next} !($1 in new){print}' \
          "$hashes_now" "$st/hashes.tsv" 2>/dev/null > "$tmp/merged.tsv"
      cat "$hashes_now" >> "$tmp/merged.tsv"
      awk -F'\t' '!seen[$1]++' "$tmp/merged.tsv" > "$st/hashes.tsv"
    fi
    LC_ALL=C sort -u "$sm_now" "$known_sm" > "$st/sourcemaps.txt"
    : > "$st/.seeded"
    date -Is > "$st/.last-run"
  fi

  rm -rf "$tmp"
  return 0
}

# ── main ─────────────────────────────────────────────────────────────────────
mkdir -p "$STATE_ROOT" 2>/dev/null

hosts="$HOSTS_FILE"
if [ -n "$ONLY_HOST" ]; then
  hosts=$(mktemp)
  printf '%s\n' "$ONLY_HOST" > "$hosts"
fi

if [ ! -f "$hosts" ]; then
  log "js-watch: host list not found: $hosts"
  log "create it with one URL per line, e.g.:"
  log "  mkdir -p ~/.config/js-watch && echo https://example.com > $HOSTS_FILE"
  exit 1
fi

if [ -n "$SEED_DIR" ]; then
  while read -r raw; do
    case "$raw" in ''|'#'*) continue;; esac
    origin="${raw%/}"; case "$origin" in http*) ;; *) origin="https://$origin";; esac
    st="$STATE_ROOT/$(hostkey "$origin")"
    [ -d "$st" ] || mkdir -p "$st"
    [ -f "$st/.seeded" ] || seed_state "$SEED_DIR" "$st"
  done < "$hosts"
fi

while read -r raw; do
  case "$raw" in ''|'#'*) continue;; esac
  run_host "$raw"
done < "$hosts"
