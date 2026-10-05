#!/bin/bash
# claude-sidebar-sync.sh (macOS): one Code tab session list for both Claude accounts in the Claude desktop app.
#
# Why: the app keeps the Code tab session list per account and org in
# ~/Library/Application Support/Claude/claude-code-sessions/<account uuid>/<org uuid>/ (one local_<id>.json per
# session). The transcripts live once in ~/.claude/projects, so a switch of account only switches the list.
# This script copies the other account folders' entries into one shared folder and replaces those folders with
# symlinks to it. Same idea as scripts/windows/claude-sidebar-sync.ps1 on Windows. Unofficial, an app update may change it.
#
# Default: report only, changes nothing.
#   --apply          back up, merge, rename each other real folder to <org>.pre-merge-<time>, link it, save config.
#                    Run by Claude inside the app, it keeps the signed-in account's folder as the shared one and refuses
#                    only when that folder would be replaced. From a plain terminal (the signed-in account is unknown)
#                    it refuses while the Claude app runs. --force skips both checks.
#   --heal           for the LaunchAgent. Silent when healthy. Relinks a folder an app update put back (at most 3 repairs
#                    a day). Anything else writes ALERT-claude-sidebar-sync.txt in the data folder and changes nothing.
#   --rollback       remove the links (rm on the link itself), restore each original list, turn --heal off.
#   --install-agent  load LaunchAgent local.claude-sidebar-sync (every 600 s and at login) running --heal.
#   --remove-agent   unload it and delete its plist.
# Options: --primary <account>/<org>, --root <sessions dir>, --data <data dir> (default ~/ClaudeSharedSidebar).
# Never remove one of these links with "rm -rf <link>/": the trailing slash follows the link into the shared folder.

set -u
MODE=report
PRIMARY=""
FORCE=0
ROOT="$HOME/Library/Application Support/Claude/claude-code-sessions"
DATA="$HOME/ClaudeSharedSidebar"
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) MODE=apply ;;
    --heal) MODE=heal ;;
    --rollback) MODE=rollback ;;
    --install-agent) MODE=install ;;
    --remove-agent) MODE=remove ;;
    --force) FORCE=1 ;;
    --primary) PRIMARY="$2"; shift ;;
    --root) ROOT="$2"; shift ;;
    --data) DATA="$2"; shift ;;
    *) echo "usage: $0 [--apply|--heal|--rollback|--install-agent|--remove-agent] [--primary account/org] [--root dir] [--data dir] [--force]"; exit 2 ;;
  esac
  shift
done
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
LOG="$DATA/logs/claude-sidebar-sync.log"
ALERT="$DATA/ALERT-claude-sidebar-sync.txt"
CONF="$DATA/config"
LABEL=local.claude-sidebar-sync
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STAMP=$(date +%Y%m%d-%H%M%S)
MAX_REPAIRS=3
STALE_DAYS=14
UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

log() {
  line="$(date '+%Y-%m-%d %H:%M:%S') $1 $2"
  case "$MODE" in apply|heal|rollback) mkdir -p "$(dirname "$LOG")"; echo "$line" >> "$LOG" ;; esac
  [ "$MODE" = heal ] || echo "$line"
}
alert() {
  log ALERT "$1"
  case "$MODE" in apply|heal|rollback)
    mkdir -p "$DATA"
    printf '%s claude-sidebar-sync stopped without changing anything.\n%s\n\nSee the state: bash %s\nLog: %s\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$SELF" "$LOG" > "$ALERT" ;;
  esac
}
clear_alert() {
  if [ "$MODE" != report ] && [ -f "$ALERT" ]; then rm -f "$ALERT"; log INFO "healthy again, alert file cleared"; fi
}
state_of() { if [ -L "$1" ]; then echo link; elif [ -d "$1" ]; then echo folder; else echo missing; fi; }
sessions_in() { ls "$1" 2>/dev/null | grep -c '^local_.*\.json$'; }
lower() { echo "$1" | tr 'A-F' 'a-f'; }
has_word() { case " $1 " in *" $2 "*) return 0 ;; esac; return 1; }

# merge FROM TO WRITE(1|0): copies local_*.json and deleted_* that TO lacks or holds older. Prints "copied newer same".
merge() {
  copied=0; newer=0; same=0
  for f in "$1"/local_*.json "$1"/deleted_*; do
    [ -e "$f" ] || continue
    dest="$2/$(basename "$f")"
    if [ ! -e "$dest" ]; then
      [ "$3" = 1 ] && cp -p "$f" "$dest"; copied=$((copied + 1))
    elif [ "$f" -nt "$dest" ]; then
      [ "$3" = 1 ] && cp -p "$f" "$dest"; copied=$((copied + 1)); newer=$((newer + 1))
    else
      same=$((same + 1))
    fi
  done
  echo "$copied $newer $same"
}
backup() {
  dest="$DATA/backups/$STAMP/$2"
  mkdir -p "$(dirname "$dest")"
  cp -Rp "$1" "$dest"
  log INFO "backup $2 -> $dest ($(find "$dest" -type f | wc -l | tr -d ' ') files)"
}
link_combo() {
  if [ "$2" = folder ]; then
    aside="$1.pre-merge-$STAMP"; n=2
    while [ -e "$aside" ]; do aside="$1.pre-merge-$STAMP-$n"; n=$((n + 1)); done
    mv "$1" "$aside"; log INFO "renamed $1 -> $(basename "$aside")"
  fi
  mkdir -p "$(dirname "$1")"
  ln -s "$3" "$1"; log INFO "symlink $1 -> $3"
}
unlink_combo() {
  rm "$1"; log INFO "link removed $1"
  # Oldest first: the first pre-merge folder is the original list, later ones come from --heal repairs.
  first=""
  for a in "$1".pre-merge-*; do
    [ -d "$a" ] || continue
    if [ -z "$first" ]; then first="$a"; mv "$a" "$1"; log INFO "restored $(basename "$a")"
    else r=$(merge "$a" "$1" 1); log INFO "merged ${r%% *} entries from $(basename "$a") back"; fi
  done
}
repairs_today() {
  [ -f "$LOG" ] || { echo 0; return; }
  since=$(( $(date +%s) - 86400 )); n=0
  while IFS= read -r line; do
    case "$line" in *" REPAIR "*)
      t=$(date -j -f '%Y-%m-%d %H:%M:%S' "$(echo "$line" | cut -c1-19)" +%s 2>/dev/null || echo 0)
      [ "$t" -gt "$since" ] && n=$((n + 1)) ;;
    esac
  done < "$LOG"
  echo "$n"
}

# ---- LaunchAgent ----
if [ "$MODE" = install ]; then
  mkdir -p "$HOME/Library/LaunchAgents" "$DATA/logs"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$SELF</string><string>--heal</string></array>
  <key>StartInterval</key><integer>600</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>$DATA/logs/launchd.err</string>
</dict></plist>
EOF
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
  launchctl bootstrap "gui/$(id -u)" "$PLIST" && echo "LaunchAgent $LABEL loaded from $PLIST"
  exit $?
fi
if [ "$MODE" = remove ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null; rm -f "$PLIST"; echo "LaunchAgent $LABEL removed"; exit 0
fi

# ---- config and root ----
CFG_PRIMARY=""; CFG_ACCOUNTS=""; CFG_ORGS=""; CFG_DISABLED=0
[ -f "$CONF" ] && . "$CONF"
if [ "$MODE" = heal ]; then
  [ -f "$CONF" ] || { alert "Not set up yet: no $CONF. Run --apply first."; exit 1; }
  [ "$CFG_DISABLED" = 1 ] && exit 0
fi
[ -d "$ROOT" ] || { alert "No claude-code-sessions folder at $ROOT (app missing, reinstalled or its storage changed)."; exit 1; }
# Inside a Claude desktop session the app passes its signed-in account, so the script knows which folder is in use.
ACTIVE=""
if [ -n "${CLAUDE_CODE_ACCOUNT_UUID:-}" ] && [ -n "${CLAUDE_CODE_ORGANIZATION_UUID:-}" ]; then
  ACTIVE="$(lower "$CLAUDE_CODE_ACCOUNT_UUID")/$(lower "$CLAUDE_CODE_ORGANIZATION_UUID")"
fi

# ---- rollback ----
if [ "$MODE" = rollback ]; then
  for a in "$ROOT"/*/; do for o in "$a"*; do
    [[ $(basename "$o") =~ $UUID_RE ]] || continue
    [ -L "$o" ] && unlink_combo "${o%/}"
  done; done
  [ -f "$CONF" ] && sed -i '' 's/^CFG_DISABLED=.*/CFG_DISABLED=1/' "$CONF"
  log INFO "rollback done, --heal is off, copied entries stay in the shared folder. Also run --remove-agent."
  exit 0
fi

# ---- accounts, orgs, shared folder ----
FOUND=""
for a in "$ROOT"/*/; do n=$(basename "$a"); [[ $n =~ $UUID_RE ]] && FOUND="$FOUND $(lower "$n")"; done
FOUND="${FOUND# }"
ACCOUNTS="$FOUND"
[ "$MODE" != apply ] && [ -n "$CFG_ACCOUNTS" ] && ACCOUNTS="$CFG_ACCOUNTS"
[ -z "$PRIMARY" ] && [ "$MODE" != apply ] && PRIMARY="$CFG_PRIMARY"
ORGS=""; BEST=""; BESTN=-1
for a in $ACCOUNTS; do
  for o in "$ROOT/$a"/*; do
    on=$(basename "$o"); [[ $on =~ $UUID_RE ]] || continue
    on=$(lower "$on"); has_word "$ORGS" "$on" || ORGS="$ORGS $on"
    if [ "$(state_of "$o")" = folder ]; then c=$(sessions_in "$o"); [ "$c" -gt "$BESTN" ] && BESTN=$c && BEST="$a/$on"; fi
  done
done
if [ -z "$PRIMARY" ] && [ -n "$ACTIVE" ] && [ "$(state_of "$ROOT/$ACTIVE")" = folder ] && [ "$(sessions_in "$ROOT/$ACTIVE")" -gt 0 ]; then
  PRIMARY="$ACTIVE"
fi
[ -z "$PRIMARY" ] && PRIMARY="$BEST"
[ -z "$PRIMARY" ] && { alert "No account folder with sessions found. Sign in to each account in the app once."; exit 1; }
PA=$(lower "${PRIMARY%%/*}"); PO=$(lower "${PRIMARY#*/}")
has_word "$ORGS" "$PO" || ORGS="$ORGS $PO"
[ "$MODE" != apply ] && for o in $CFG_ORGS; do has_word "$ORGS" "$o" || ORGS="$ORGS $o"; done
ORGS="${ORGS# }"
SHARED="$ROOT/$PA/$PO"
TODO=""; FOREIGN=""; NEWORGS=""
for a in $ACCOUNTS; do
  for o in $ORGS; do
    [ "$a" = "$PA" ] && [ "$o" = "$PO" ] && continue
    p="$ROOT/$a/$o"; s=$(state_of "$p")
    if [ "$s" = link ]; then [ "$(readlink "$p")" = "$SHARED" ] || FOREIGN="$FOREIGN $a/$o"
    else TODO="$TODO $a/$o"; fi
  done
done
if [ "$MODE" = heal ]; then for o in $ORGS; do has_word "$CFG_ORGS" "$o" || NEWORGS="$NEWORGS $o"; done; fi

# ---- report (default) ----
if [ "$MODE" = report ]; then
  echo "Sessions root: $ROOT"
  echo "Account folders found: $FOUND"
  set -- $FOUND; [ $# -gt 2 ] && echo "More than 2 accounts found. Pass --primary and remove the extra account folder from the plan by hand."
  if [ -n "$ACTIVE" ]; then echo "The app is signed in to: $ACTIVE"
  elif pgrep -xq Claude; then echo "The Claude app is running: quit it before --apply."
  else echo "The Claude app is not running."; fi
  echo "Shared folder: $PA/$PO ($(state_of "$SHARED"), $(sessions_in "$SHARED") sessions)"
  for a in $ACCOUNTS; do for o in $ORGS; do
    [ "$a" = "$PA" ] && [ "$o" = "$PO" ] && continue
    p="$ROOT/$a/$o"; s=$(state_of "$p"); echo "  $a/$o: $s"
    case "$s" in
      link) echo "    -> $(readlink "$p")" ;;
      folder) r=$(merge "$p" "$SHARED" 0); set -- $r; echo "    --apply would copy $1 entries ($2 newer copies), $3 already there, then link it" ;;
      missing) echo "    --apply would create the symlink" ;;
    esac
  done; done
  [ -n "$FOREIGN" ] && echo "A link points somewhere else:$FOREIGN. --apply and --heal stop on it."
  [ -z "$TODO" ] && [ -z "$FOREIGN" ] && [ "$(state_of "$SHARED")" = folder ] && echo "Healthy: every account folder is a symlink to the shared folder."
  echo "Nothing changed. --apply merges and links, --heal is the scheduled repair, --rollback removes the links."
  exit 0
fi

# ---- checks ----
set -- $FOUND
if [ "$MODE" = apply ] && [ $# -gt 2 ]; then alert "More than 2 account folders found ($FOUND). Not supported by this script."; exit 1; fi
[ "$(state_of "$SHARED")" = folder ] || { alert "The shared folder $SHARED is $(state_of "$SHARED"), expected a real folder."; exit 1; }
[ "$(sessions_in "$SHARED")" -gt 0 ] || { alert "The shared folder holds no local_*.json entries. The app may have changed its storage."; exit 1; }
[ -n "$FOREIGN" ] && { alert "A link does not point at the shared folder:$FOREIGN"; exit 1; }
[ -n "$NEWORGS" ] && { alert "New org folder(s) since --apply:$NEWORGS. Run --apply again to include them."; exit 1; }
if [ "$MODE" = apply ] && [ "$FORCE" = 0 ]; then
  if [ -n "$ACTIVE" ]; then
    if [ "$ACTIVE" != "$PA/$PO" ] && has_word "$TODO" "$ACTIVE" && [ "$(state_of "$ROOT/$ACTIVE")" = folder ]; then
      alert "The app is signed in to $ACTIVE, whose folder would be replaced. Switch the app to the shared account ($PA/$PO), or quit it and run this from Terminal."; exit 1
    fi
  elif pgrep -xq Claude; then
    alert "The Claude app is running. Quit it (Cmd+Q), then run --apply again."; exit 1
  fi
fi
if [ -z "$TODO" ]; then
  if [ "$MODE" = heal ]; then
    newest=$(ls -t "$SHARED"/local_*.json 2>/dev/null | head -1)
    if [ -n "$newest" ] && [ $(( ( $(date +%s) - $(stat -f %m "$newest") ) / 86400 )) -ge $STALE_DAYS ]; then
      alert "Links are fine, but no session entry was written for $STALE_DAYS days. The app may store sessions elsewhere now."; exit 1
    fi
  fi
  if [ "$MODE" = apply ]; then
    printf "CFG_PRIMARY='%s'\nCFG_ACCOUNTS='%s'\nCFG_ORGS='%s'\nCFG_DISABLED=0\n" "$PA/$PO" "$ACCOUNTS" "$ORGS" > "$CONF"
    log INFO "already linked, saved config, nothing else to do"
  fi
  clear_alert; exit 0
fi
if [ "$MODE" = heal ] && [ "$(repairs_today)" -ge $MAX_REPAIRS ]; then
  alert "$MAX_REPAIRS repairs in the last 24 hours. The app keeps replacing the link, so the script stopped repairing."; exit 1
fi

# ---- apply / heal ----
mkdir -p "$DATA"
backup "$SHARED" "$PA/$PO"
for k in $TODO; do [ "$(state_of "$ROOT/$k")" = folder ] && backup "$ROOT/$k" "$k"; done
for k in $TODO; do
  p="$ROOT/$k"; s=$(state_of "$p")
  if [ "$s" = folder ]; then r=$(merge "$p" "$SHARED" 1); set -- $r; log INFO "merged $1 entries from $p ($2 newer copies, $3 already there)"; fi
  link_combo "$p" "$s" "$SHARED"
  [ "$MODE" = heal ] && log REPAIR "relinked $p"
done
[ "$MODE" = apply ] && printf "CFG_PRIMARY='%s'\nCFG_ACCOUNTS='%s'\nCFG_ORGS='%s'\nCFG_DISABLED=0\n" "$PA/$PO" "$ACCOUNTS" "$ORGS" > "$CONF"

# ---- verify ----
total=$(sessions_in "$SHARED")
for k in $TODO; do
  p="$ROOT/$k"
  if [ "$(state_of "$p")" != link ] || [ "$(readlink "$p")" != "$SHARED" ] || [ "$(sessions_in "$p/")" != "$total" ]; then
    alert "Verification failed for $p."; exit 1
  fi
done
clear_alert
log INFO "done: $total session entries, shared by every account folder"
