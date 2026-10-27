# Part of OmaControl. Sourced by bin/omacontrol; not run on its own.
#
# Headlines from omarchy.org. The only thing in this window that leaves the
# machine, which buys it three rules:
#
#   Cached.     One fetch every few hours, kept on disk, and every read after
#               that is a file read. Opening the Overview page does not mean a
#               request.
#   Never waits. The page polls for whatever is cached and the fetch happens
#               in its own subcommand, so a site that hangs costs the reader
#               nothing. The stamp says how old the answer is.
#   Silent on   omarchy.org has no feed, so this reads the news page's HTML.
#   failure.    That is someone else's markup and it will change — one of the
#               headlines it is parsing right now is about the site being
#               redesigned. When the shape moves, this returns nothing and the
#               section disappears rather than showing wreckage.

# The feed, not the page. omarchy.org publishes RSS at /news/rss.xml — it is
# not advertised with a <link rel="alternate"> in the news page's head, which
# is how the first version of this ended up scraping the HTML instead.
#
# A feed is a contract and markup is not. The scraper had to be told which
# <span> held a headline and would have broken the next time the site was
# restyled; this reads elements that are named in the RSS spec.
NEWS_URL="${OMACONTROL_NEWS_URL:-https://omarchy.org/news/rss.xml}"

NEWS_CACHE="${OMACONTROL_NEWS_CACHE:-${XDG_CACHE_HOME:-$HOME_DIR/.cache}/omarchy/omacontrol/news.json}"
# Half an hour. Short enough that a headline posted this morning is on the page
# by lunch; long enough that a window opened twenty times in an afternoon is
# still one request. `news fetch` checks this itself, so the page can ask on
# every open and on a timer without either of those meaning a request.
NEWS_MAX_AGE=${OMACONTROL_NEWS_MAX_AGE:-1800}

# How many read marks to keep. The list only ever grows, and a headline that
# scrolled off omarchy.org years ago cannot come back to be unread — so old
# marks are dropped rather than kept for ever in a config file.
NEWS_READ_KEEP=${OMACONTROL_NEWS_READ_KEEP:-60}

# The cache, with each item told whether it has been read.
#
# Read state lives in OmaControl's own store rather than beside the cache: the
# cache is disposable — delete it and the next fetch rebuilds it — while what
# you have already read is yours, and losing it would light up eight stars for
# news you read last week.
news_cached() {
  [[ -f $NEWS_CACHE ]] || { echo '{}'; return; }
  local cache read
  cache=$(emit_json "$(read_file "$NEWS_CACHE")" '{}')
  read=$(news_read_list)

  # Compared with the trailing slash taken off both sides. The RSS feed's
  # <link> has no trailing slash; the HTML this used to scrape did — so the
  # switch to the feed would otherwise have made every already-read headline
  # look new, and any future change of convention would do it again. Marks
  # already in the store are normalised on the way in rather than migrated.
  emit_json "$(jq -cn --argjson cache "${cache:-{\}}" --argjson read "${read:-[]}" '''
    ( $read | map(rtrimstr("/")) ) as $marks
    | $cache + { items: [ $cache.items[]? | . as $item
                          | $item + { read: ($marks | index($item.url | rtrimstr("/")) != null) } ] }''')" '{}'
}

news_read_list() {
  read_store | jq -c '[ (.newsRead // [])[] ]' 2>/dev/null || echo '[]'
}

# Marking read is idempotent and bounded, and it does not re-render anything:
# note_store writes the store without rebuilding the Hyprland config, which a
# read headline has no business touching.
news_mark_read() {
  local url=${1%/}
  [[ -n $url ]] || return 0
  note_store '.newsRead = (((.newsRead // []) + [$url]) | unique | .[-($keep):])' \
    --arg url "$url" --argjson keep "$NEWS_READ_KEEP"
}

news_mark_unread() {
  local url=${1%/}
  [[ -n $url ]] || return 0
  # Both spellings, so a mark written before the feed switch also clears.
  note_store '.newsRead = ((.newsRead // []) - [$url, $slashed])' \
    --arg url "$url" --arg slashed "$url/"
  return 0
}

# Everything currently in the cache, in one write.
news_mark_all_read() {
  local urls
  urls=$(news_cached | jq -c '[ .items[]?.url ]')
  note_store '.newsRead = (((.newsRead // []) + $urls) | unique | .[-($keep):])' \
    --argjson urls "${urls:-[]}" --argjson keep "$NEWS_READ_KEEP"
}

news_age() {
  local at
  at=$(news_cached | jq -r '.fetchedAt // 0' 2>/dev/null)
  echo $(( $(date +%s) - ${at:-0} ))
}

# Whether a fetch is worth making. The page calls this before asking for one,
# so a stale cache is refreshed and a fresh one is left alone.
news_stale() {
  [[ ! -f $NEWS_CACHE ]] && return 0
  (( $(news_age) > NEWS_MAX_AGE ))
}

news_fetch() {
  # The age check lives here, not in the caller. Every comment about this being
  # free to ask depends on it, and for a while it was not true: `fetch` ran the
  # request unconditionally and `stale` was a subcommand nobody called, so a
  # window opened twenty times made twenty requests.
  if offline || { [[ ${1:-} != --force ]] && ! news_stale; }; then
    # Still seed, in case a cache was written before read marks existed.
    news_seed
    news_cached
    return
  fi

  local html
  # Bounded like every other read here, and identified: a scraper that does not
  # say what it is gives the other end no way to ask it to stop.
  html=$(timeout "$OMACONTROL_READ_TIMEOUT" curl -sS -L --max-time "$OMACONTROL_READ_TIMEOUT" \
    -A "omacontrol (+https://github.com/twiking/omacontrol)" "$NEWS_URL" 2>/dev/null \
    | head -c "$OMACONTROL_READ_MAX")
  [[ -n $html ]] || { news_cached; return; }

  local items
  items=$(printf '%s' "$html" | news_parse)
  # A parse that found nothing means the page moved. The last good cache is
  # better than an empty list, and an empty list is better than a broken one.
  if [[ $(jq -r 'length' <<<"${items:-[]}" 2>/dev/null || echo 0) -eq 0 ]]; then
    news_cached
    return
  fi

  local next
  next=$(jq -cn --argjson items "$items" --argjson at "$(date +%s)" \
    '{ fetchedAt: $at, items: $items }')
  mkdir -p "$(dirname "$NEWS_CACHE")"
  printf '%s\n' "$next" >"$NEWS_CACHE" 2>/dev/null
  news_seed
  # Read back through news_cached so callers always get the same shape, read
  # marks included.
  news_cached
}

# The first list anyone sees is not "new". Without this, a fresh install opens
# on eight starred headlines — every one of which is simply the news, and none
# of which the reader has missed. So the first successful fetch marks what it
# found as read, and a star from then on means *since you last looked*.
#
# Flagged separately from the read list itself, or marking everything unread
# again would be undone by the next fetch.
news_seed() {
  [[ $(read_store | jq -r '.newsSeeded // false') == true ]] && return 0
  local urls
  urls=$(emit_json "$(read_file "$NEWS_CACHE")" '{}' | jq -c '[ .items[]?.url ]')
  note_store '.newsSeeded = true | .newsRead = (($urls // []) | unique)' \
    --argjson urls "${urls:-[]}"
}

# Python because this is XML, and the parser that ships with it knows what a
# CDATA section is and how to unescape an entity. A regex over someone's feed
# would be the same fragility as the regex over their HTML, one layer down.
news_parse() {
  # The program arrives on fd 3, not on stdin. `python3 -` reads its *script*
  # from stdin, which would eat the feed this is meant to be parsing — the
  # parser then finds nothing in an empty string and reports a feed that
  # changed shape, which is a maddening way to debug a working parser.
  python3 /dev/fd/3 3<<'PY'
import json
import sys
import xml.etree.ElementTree as ET
from email.utils import parsedate_to_datetime

try:
    root = ET.fromstring(sys.stdin.buffer.read())
except ET.ParseError:
    # Not a feed today. The caller keeps the last good cache.
    json.dump([], sys.stdout)
    sys.exit(0)

items = []
seen = set()
for item in root.iterfind('./channel/item'):
    title = (item.findtext('title') or '').strip()
    # The guid is the identity when it is a permalink; the link is the
    # fallback. Read marks are keyed on this, so it has to be the stable one.
    link = (item.findtext('link') or '').strip()
    guid = (item.findtext('guid') or '').strip()
    url = link or guid
    if not title or not url or url in seen:
        continue
    seen.add(url)

    iso = ''
    shown = ''
    raw = (item.findtext('pubDate') or '').strip()
    if raw:
        try:
            when = parsedate_to_datetime(raw)
            iso = when.date().isoformat()
            # Written out the way the site writes it, rather than a format the
            # reader has to decode.
            shown = when.strftime('%B %-d, %Y')
        except (TypeError, ValueError):
            pass

    items.append({
        'title': title,
        'url': url,
        'date': iso,
        'shown': shown,
        'summary': (item.findtext('description') or '').strip(),
    })
    if len(items) == 8:
        break

json.dump(items, sys.stdout)
PY
}

# Opening a headline hands it to the browser and then *goes there*: the window
# closes and the workspace the browser is on comes forward.
#
# Without the second half, clicking a headline on a single-monitor setup looks
# like nothing happened — the browser has the URL, but it is on workspace 2 and
# you are still on 1, looking at a window that has just closed itself.
news_open() {
  local url=$1
  # Only ever a URL this fetch produced, and only ever on the site it came
  # from: a headline is untrusted text and its link is untrusted with it.
  [[ $url == https://omarchy.org/* ]] || die "refusing to open $url"
  # Opening one is reading it. Anything else means a headline you clicked is
  # still starred when you come back, which is the one thing a star must never
  # do.
  news_mark_read "$url"

  # Detached, because the follow has to outlive this process: the window's
  # helper must not sit waiting for a browser to start.
  setsid -f bash -c '
    url=$1; shift
    xdg-open "$url" >/dev/null 2>&1
    # The window may not exist yet — if the browser was not running, xdg-open
    # has only just started it. So the focus is retried rather than attempted
    # once, and it gives up quietly: a browser that never appears is not
    # something to pop an error about over someone else'"'"'s desktop.
    for _ in $(seq 1 25); do
      for pattern in "$@"; do
        [[ -n $pattern ]] || continue
        if omarchy-hyprland-focus-app "$pattern" 2>/dev/null; then exit 0; fi
      done
      sleep 0.2
    done
  ' bash "$url" $(news_browser_patterns) >/dev/null 2>&1
}

# What to look for in the window list, most specific first.
#
# The desktop id is the better key: `brave-browser.desktop` is the window class
# `brave-browser`, and `google-chrome.desktop` is `google-chrome`, while the
# friendly names Omarchy prints ("brave", "chrome") are only substrings of
# those. Both are offered because they disagree for at least one browser —
# `brave-origin.desktop` runs under the ordinary Brave class.
news_browser_patterns() {
  local desktop friendly
  desktop=$(capture env -u BROWSER xdg-settings get default-web-browser)
  friendly=$(capture omarchy-default-browser | head -n1)
  printf '%s %s' "${desktop%.desktop}" "${friendly%%-*}"
}

news_cmd() {
  case ${1:-state} in
    # What is on disk, whatever its age. This is what the page polls.
    state|poll) news_cached ;;
    # Asked for by the page, once, and only when the cache has aged out.
    fetch) news_fetch ;;
    refresh) news_fetch --force ;;
    stale) news_stale && echo true || echo false ;;
    read) shift; [[ -n ${1:-} ]] || die "usage: omacontrol news read <url>"
      news_mark_read "$1" ;;
    unread) shift; [[ -n ${1:-} ]] || die "usage: omacontrol news unread <url>"
      news_mark_unread "$1" ;;
    read-all) news_mark_all_read ;;
    open) shift; [[ -n ${1:-} ]] || die "usage: omacontrol news open <url>"
      news_open "$1" ;;
    *) die "usage: omacontrol news poll|fetch|stale|read <url>|unread <url>|read-all|open <url>" ;;
  esac
}
