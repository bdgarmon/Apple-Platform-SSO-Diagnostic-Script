#!/bin/zsh
# pssodiagv300.zsh v3.0.0
# Options:
#   -y, --yes               skip the confirmation prompt
#   -n, --dry-run           print the plan and exit; collect nothing
#       --log-window <N>    unified-log lookback, e.g. 90m, 6h, 1d  (default 1d)
#       --hub-duration <N>  hubcli log duration, e.g. 1h, 1d         (default 1d)
#       --skip-sysdiagnose  skip the (slow) sysdiagnose step
#       --tests-only        fast mode: no sysdiagnose, no hubcli archive, 3h log window (run it right after a failed attempt)
#       --no-browser-test   skip the background Safari navigation test
#       --output-dir <path> folder for the finished .zip (default: the folder this script is in)
#       --test-url <url>    also test whether this URL is handed to the SSO extension (repeatable, max 10)
#       --kerberos-url <url> Kerberos web test: curl --negotiate as the logged-in user, then check klist (repeatable, max 3)
#       --debug-logging <on|off> turn AppSSO debug log persistence on or off (asks first), then exit; no collection
#       --open-fda-settings open System Settings > Full Disk Access, print the steps, exit
#   -h, --help

SCRIPT_VERSION="3.0.0"
SCRIPT_PATH=${0:A}
SCRIPT_DIR=${SCRIPT_PATH:h}
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

LOG_WINDOW="1d"
HUB_DURATION="1d"
ASSUME_YES=0
DRY_RUN=0
SKIP_SYSDIAG=0
OPEN_FDA=0
NO_BROWSER=0
OUT_DIR_ARG=""
TESTS_ONLY=0
LOG_WINDOW_SET=0
typeset -a TEST_URLS; TEST_URLS=()
typeset -a KERBEROS_URLS; KERBEROS_URLS=()
DEBUG_LOGGING_ARG=""
HUBCLI="/usr/local/bin/hubcli"      # documented install path for hubcli
typeset -a PROBLEMS NOTES
HUB_BUNDLES=(com.ws1.hub.mac com.airwatch.mac.agent)   # current and older Hub app bundle IDs

usage() { /usr/bin/awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$SCRIPT_PATH"; }

# ---------- argument parsing -------------------------------------------------
while (( $# )); do
  case "$1" in
    -y|--yes)            ASSUME_YES=1 ;;
    -n|--dry-run)        DRY_RUN=1 ;;
    --log-window)        LOG_WINDOW="${2:-}"; LOG_WINDOW_SET=1; shift ;;
    --hub-duration)      HUB_DURATION="${2:-}"; shift ;;
    --skip-sysdiagnose)  SKIP_SYSDIAG=1 ;;
    --tests-only)        TESTS_ONLY=1; SKIP_SYSDIAG=1 ;;
    --no-browser-test)   NO_BROWSER=1 ;;
    --output-dir)        [[ -n "${2:-}" ]] || { print -u2 "--output-dir needs a folder path"; exit 2; }; OUT_DIR_ARG="$2"; shift ;;
    --test-url)          [[ -n "${2:-}" ]] || { print -u2 "--test-url needs an http(s) URL"; exit 2; }; TEST_URLS+=("$2"); shift ;;
    --kerberos-url)      [[ -n "${2:-}" ]] || { print -u2 "--kerberos-url needs an http(s) URL"; exit 2; }; KERBEROS_URLS+=("$2"); shift ;;
    --debug-logging)     [[ "${2:-}" == on || "${2:-}" == off ]] || { print -u2 "--debug-logging needs on or off"; exit 2; }; DEBUG_LOGGING_ARG="$2"; shift ;;
    --open-fda-settings) OPEN_FDA=1 ;;
    -h|--help)           usage; exit 0 ;;
    *) print -u2 "Unknown option: $1"; usage; exit 2 ;;
  esac
  shift
done

# --tests-only: a short log window unless --log-window was given
MODE_PLAN=""; MODE_README=""
if (( TESTS_ONLY )); then
  (( ! LOG_WINDOW_SET )) && LOG_WINDOW="3h"
  MODE_PLAN="  Mode                 : --tests-only (no sysdiagnose, no hubcli archive; unified-log window $LOG_WINDOW)"
  MODE_README="Run mode: --tests-only (no sysdiagnose, no hubcli archive)"
fi

# --test-url: at most 10, each an http(s) URL without spaces
if (( ${#TEST_URLS[@]} > 10 )); then print -u2 "--test-url: at most 10 URLs"; exit 2; fi
TEST_URL_PLAN=""
for u in "${TEST_URLS[@]}"; do
  [[ "$u" =~ ^https?://[^[:space:]]+$ ]] || { print -u2 "--test-url needs an http:// or https:// URL without spaces: $u"; exit 2; }
  TEST_URL_PLAN+="$u "
done
[[ -n "$TEST_URL_PLAN" ]] && TEST_URL_PLAN="     + ${#TEST_URLS[@]} URL(s) you asked to test (--test-url): ${TEST_URL_PLAN% }"
KERB_PLAN=""
if (( ${#KERBEROS_URLS[@]} > 3 )); then print -u2 "--kerberos-url: at most 3 URLs"; exit 2; fi
for u in "${KERBEROS_URLS[@]}"; do
  [[ "$u" =~ ^https?://[^[:space:]]+$ ]] || { print -u2 "--kerberos-url needs an http:// or https:// URL without spaces: $u"; exit 2; }
  KERB_PLAN+="$u "
done
[[ -n "$KERB_PLAN" ]] && KERB_PLAN="     + ${#KERBEROS_URLS[@]} Kerberos web test URL(s) (--kerberos-url): ${KERB_PLAN% }"

# where the finished .zip goes: the folder this script is in, unless --output-dir says otherwise
OUT_DIR="$SCRIPT_DIR"; OUT_DIR_SRC="default: the folder this script is in"; OUT_DIR_NOTE=""
if [[ -n "$OUT_DIR_ARG" ]]; then OUT_DIR="${OUT_DIR_ARG:A}"; OUT_DIR_SRC="--output-dir"; fi

[[ "$LOG_WINDOW"    =~ '^[0-9]+[smhd]$' ]] || { print -u2 "Bad --log-window: '$LOG_WINDOW' (use e.g. 90m, 6h, 1d)"; exit 2; }
[[ "$HUB_DURATION"  =~ '^[0-9]+[smhd]$' ]] || { print -u2 "Bad --hub-duration: '$HUB_DURATION' (use e.g. 1h, 1d)"; exit 2; }
[[ "$(uname)" == "Darwin" ]] || { print -u2 "This script only runs on macOS."; exit 2; }

if (( EUID != 0 )); then
  print -u2 "This script must run as root (sysdiagnose requires it). Re-run with:"
  print -u2 "    sudo ${(q)SCRIPT_PATH}"
  exit 2
fi

# ---------- who is at the desktop? (PSSO state is per-user) -------------------
CONSOLE_USER=$(/usr/bin/stat -f%Su /dev/console 2>/dev/null)
if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" || "$CONSOLE_USER" == "loginwindow" ]]; then
  CONSOLE_USER="${SUDO_USER:-}"
fi
if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" ]] && /usr/bin/id -u "$CONSOLE_USER" >/dev/null 2>&1; then
  CONSOLE_UID=$(/usr/bin/id -u "$CONSOLE_USER")
  USER_HOME=$(/usr/bin/dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')
else
  CONSOLE_USER=""; CONSOLE_UID=""; USER_HOME=""
fi

OS_VER=$(/usr/bin/sw_vers -productVersion 2>/dev/null)

# Full Disk Access probe: the system TCC.db is unreadable (even as root) without Full Disk Access.
fda_granted() {   # 0 = this terminal has Full Disk Access (also 0 if the probe file does not exist)
  local f="${FDA_PROBE_FILE:-/Library/Application Support/com.apple.TCC/TCC.db}"
  [[ -e "$f" ]] || return 0
  /usr/bin/head -c1 "$f" >/dev/null 2>&1
}

fda_status() {
  if fda_granted; then print "granted to this terminal"; else print "NOT granted (a real run stops before collecting anything)"; fi
}

fda_required_message() {
  print "
FULL DISK ACCESS IS REQUIRED - ${SCRIPT_PATH:t} cannot continue.

This terminal does not have Full Disk Access, and the script needs it to read protected
files. Nothing was collected and nothing on this Mac was changed.

To grant it:
  1. Open System Settings > Privacy & Security > Full Disk Access.
     (To open that pane for you, run:  sudo ./${SCRIPT_PATH:t} --open-fda-settings)
  2. Switch ON the terminal app you are using (Terminal, iTerm, ...).
     Use the + button to add it if it is not listed.
  3. Authenticate with an administrator account when macOS asks.
  4. Quit the terminal app completely (Command-Q) and open it again. macOS only applies
     the permission to terminals that are started afterwards.
  5. Run the script again.
"
}

prepare_output_dir() {   # make sure the finished .zip can be written; stop early if not
  local t
  if [[ ! -d "$OUT_DIR" ]]; then
    if (( DRY_RUN )); then OUT_DIR_NOTE=" (does not exist yet - it will be created)"; return 0; fi
    if ! /bin/mkdir -p "$OUT_DIR" 2>/dev/null; then
      print -u2 "Cannot create the output folder: $OUT_DIR"
      print -u2 "Choose another folder with --output-dir <path>."
      exit 2
    fi
    [[ -n "$CONSOLE_USER" ]] && /usr/sbin/chown "$CONSOLE_USER" "$OUT_DIR" 2>/dev/null
  fi
  t="$OUT_DIR/.psso-write-test.$$"
  if ! ( : > "$t" ) 2>/dev/null; then
    print -u2 "The output folder is not writable: $OUT_DIR"
    print -u2 "Choose a writable folder with --output-dir <path>."
    exit 2
  fi
  /bin/rm -f "$t"
}

LOGBIN=/usr/bin/log

debug_logging_action() {   # --debug-logging on|off : changes the macOS log setting for com.apple.AppSSO only, after confirmation
  local mode="$1" shown rc
  if [[ "$mode" == on ]]; then shown='log config --mode "level:debug,persist:debug" --subsystem "com.apple.AppSSO"'
  else shown='log config --reset --subsystem "com.apple.AppSSO"'; fi
  print ""
  print "This changes the macOS log setting for ONE subsystem (com.apple.AppSSO) on this Mac:"
  print "    sudo ${shown}"
  if [[ "$mode" == on ]]; then
    print "Debug messages for AppSSO are then kept on disk, which uses more space. Reproduce the problem, run this"
    print "script again, and then turn it off again with: sudo ./${SCRIPT_PATH:t} --debug-logging off"
    print "For the Microsoft extension, Microsoft also suggests Company Portal > Settings > 'Turn on advanced logging'."
  else
    print "This puts AppSSO logging back to the macOS default."
  fi
  if (( DRY_RUN )); then print "Dry run only - nothing changed."; return 0; fi
  if (( ! ASSUME_YES )); then
    read -r "?Proceed? [y/N] "
    [[ "$REPLY" == [yY]* ]] || { print "Aborted."; return 0; }
  fi
  if [[ "$mode" == on ]]; then "$LOGBIN" config --mode "level:debug,persist:debug" --subsystem "com.apple.AppSSO"
  else "$LOGBIN" config --reset --subsystem "com.apple.AppSSO"; fi
  rc=$?
  print "Exit code: ${rc}"
  print "Current setting:"
  "$LOGBIN" config --status --subsystem com.apple.AppSSO
  return $rc
}

open_fda_settings() {
  print "Opening System Settings > Privacy & Security > Full Disk Access for ${CONSOLE_USER:-the logged-in user} ..."
  if [[ -n "$CONSOLE_UID" ]]; then
    /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" /usr/bin/open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null \
      || /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" /usr/bin/open -b com.apple.systempreferences
  else
    print "No console user - open System Settings manually."
  fi
  print "
macOS cannot prompt for Full Disk Access and no script can enable it. Do this by hand:
  1. In Full Disk Access, switch ON 'Terminal' (use + to add /System/Applications/Utilities/Terminal.app if missing).
  2. Authenticate with an administrator account when asked.
  3. Choose 'Quit & Reopen' for Terminal, then re-run:  sudo ./${SCRIPT_PATH:t}
Only the Company Portal extension log folder needs this; everything else is collected without it.
(Fleet-wide alternative: an MDM Privacy Preferences Policy Control profile - see the DRAFT .mobileconfig.)"
}
if (( OPEN_FDA )); then open_fda_settings; exit 0; fi
if [[ -n "$DEBUG_LOGGING_ARG" ]]; then debug_logging_action "$DEBUG_LOGGING_ARG"; exit $?; fi
if (( ! DRY_RUN )) && ! fda_granted; then fda_required_message; exit 3; fi
prepare_output_dir
OS_MAJOR=${OS_VER%%.*}

# ---------- plan + confirmation ----------------------------------------------
print "
PSSO + Hub log collector v$SCRIPT_VERSION
  macOS version        : $OS_VER $( [[ "$OS_MAJOR" == 26 || "$OS_MAJOR" == 27 ]] || print '(WARNING: only 26/27 are targeted)')
  Console (GUI) user   : ${CONSOLE_USER:-<none - user-context checks will be SKIPPED>}
  Output zip location  : $OUT_DIR  [$OUT_DIR_SRC]$OUT_DIR_NOTE
  Unified-log window   : $LOG_WINDOW        Hub log duration: $HUB_DURATION
  Full Disk Access     : $(fda_status)

Plan (read-only, except sysdiagnose / hubcli archive):
  1. sysdiagnose                                   ($( (( SKIP_SYSDIAG )) && print 'SKIPPED' || print 'several minutes; waits if another sysdiagnose is running'))
  2. app-sso platform -s, app-sso -l, pluginkit    (run as $CONSOLE_USER)
  3. profiles/MDM evidence for the PSSO payload    (secrets best-effort redacted)
  4. unified-log slices for PSSO registration attempts + IdP extension logs
  5. $( (( TESTS_ONLY )) && print 'Hub unified log only (hubcli archive skipped by --tests-only)' || print 'Intelligent Hub logs via hubcli + Hub unified log')
  6. automated validation tests: state checks, IdP endpoints, associated domains (swcutil, AASA, Apple CDN),
     time skew, running web-filter/VPN/proxy agents, the Microsoft sign-in endpoint redirect probe, and a
     background Safari navigation test for each SSO payload URL and each --test-url URL
     (skip the browser part: --no-browser-test)
     plus Okta, Kerberos, leftover-state and AppSSO debug-logging checks where they apply
  7. package everything into one .zip
"
[[ -n "$MODE_PLAN" ]] && print -r -- "$MODE_PLAN"
[[ -n "$TEST_URL_PLAN" ]] && print -r -- "$TEST_URL_PLAN"
[[ -n "$KERB_PLAN" ]] && print -r -- "$KERB_PLAN"
if (( DRY_RUN )); then print "Dry run only - nothing collected."; exit 0; fi
if (( ! ASSUME_YES )); then
  print -n "Proceed? [y/N] "
  read -r REPLY </dev/tty
  [[ "$REPLY" == [yY]* ]] || { print "Aborted."; exit 0; }
fi

# ---------- staging -----------------------------------------------------------
HOST=$(/usr/sbin/scutil --get LocalHostName 2>/dev/null || /bin/hostname -s)
HOST=${HOST//[^A-Za-z0-9_-]/_}
TS=$(/bin/date +%Y%m%d-%H%M%S)
BUNDLE="PSSO-Diag-${HOST}-${TS}"
STAGE=$(/usr/bin/mktemp -d /private/var/tmp/psso-collect.XXXXXX) || { print -u2 "mktemp failed"; exit 1; }
WORK="$STAGE/$BUNDLE"
D0="$STAGE/system-parts";        D1="$WORK/01-sysdiagnose"
D2="$WORK/02-psso-state";        D3="$WORK/03-mdm-payload"
D4="$WORK/04-psso-registration-logs"; D5="$WORK/05-hub-logs"; D6="$WORK/06-validation"
/bin/mkdir -p "$D0" "$D1" "$D2" "$D3" "$D4" "$D5" "$D6"
trap '/bin/rm -rf "$STAGE"' EXIT
trap '/bin/rm -rf "$STAGE"; exit 130' INT TERM

CLOG="$WORK/collector.log"
log()     { print -r -- "[$(/bin/date '+%m-%d-%Y %H:%M:%S %Z')] $*" | /usr/bin/tee -a "$CLOG"; }
problem() { PROBLEMS+=("$*"); log "PROBLEM: $*"; }
note()    { NOTES+=("$*");    log "NOTE: $*"; }
note_quiet() { NOTES+=("$*"); print -r -- "[$(/bin/date '+%m-%d-%Y %H:%M:%S %Z')] NOTE: $*" >> "$CLOG"; }   # for use inside the findings block

# capture <outfile> <command...>  - run as root, keep stdout+stderr+exit code
capture() {
  local out="$1"; shift
  local rc
  {
    print -r -- "# command : ${(j: :)${(q)@}}"
    print -r -- "# started : $(/bin/date '+%m-%d-%Y %H:%M:%S %Z')"
    print -r -- "# ------------------------------------------------------------"
  } > "$out"
  "$@" >> "$out" 2>&1
  rc=$?
  print -r -- "# ---- exit code: $rc" >> "$out"
  log "  [rc=$rc] ${out:t}"
  return $rc
}

# run a command inside the console user's GUI session
run_as_user() {
  /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" -H /usr/bin/env "PATH=$PATH" "$@"
}
capture_user() {
  local out="$1"; shift
  if [[ -z "$CONSOLE_USER" ]]; then
    print -r -- "# SKIPPED: no console user (log in at the desktop and re-run)" > "$out"
    problem "user-context command skipped (no console user): ${out:t}"
    return 1
  fi
  capture "$out" run_as_user "$@"
}

copy_if_exists() {   # copy_if_exists <src> <dest-dir>
  local src="$1" dst="$2" err
  if [[ -e "$src" ]]; then
    /bin/mkdir -p "$dst"
    if err=$(/usr/bin/ditto "$src" "$dst/${src:t}" 2>&1); then
      log "  copied: $src"
    elif [[ "$err" == *"Operation not permitted"* ]]; then
      note "blocked by macOS privacy protection, not collected: $src (macOS blocked it even though this terminal has Full Disk Access - it is per-app data protection)"
    else
      problem "could not copy $src: $err"
    fi
  else
    log "  not present: $src"
  fi
}

# Best-effort secret redaction for `profiles` output (XML and text formats).
# Redacts values of keys containing: password, passcode, challenge, secret,
# registrationtoken, accesstoken, refreshtoken.  (TokenToUserMapping is kept.)
redact_file() {
  local f="$1" tmp="$1.redacted"
  /usr/bin/awk '
    function sensitive(k) { k=tolower(k); return (k ~ /password|passcode|challenge|secret|registrationtoken|accesstoken|refreshtoken/) }
    {
      line=$0
      if (pending) {
        pending=0
        if (line ~ /^[ \t]*<(string|data)>.*<\/(string|data)>[ \t]*$/) {
          match(line, /^[ \t]*/); indent=substr(line, 1, RLENGTH)
          print indent "<string>[REDACTED]</string>"; next
        }
      }
      if (match(line, /<key>[^<]*<\/key>/)) {
        key=substr(line, RSTART+5, RLENGTH-11)
        if (sensitive(key)) {
          if (line ~ /<\/key>[ \t]*<(string|data)>/) {
            sub(/<\/key>[ \t]*<(string|data)>.*$/, "</key><string>[REDACTED]</string>", line)
            print line; next
          }
          pending=1
        }
        print line; next
      }
      if (match(line, /^[ \t]*"?[A-Za-z0-9_. -]+"?[ \t]*=[ \t]*[^{(]/)) {
        name=line; sub(/[ \t]*=.*$/, "", name); gsub(/^[ \t]*"?|"$/, "", name)
        if (sensitive(name)) sub(/=.*$/, "= \"[REDACTED]\";", line)
      }
      print line
    }' "$f" > "$tmp" && /bin/mv "$tmp" "$f"
}

# Redact device keys / certificate / device context in `app-sso platform -s` output.
redact_appsso() {
  local f="$1"
  /usr/bin/sed -E 's/^([[:space:]]*"[^"]*([Kk]ey[Dd]ata|[Cc]ertificate|deviceContext)[^"]*"[[:space:]]*:[[:space:]]*)"[^"]*"/\1"[REDACTED]"/' "$f" > "$f.redacted" && /bin/mv "$f.redacted" "$f"
}

# app-sso can print "invalid option" yet exit 0, so sniff the output too.
flag_cli_errors() {   # flag_cli_errors <file> <label>
  if /usr/bin/grep -qiE 'invalid option|unrecognized option|unknown option' "$1" 2>/dev/null; then
    problem "$2 rejected an option on this macOS version (see ${1:t})"
  fi
}

# ---- username forensics helpers (zsh/bash compatible) ----
shape() {   # describe the *syntax* of a user string
  local u="$1" s=""
  if [[ "$u" == *@* ]]; then s="has-@ domain=${u##*@}"; else s="NO-@ (no domain part)"; fi
  [[ "$u" == *"\\"* ]] && s+=" has-backslash"
  [[ "$u" == *[[:space:]]* ]] && s+=" has-whitespace"
  [[ "$u" == *[A-Z]* ]] && s+=" has-uppercase"
  [[ "$u" == *'***'* ]] && s+=" (partly masked by macOS)"
  print -r -- "$s len=${#u}"
}

extract_user_strings() {   # <unified-log text file>  ->  "source|value" lines
  /usr/bin/grep -E 'platformSSOEnabledForUsername|activate Platform SSO for user|Platform SSO not configured for user|Activate for user|forUserName:|verifyPasswordLogin|Code=-1004|presenting ui: authenticate' "$1" 2>/dev/null | /usr/bin/sed -nE \
    -e 's/.*platformSSOEnabledForUsername:([^ ]+) .*/coreauthd platformSSOEnabledForUsername|\1/p' \
    -e 's/.*activate Platform SSO for user: ([^ ]+) allowAutoUnlock.*/loginwindow activatePlatformSSOForUser|\1/p' \
    -e 's/.*Platform SSO not configured for user ([^ ,]+),.*/loginwindow PSSO-not-configured|\1/p' \
    -e 's/.*Activate for user ([^ ,]+),.*/PlatformSSOUIAgent activate|\1/p' \
    -e 's/.*forUserName:\] userName = ([^ ]+) on.*/AppSSO savePendingSSOTokens forUserName|\1/p' \
    -e 's/.*verifyPasswordLogin:passwordContext:\] userName = ([^,]+),.*/AppSSO verifyPasswordLogin userName|\1/p' \
    -e 's/.*Code=-1004 "[^"]*" UserInfo=\{[^}]*\}, ([^ ]+)$/AppSSO -1004 config error for user|\1/p' \
    -e 's/.*presenting ui: authenticate\(url: [^,]+, username: "([^"]*)".*/Hub SSO extension authenticate(username:)|\1/p' \
    | /usr/bin/grep -vE '\|-?[0-9]+$|_mbsetupuser'
}

lc() { /usr/bin/tr '[:upper:]' '[:lower:]'; }

# prints the "username" section of QUICK-FINDINGS.  Needs: S (app-sso state file), PL (psso log), D2 (02 dir)
username_findings() {
  local login_un upns u1 l_dom u_dom l_loc u_loc a b n_bur n_vp n_hubun n_any_at ustr
  print "[local macOS account]"
  /usr/bin/grep -vE '^#' "$D2/local-account-dscl.txt" 2>/dev/null | /usr/bin/sed 's/^/    /'
  print ""
  print "[user strings seen by macOS PSSO components in the log window] (exact, as logged; count / source / string / syntax)"
  ustr="$STAGE/user-strings.txt"
  { extract_user_strings "$PL"; extract_user_strings "$HH"; } > "$ustr" 2>/dev/null
  /usr/bin/sort "$ustr" | /usr/bin/uniq -c | /usr/bin/sort -rn | while read -r cnt rest; do
    if [[ -z "${rest#*|}" ]]; then
      print -r -- "    ${cnt}x  ${rest%%|*}: <empty string>"
    else
      print -r -- "    ${cnt}x  ${rest%%|*}: ${rest#*|}   [$(shape "${rest#*|}")]"
    fi
  done
  n_bur=$(/usr/bin/grep -c 'beginUserRegistrationUsingUserName' "$PL" 2>/dev/null)
  print "    beginUserRegistration (the call that receives the typed user name): ${n_bur:-0} log line(s); the user name argument is logged as <private>, so it is NOT recoverable from these logs"
  print ""
  print "[IdP-facing identity strings in app-sso platform -s]"
  login_un=$(/usr/bin/grep -m1 '"loginUserName"' "$S" 2>/dev/null | /usr/bin/sed -E 's/.*: "([^"]*)".*/\1/')
  upns=$(/usr/bin/grep '"upn"' "$S" 2>/dev/null | /usr/bin/sed -E 's/.*: "(.*)"[[:space:]]*$/\1/; s/\\+@/@/; s/@KERBEROS\.[A-Z.]+$//')
  print "    loginUserName: ${login_un:-<not present>}  [$(shape "$login_un")]   (macOS masks the middle of the local part)"
  if [[ -n "$upns" ]]; then
    print -r -- "$upns" | while read -r u; do print "    cloud/Kerberos UPN returned by the IdP: $u  [$(shape "$u")]"; done
  else
    print "    cloud/Kerberos UPN: <none in state - Kerberos mapping not configured or no ticket yet>"
  fi
  if [[ -n "$login_un" && -n "$upns" ]]; then
    u1=$(print -r -- "$upns" | /usr/bin/head -1)
    l_dom=${login_un##*@}; u_dom=${u1##*@}
    l_loc=${login_un%@*};  u_loc=${u1%@*}
    if [[ "$(print -r -- "$l_dom" | lc)" != "$(print -r -- "$u_dom" | lc)" ]]; then
      print "    CHECK: domain differs - loginUserName '@${l_dom}' vs IdP UPN '@${u_dom}'"
    else
      print "    domain matches IdP UPN (@${l_dom})"
    fi
    if [[ "$l_loc" == *'***'* ]]; then
      a=$(print -r -- "${l_loc:0:1}" | lc); b=$(print -r -- "${u_loc:0:1}" | lc)
      if [[ "${l_loc: -1}" != '*' ]]; then
        a+=$(print -r -- "${l_loc: -1}" | lc); b+=$(print -r -- "${u_loc: -1}" | lc)
      fi
      if [[ "$a" != "$b" ]]; then
        print "    CHECK: the visible characters of the loginUserName local part differ from the IdP UPN local part (different account or typo)"
      else
        print "    the visible characters of the local part match the IdP UPN (the full local part cannot be verified - macOS masks it)"
      fi
    fi
  fi
  n_hubun=$(/usr/bin/grep 'Hub SSO extension authenticate' "$ustr" | /usr/bin/grep -vE '\|$' | /usr/bin/grep -vc '@')
  n_any_at=$(/usr/bin/grep -v -e 'verifyPasswordLogin' -e '^Hub SSO extension' "$ustr" | /usr/bin/grep -c '@')
  if (( ${n_hubun:-0} > 0 && ${n_any_at:-0} > 0 )); then
    print "    CHECK: the Hub SSO extension sign-in UI was given a user name WITHOUT @domain ${n_hubun} time(s), while other macOS components use an @domain name for this user."
    print "           If the IdP requires UPN/email, this is the pattern to investigate."
  fi
  n_vp=$(/usr/bin/grep 'verifyPasswordLogin' "$ustr" | /usr/bin/grep -vc '@')
  if [[ "$login_un" == *@* ]] && (( ${n_vp:-0} > 0 )); then
    print "    CHECK: ${n_vp} PSSO password-login attempt(s) were handed a user name WITHOUT @domain while loginUserName has @domain."
    print "           If your IdP requires UPN/email, compare with the local account RecordName entries above."
  fi
}

# ---- helpers: timezone-correct timestamps + Apple-side (IdP-agnostic) registration timeline ----
# Input timestamps come from `log show --style default`, e.g. "2026-10-29 10:52:58-0700" (offset included).
to_epoch_tz() { /bin/date -j -f '%Y-%m-%d %H:%M:%S%z' "$1" '+%s' 2>/dev/null; }

stamp_utc() {   # "YYYY-MM-DD HH:MM:SS+ZZZZ" -> "MM-DD-YYYY HH:MM:SS UTC"
  local e; e=$(to_epoch_tz "$1")
  if [[ -n "$e" ]]; then TZ=UTC /bin/date -r "$e" '+%m-%d-%Y %H:%M:%S UTC'; else print -r -- "$1"; fi
}

apple_registration_timeline() {   # <log show --style default file>
  local ts label tl_tmp
  tl_tmp=$(/usr/bin/mktemp)
  /usr/bin/sed -nE \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*Making pane visible: (PlatformSSO[A-Za-z]+).*/\1\2|Setup Assistant pane shown: \3/p' \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*Did click continue on pane: (PlatformSSO[A-Za-z]+).*/\1\2|Setup Assistant pane continued: \3/p' \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*createOrRepairDeviceConfigurationWithError.*/\1\2|device configuration created or repaired/p' \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*POExtension beginDeviceRegistrationUsingOptions.*/\1\2|device registration started/p' \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*finishRegistrationWithStatus:message:\] success = ([0-9]+).*/\1\2|registration finished (success=\3)/p' \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*Sending nonce request.*/\1\2|PSSO nonce request sent/p' \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*Sending login request.*/\1\2|PSSO login request sent/p' \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*Login Result = ([A-Za-z0-9_]+).*/\1\2|PSSO login result: \3/p' \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*POConfigurationCoreManager savePendingSSOTokens.*/\1\2|SSO tokens saved (pending)/p' \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*POExtension beginUserRegistrationUsingUserName.*/\1\2|user registration started (user name argument is <private>)/p' \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*handleUserRegistrationForUser.*/\1\2|user registration handled/p' \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*Failed to find credential.*/\1\2|NOTE: Setup Assistant logged "Failed to find credential" - read the surrounding lines; this line alone does not show a failure/p' \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*PODaemonProcess removeUserConfigurationForIdentifier.*/\1\2|AppSSO removed the user configuration/p' \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*\[com\.ws1\.hub\.ssoextension:[A-Za-z]+\] beginUserRegistration.*/\1\2|Hub SSO extension: beginUserRegistration/p' \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*\[com\.ws1\.hub\.ssoextension:[A-Za-z]+\] beginDeviceRegistration.*/\1\2|Hub SSO extension: beginDeviceRegistration/p' \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*presenting ui: authenticate\(url: [^,]+, username: ""\).*/\1\2|Hub SSO extension: sign-in UI shown (username argument EMPTY)/p' \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*presenting ui: authenticate\(url: [^,]+, username: "[^"]+".*/\1\2|Hub SSO extension: sign-in UI shown (username argument given - see username section)/p' \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*Beginning registerUser network call.*/\1\2|Hub SSO extension: registerUser network call started/p' \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*Register user endpoint failed.*/\1\2|ERROR: Hub SSO extension - register user endpoint failed (reason logged as <private>)/p' \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*Unhandled registration error: (.*)$/\1\2|ERROR: Hub SSO extension - unhandled registration error: \3/p' \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*\[com\.ws1\.hub\.ssoextension:[A-Za-z]+\] registrationDidComplete.*/\1\2|Hub SSO extension: registrationDidComplete/p' \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*Presenting <NotificationRecord app:"com\.apple\.PlatformSSO\.notifications".*category:"([A-Z_]+)".*/\1\2|Platform SSO PROMPT shown to the user (\3)/p' \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*Received response <NotificationRecord app:"com\.apple\.PlatformSSO\.notifications".*category:"([A-Z_]+)".*/\1\2|Platform SSO prompt: user RESPONDED (\3)/p' \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*Removing displayed <NotificationRecord app:"com\.apple\.PlatformSSO\.notifications".*category:"([A-Z_]+)".*/\1\2|Platform SSO prompt removed from screen (\3)/p' \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*config version changed from from (0x[0-9A-Fa-f]+) to (0x[0-9A-Fa-f]+).*/\1\2|AppSSO configuration version changed (now \4)/p' \
    "$1" 2>/dev/null | /usr/bin/uniq > "$tl_tmp"
  /usr/bin/awk -F'|' '
    NR == FNR {
      if ($2 ~ /^AppSSO configuration version changed/) { k = substr($1,1,15); if (!(k in c)) { first[k] = $1; ord[k] = NR } c[k]++; lastts[k] = $1 }
      next
    }
    !prep {
      prep = 1; nq = 0; mq = 0; minord = 0; maxord = 0
      for (k in c) if (c[k] < 5) {
        nq++; mq += c[k]
        if (minord == 0 || ord[k] < minord) { minord = ord[k]; qfirst = first[k] }
        if (ord[k] > maxord) { maxord = ord[k]; qlast = lastts[k] }
      }
    }
    {
      if ($2 ~ /^AppSSO configuration version changed/) {
        k = substr($1,1,15)
        if (c[k] >= 5) { if (done[k]++) next; print $1 "|AppSSO configuration version changed (" c[k] "x within this 10-minute window)"; next }
        if (!qdone++) print qfirst "|AppSSO configuration changed in " nq " quiet 10-minute window(s): " mq " change(s) in total, the last at " qlast
        next
      }
      print
    }' "$tl_tmp" "$tl_tmp" | while IFS='|' read -r ts label; do
    print -r -- "    $(stamp_utc "$ts")   [device clock $ts]   $label"
  done
  /bin/rm -f "$tl_tmp"
}

# sets HH_BEFORE / HH_AFTER = number of Hub 'unhealthy' PSSO evaluations before / after the registration epoch
hub_health_vs_registration() {   # <health slice, --style default> <registration epoch>
  local ts e
  HH_BEFORE=0; HH_AFTER=0
  while read -r ts; do
    e=$(to_epoch_tz "$ts")
    [[ -z "$e" ]] && continue
    if (( e > $2 )); then HH_AFTER=$(( HH_AFTER + 1 )); else HH_BEFORE=$(( HH_BEFORE + 1 )); fi
  done < <(/usr/bin/sed -nE 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*health state is unhealthy.*/\1\2/p' "$1" 2>/dev/null)
}

fmt_dur() {   # seconds -> "1h 5m 9s"
  local s=$1 h m
  (( s < 0 )) && s=$(( -s ))
  h=$(( s / 3600 )); m=$(( (s % 3600) / 60 )); s=$(( s % 60 ))
  if (( h > 0 )); then print "${h}h ${m}m ${s}s"; elif (( m > 0 )); then print "${m}m ${s}s"; else print "${s}s"; fi
}

xml_values() {   # <profiles xml file> <key>  -> the string value(s) of that key (single string or array of strings)
  /usr/bin/awk -v key="<key>$2</key>" '
    index($0, key) { s=1; next }
    s==1 { if ($0 ~ /<array>/) { s=2; next } else if ($0 ~ /<string>/) { gsub(/<[^>]*>/,""); gsub(/^[ \t]+|[ \t]+$/,""); print; s=0; next } else { s=0 } }
    s==2 { if ($0 ~ /<\/array>/) { s=0; next } if ($0 ~ /<string>/) { gsub(/<[^>]*>/,""); gsub(/^[ \t]+|[ \t]+$/,""); print } }
  ' "$1" 2>/dev/null
}

xml_int() {   # <profiles xml> <key>  -> first integer/boolean value of that key (booleans as 1/0)
  /usr/bin/awk -v key="<key>$2</key>" '
    index($0, key) { s=1; next }
    s==1 && /<integer>/ { gsub(/<[^>]*>/,""); gsub(/^[ \t]+|[ \t]+$/,""); print; exit }
    s==1 && /<(true|false) ?\/>/ { print ($0 ~ /<true/) ? 1 : 0; exit }
  ' "$1" 2>/dev/null
}

sso_payload_summary() {   # <profiles xml> <AppSSO config extract>
  local k vals line shown=0
  print "[SSO payload settings on this Mac, from 'profiles show -all -output stdout-xml' (all profiles)]"
  for k in URLs Hosts AssociatedDomains URLPrefix; do
    vals=$(xml_values "$1" "$k" | /usr/bin/sort -u)
    if [[ -n "$vals" ]]; then
      shown=1
      print -r -- "$vals" | while IFS= read -r line; do print "    $k: $line"; done
    fi
  done
  if (( ! shown )); then
    print "    (not shown by 'profiles' for this payload/OS; AppSSO's own copy follows)"
    /usr/bin/grep -E 'https?://|Hosts = ' "$2" 2>/dev/null | /usr/bin/sed -E 's/^[[:space:]]+/    /' | /usr/bin/sort -u
  fi
  if { xml_values "$1" URLs; /usr/bin/grep -E 'https?://' "$2" 2>/dev/null; } | /usr/bin/grep -qi 'login\.microsoftonline\.com'; then
    print "    'login.microsoftonline.com' listed in URLs: YES"
  else
    print "    'login.microsoftonline.com' listed in URLs: NO"
  fi
}

profile_events() {   # <mdm log slice, --style default>  -> profile install / update / removal events with UTC
  local out ts label flag
  out=$(/usr/bin/sed -nE \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*InstallProfile === ([^(]*[^( ]) \(.*/\1\2|install: \3/p' \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*InstallProfile \(Update\) for: ([^(]*[^( ]) \(.*/\1\2|UPDATE of existing profile: \3/p' \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*RemoveProfile === ([^(]*[^( ]) \(.*/\1\2|REMOVED: \3/p' \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*RemoveProfilePayloads: Will remove: ([^(]*[^( ]) \(<([^>]*)>.*/\1\2|   payload removed: \3 (\4)/p' \
    -e 's/^([0-9-]+ [0-9:]+)\.[0-9]+([+-][0-9]{4}) .*RemoveProfile for: <Device> \(CheckinCycleStage[0-9]*:([A-Za-z]*):REMOVE.*/\1\2|   removal driven by an MDM check-in cycle (\3)/p' \
    "$1" 2>/dev/null | /usr/bin/cut -c1-200 | /usr/bin/uniq | /usr/bin/awk -F'|' '$2 ~ /ManagedSettings/ { n++; next } { print } END { if (n) print "|" n " ManagedSettings events omitted (Apple-generated user profile)" }' | while IFS='|' read -r ts label; do
      if [[ -z "$ts" ]]; then print -r -- "    ($label)"; continue; fi
      flag=""
      [[ "$label" == *SSO* ]] && flag="   <== SSO-related"
      print -r -- "    $(stamp_utc "$ts")   [device clock $ts]   ${label}${flag}"
    done)
  if [[ -n "$out" ]]; then print -r -- "$out"; else print "    (none in the log window)"; fi
}

# ---- automated PSSO validation helpers ----
vcheck() {   # vcheck STATUS name detail...   (STATUS: PASS FAIL WARN INFO SKIP)
  local st="$1" name="$2"; shift 2
  print -r -- "${st}|${name}|$*" >> "$VAL"
  log "  [${st}] ${name}: $*"
}

state_val() {   # first value of "<key>" in the app-sso platform -s output
  /usr/bin/grep -m1 "\"$1\"" "$S_STATE" 2>/dev/null | /usr/bin/sed -E 's/^[[:space:]]*"[^"]*"[[:space:]]*:[[:space:]]*//; s/,$//; s/^"//; s/"$//'
}

url_host() {   # https://host:port/path -> host
  local u="${1#*://}"
  u="${u%%/*}"; u="${u%%\?*}"
  print -r -- "${u%%:*}"
}

tls_issuer() {   # <curl -v stderr file>
  /usr/bin/sed -nE 's/^\*[[:space:]]+issuer:[[:space:]]*//p' "$1" 2>/dev/null | /usr/bin/head -1
}

run_timeout() {   # run_timeout <seconds> <command...>
  local t=$1 pid killer rc
  shift
  "$@" &
  pid=$!
  ( /bin/sleep "$t"; /bin/kill "$pid" 2>/dev/null ) &
  killer=$!
  wait "$pid" 2>/dev/null; rc=$?
  /bin/kill "$killer" 2>/dev/null
  return $rc
}

http_probe() {   # http_probe <name> <GET|POST|HEAD> <url> [extra curl args]  -> HP_CODE HP_RC HP_BODY HP_HDR HP_VERB
  local name="$1" method="$2" url="$3"; shift 3
  local -a mflag
  mflag=(-X "$method")
  [[ "$method" == HEAD ]] && mflag=(-I)
  HP_BODY="$D6/net-$name.body"; HP_HDR="$D6/net-$name.headers"; HP_VERB="$D6/net-$name.verbose"
  HP_CODE=$(/usr/bin/curl -sS -v "${mflag[@]}" --max-time 20 --connect-timeout 10 -o "$HP_BODY" -D "$HP_HDR" -w '%{http_code}' "$@" "$url" 2> "$HP_VERB")
  HP_RC=$?
  print -r -- "$HP_CODE $HP_RC" > "$D6/net-$name.code"
}

aasa_authsrv_apps() {   # <AASA json file> -> app IDs under authsrv.apps, one per line
  /usr/bin/tr -d '\n\r\t' < "$1" 2>/dev/null | /usr/bin/sed -nE 's/.*"authsrv"[[:space:]]*:[[:space:]]*\{[^}]*"apps"[[:space:]]*:[[:space:]]*\[([^]]*)\].*/\1/p' | /usr/bin/tr ',' '\n' | /usr/bin/sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//' | /usr/bin/grep -v '^$'
}

aasa_verdict() {   # <AASA json file> -> "STATUS|detail" (needs TEAM_ID, EXT_ID)
  local apps app team bundle listed=""
  apps=$(aasa_authsrv_apps "$1")
  if [[ -z "$apps" ]]; then print "FAIL|no authsrv section (or not valid JSON) in the AASA file"; return; fi
  while IFS= read -r app; do
    team="${app%%.*}"; bundle="${app#*.}"
    listed+="$app "
    if team_ok "$team" && [[ "$EXT_ID" == "$bundle" || "$EXT_ID" == "$bundle".* ]]; then
      if [[ -n "$TEAM_ID" ]]; then print "PASS|authsrv lists $app (matches the extension's team and bundle prefix)"
      else print "PASS|authsrv lists $app (matches the extension's bundle prefix; its team is not known on this Mac)"; fi
      return
    fi
  done <<< "$apps"
  print "FAIL|authsrv lists [${listed% }] but not this extension (team ${TEAM_ID:-?}, bundle ${EXT_ID:-?})"
}

swc_authsrv_rows() {   # <swcutil show output> -> domain|appid|approval|lastchecked  (authsrv entries only)
  /usr/bin/awk '
    function emit() { if (dom != "") print dom "|" app "|" ap "|" lc; dom=""; app=""; ap=""; lc="" }
    /^Service:[ \t]+authsrv/ { if (s) emit(); s=1; next }
    /^Service:/ { if (s) emit(); s=0; next }
    s && /^App ID:/ { sub(/^App ID:[ \t]+/,""); app=$0; next }
    s && /^Domain:/ { sub(/^Domain:[ \t]+/,""); dom=$0; next }
    s && /^Site\/Fmwk Approval:/ { sub(/^Site\/Fmwk Approval:[ \t]+/,""); ap=$0; next }
    s && /^Last Checked:/ { sub(/^Last Checked:[ \t]+/,""); lc=$0; next }
    s && /^-----/ { emit(); s=0; next }
    END { if (s) emit() }
  ' "$1" 2>/dev/null
}

CH_HELD=""
ch_hold() { CH_HELD+="$1|$2|$3"$'\n'; }   # check_host holds its per-host lines until it knows whether they are one consolidated finding

ext_payload_url_hosts() {   # hosts of the URLs listed by the SSO payload(s) whose extension is the active one
  local p u
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    [[ "$(flat_val "$p" ExtensionIdentifier)" == "$EXT_ID" ]] || continue
    while IFS= read -r u; do [[ -n "$u" ]] && url_host "$u"; done <<< "$(flat_list "$p" URLs)"
  done <<< "$(sso_prefixes)"
}

aasa_vendor() {   # <space-separated app ids an AASA file lists> -> the vendor they belong to
  case "$1" in
    *com.microsoft.*) print "Microsoft" ;;
    *com.okta.*) print "Okta" ;;
    *com.ws1.*|*com.vmware.*|*com.airwatch.*|*com.omnissa.*) print "Omnissa" ;;
    *) print "another vendor" ;;
  esac
}

aasa_lists_ext_bundle() {   # true when an app in the list has this extension's bundle (only the team differs)
  print -r -- "$1" | /usr/bin/awk -v ext="$EXT_ID" '{ for (i = 1; i <= NF; i++) { n = index($i, "."); b = substr($i, n + 1); if (ext == b || index(ext, b ".") == 1) f = 1 } } END { exit f ? 0 : 1 }'
}

check_host() {   # check_host <host>   (needs ASSOC_HOSTS, EXT_URL_HOSTS, EXT_ASSOC_HOSTS, D6, TEAM_ID, EXT_ID, UNRESOLVED_HOSTS)
  local h="$1" safe v rows mine first o_code o_body o_ok=0 c_ok=0 cdn_body has_payload=0 note
  local swp sw_state="" sw_first="" o_v="" c_v="" o_list="" c_list="" own_urls=0 own_assoc=0 list="" src="" vtxt="" swtxt="" where="" fixwhere="" msg="" fk=0 st nm det
  CH_HELD=""
  safe="${h//[^A-Za-z0-9.-]/_}"
  # 0. some payload URLs are bare domain prefixes, not web hosts - nothing to associate or fetch
  http_probe "aasa-origin-$safe" GET "https://$h/.well-known/apple-app-site-association" --max-redirs 0
  o_code="$HP_CODE"; o_body="$HP_BODY"
  if [[ "$HP_RC" == 6 || "$HP_RC" == 60 ]]; then
    UNRESOLVED_HOSTS+="$h"$'\n'
    if [[ "$HP_RC" == 6 ]]; then note="the name does not resolve"; else note="its TLS certificate is not valid for the name"; fi
    vcheck INFO "host:$h" "URL prefix only - not a web host that can serve an AASA file ($note; curl rc=$HP_RC); association checks skipped"
    return
  fi
  # 1. association: what macOS itself decided (swcutil) is authoritative; the payload entry is only one way to get it
  print -r -- "$ASSOC_HOSTS" | /usr/bin/grep -qxF "$h" && has_payload=1
  if [[ -s "$D6/swcutil-show.txt" ]] && /usr/bin/grep -q 'exit code: 0' "$D6/swcutil-show.txt"; then
    rows=$(swc_authsrv_rows "$D6/swcutil-show.txt" | /usr/bin/awk -F'|' -v h="$h" '{ d=$1; sub(/\?.*$/,"",d); if (d==h) print }')
    mine=$(print -r -- "$rows" | /usr/bin/awk -F'|' -v team="$TEAM_ID" -v ext="$EXT_ID" 'NF { n=index($2,"."); t=substr($2,1,n-1); b=substr($2,n+1); if (team=="" || (t==team && (ext==b || index(ext, b ".")==1))) print }')
    first=$(print -r -- "$mine" | /usr/bin/head -1)
    if print -r -- "$mine" | /usr/bin/grep -q '|approved|'; then
      sw_state=approved
      if (( has_payload )); then note="also listed in the Associated Domains payload"; else note="the association is built into the app, so no payload entry is needed"; fi
      ch_hold PASS "domain-association:$h" "swcutil: authsrv approved for this extension ($first) - $note"
    elif print -r -- "$mine" | /usr/bin/grep -q '|denied|'; then
      sw_state=denied; sw_first="$first"
      ch_hold FAIL "domain-association:$h" "swcutil: authsrv DENIED for this extension ($first)"
    elif [[ -n "$mine" ]]; then
      sw_state=notyet; sw_first="$first"
      ch_hold WARN "domain-association:$h" "swcutil: authsrv present but not yet approved ($first)"
    elif [[ -n "$rows" ]]; then
      sw_state=other
      ch_hold FAIL "domain-association:$h" "swcutil lists authsrv entries for $h only for OTHER apps ($(print -r -- "$rows" | /usr/bin/awk -F'|' '{ printf "%s ", $2 }')), none for this extension (team ${TEAM_ID:-?}, bundle ${EXT_ID:-?})"
    elif (( has_payload )); then
      sw_state=none
      ch_hold WARN "domain-association:$h" "authsrv:$h is in the Associated Domains payload but swcutil has no entry for it yet"
    else
      sw_state=none
      ch_hold FAIL "domain-association:$h" "no Associated Domains payload entry and no swcutil authsrv entry for $h - macOS will not let this extension act for the domain"
    fi
  elif (( has_payload )); then
    sw_state=unavailable
    ch_hold INFO "domain-association:$h" "authsrv:$h is in the Associated Domains payload (swcutil was not available to confirm approval)"
  else
    sw_state=unavailable
    ch_hold WARN "domain-association:$h" "no Associated Domains payload entry and swcutil was not available - association not verified"
  fi
  # 2. AASA at the origin (no redirects allowed)
  if [[ "$o_code" == 200 ]]; then
    v=$(aasa_verdict "$o_body"); o_v="${v%%|*}"; ch_hold "$o_v" "aasa-origin:$h" "${v#*|}"
    [[ "$o_v" == PASS ]] && o_ok=1
    [[ "$o_v" == FAIL ]] && o_list=$(aasa_authsrv_apps "$o_body" | /usr/bin/tr '\n' ' ')
  else
    ch_hold FAIL "aasa-origin:$h" "HTTP ${o_code} (curl rc=$HP_RC) for https://$h/.well-known/apple-app-site-association (must be HTTP 200, no redirect)"
  fi
  # 3. AASA as Apple's CDN serves it (what devices use)
  http_probe "aasa-cdn-$safe" GET "https://app-site-association.cdn-apple.com/a/v1/$h"
  cdn_body="$HP_BODY"
  if [[ "$HP_CODE" == 200 ]]; then
    v=$(aasa_verdict "$cdn_body"); c_v="${v%%|*}"; ch_hold "$c_v" "aasa-cdn:$h" "${v#*|}"
    [[ "$c_v" == PASS ]] && c_ok=1
    [[ "$c_v" == FAIL ]] && c_list=$(aasa_authsrv_apps "$cdn_body" | /usr/bin/tr '\n' ' ')
    if (( o_ok )) && [[ "$(/usr/bin/tr -d ' \n\r\t' < "$o_body" | /usr/bin/shasum)" != "$(/usr/bin/tr -d ' \n\r\t' < "$cdn_body" | /usr/bin/shasum)" ]]; then
      ch_hold WARN "aasa-cdn-vs-origin:$h" "the Apple CDN copy differs from the origin file (CDN caches for hours: Cache-Control max-age=21600 observed)"
    fi
  else
    ch_hold FAIL "aasa-cdn:$h" "Apple CDN returned HTTP ${HP_CODE} (curl rc=$HP_RC) for https://app-site-association.cdn-apple.com/a/v1/$h - devices cannot validate the extension for this domain"
  fi
  # 4. one consolidated finding when this extension's own profile lists a domain that belongs to another vendor
  print -r -- "$EXT_URL_HOSTS" | /usr/bin/grep -qxF "$h" && own_urls=1
  print -r -- "$EXT_ASSOC_HOSTS" | /usr/bin/grep -qxF "$h" && own_assoc=1
  list="${c_list:-$o_list}"
  if [[ -n "$EXT_ID" && "$sw_state" != approved && "$o_v" != PASS && "$c_v" != PASS && -n "${list// /}" ]] && (( own_urls || own_assoc )) && ! aasa_lists_ext_bundle "$list"; then fk=1; fi
  if (( fk )); then
    vtxt=$(aasa_vendor "$list")
    where=""; (( own_urls )) && where="URLs"; (( own_assoc )) && where+="${where:+ and }Associated Domains"
    if (( own_urls && own_assoc )); then fixwhere="both the URLs list and the Associated Domains payload"; elif (( own_urls )); then fixwhere="the URLs list"; else fixwhere="the Associated Domains payload"; fi
    src=""; [[ "$o_v" == FAIL && -n "${o_list// /}" ]] && src="the file at its origin"
    [[ "$c_v" == FAIL && -n "${c_list// /}" ]] && src+="${src:+ and }Apple's CDN copy"
    swp=$(print -r -- "$sw_first" | /usr/bin/awk -F'|' '{ printf "%s, last checked %s", $3, $4 }')
    case "$sw_state" in
      denied) swtxt="macOS denied this extension for it (swcutil: ${swp})" ;;
      other) swtxt="macOS (swcutil) has entries for it only for other apps" ;;
      notyet) swtxt="macOS has not approved it (swcutil: ${swp})" ;;
      unavailable) swtxt="swcutil was not available to confirm macOS's decision" ;;
      *) swtxt="macOS (swcutil) has no approval for this extension" ;;
    esac
    msg="the profile lists ${h} for this extension (in ${where}), but that domain belongs to ${vtxt}: its AASA file (${src}) lists only [${list% }] and not this extension (team ${TEAM_ID:-?}, bundle ${EXT_ID}), and ${swtxt}. The entry cannot work, because only the domain's owner can add this extension to its AASA file. Fix: remove ${h} from ${fixwhere}."
    (( own_urls )) && msg+=" A URL kept in the URLs list also stays reserved: Apple requires every URL to be unique across all installed SSO payloads, so ${vtxt}'s own SSO profile could not use it."
    vcheck FAIL "payload-foreign-domain:$h" "$msg"
  else
    while IFS='|' read -r st nm det; do
      [[ -z "$st" ]] && continue
      vcheck "$st" "$nm" "$det"
    done <<< "$CH_HELD"
  fi
}

# ---- per-pair association checks (every authsrv entry of an Associated Domains payload: app + domain) ----
ad_pairs() {   # <profiles xml> -> "application id|domain" for every authsrv entry in an Associated Domains payload
  /usr/bin/awk '
    /<key>ApplicationIdentifier<\/key>/ { getline; v=$0; gsub(/<[^>]*>/,"",v); gsub(/^[ \t]+|[ \t]+$/,"",v); app=v; next }
    /<key>AssociatedDomains<\/key>/ { inarr=1; next }
    inarr && /<\/array>/ { inarr=0; next }
    inarr && /<string>/ { v=$0; gsub(/<[^>]*>/,"",v); gsub(/^[ \t]+|[ \t]+$/,"",v); if (v ~ /^authsrv:/) { sub(/^authsrv:/,"",v); sub(/\?.*$/,"",v); print app "|" v } }
  ' "$1" 2>/dev/null
}

app_is_active() {   # <TEAM.bundle> -> success if it is the host app of the active extension
  local a="$1" team bundle
  team="${a%%.*}"; bundle="${a#*.}"
  team_ok "$team" && [[ "$EXT_ID" == "$bundle" || "$EXT_ID" == "$bundle".* ]]
}

aasa_fetch() {   # aasa_fetch origin|cdn <host>  -> AF_CODE AF_RC AF_BODY   (reuses an earlier fetch of the same host)
  local kind="$1" h="$2" safe name
  safe="${h//[^A-Za-z0-9.-]/_}"; name="aasa-${kind}-${safe}"
  if [[ ! -f "$D6/net-$name.code" ]]; then
    if [[ "$kind" == origin ]]; then http_probe "$name" GET "https://$h/.well-known/apple-app-site-association" --max-redirs 0
    else http_probe "$name" GET "https://app-site-association.cdn-apple.com/a/v1/$h"; fi
  fi
  read -r AF_CODE AF_RC < "$D6/net-$name.code"
  AF_BODY="$D6/net-$name.body"
}

check_association_pairs() {   # needs XMLP D6 HOSTS TEAM_ID EXT_ID
  local pairs app dom core row appr last swc_ok=0 o_state c_state apps_c why name n_all=0 n_covered=0
  pairs=$(ad_pairs "$XMLP" | /usr/bin/sort -u)
  if [[ -z "$pairs" ]]; then vcheck SKIP association-pairs "no authsrv entries in an Associated Domains payload"; return; fi
  [[ -s "$D6/swcutil-show.txt" ]] && /usr/bin/grep -q 'exit code: 0' "$D6/swcutil-show.txt" && swc_ok=1
  while IFS='|' read -r app dom; do
    [[ -z "$app" || -z "$dom" ]] && continue
    n_all=$(( n_all + 1 ))
    core=0; print -r -- "$HOSTS" | /usr/bin/grep -qxF "$dom" && core=1
    if (( core )) && app_is_active "$app"; then n_covered=$(( n_covered + 1 )); continue; fi   # already judged by domain-association:<host>
    name="pair:${app}@${dom}"
    aasa_fetch origin "$dom"
    if [[ "$AF_RC" == 6 || "$AF_RC" == 60 ]]; then
      vcheck INFO "$name" "the domain is not a web host that can serve an AASA file (curl rc=${AF_RC}), so this association cannot be approved"
      continue
    fi
    if [[ "$AF_CODE" == 200 ]]; then
      if aasa_authsrv_apps "$AF_BODY" | /usr/bin/grep -qxF "$app"; then o_state="lists it"; else o_state="does not list it"; fi
    else o_state="unreadable (HTTP ${AF_CODE})"; fi
    aasa_fetch cdn "$dom"
    apps_c=""
    if [[ "$AF_CODE" == 200 ]]; then
      apps_c=$(aasa_authsrv_apps "$AF_BODY" | /usr/bin/tr '\n' ' ')
      if aasa_authsrv_apps "$AF_BODY" | /usr/bin/grep -qxF "$app"; then c_state="lists it"; else c_state="does not list it"; fi
    else c_state="unreadable (HTTP ${AF_CODE})"; fi
    why="the domain's AASA at its origin ${o_state}; Apple's CDN copy ${c_state}"
    if [[ "$c_state" == "does not list it" ]]; then
      if [[ -n "${apps_c// /}" ]]; then why+=" (it lists: ${apps_c% })"; else why+=" (it has no authsrv apps)"; fi
    fi
    if (( swc_ok )); then
      row=$(swc_authsrv_rows "$D6/swcutil-show.txt" | /usr/bin/awk -F'|' -v d="$dom" -v a="$app" '{ x=$1; sub(/\?.*$/,"",x); if (x==d && $2==a) { print; exit } }')
      if [[ -n "$row" ]]; then
        appr=$(print -r -- "$row" | /usr/bin/awk -F'|' '{ print $3 }'); last=$(print -r -- "$row" | /usr/bin/awk -F'|' '{ print $4 }')
        case "$appr" in
          approved)
            if [[ "$c_state" == "does not list it" ]]; then
              vcheck WARN "$name" "swcutil: approved (last checked ${last}), yet ${why} - possibly a cached decision"
            else
              vcheck PASS "$name" "swcutil: approved (last checked ${last}); ${why}"
            fi ;;
          denied)
            vcheck WARN "$name" "swcutil: DENIED (last checked ${last}); ${why}. Harmless if nothing uses this app for this domain." ;;
          *)
            vcheck WARN "$name" "swcutil: status '${appr}' (last checked ${last}), not approved yet; ${why}" ;;
        esac
      elif [[ "$c_state" == "lists it" ]]; then
        vcheck INFO "$name" "no swcutil entry yet (macOS evaluates a new entry a few minutes after the profile installs); ${why} - approval is expected"
      elif [[ "$c_state" == "does not list it" ]]; then
        vcheck WARN "$name" "no swcutil entry yet; ${why} - a denial is expected"
      else
        vcheck INFO "$name" "no swcutil entry yet and Apple's CDN copy could not be read; ${why}"
      fi
    else
      vcheck INFO "$name" "swcutil was not available; ${why}"
    fi
  done <<< "$pairs"
  vcheck INFO association-pairs "${n_all} authsrv pair(s) (app + domain) in the Associated Domains payload; ${n_covered} judged by the domain-association checks above, $(( n_all - n_covered )) judged individually as pair:APP@DOMAIN"
}

# ---- v2.7: unknown team, shared Safari session/probe, --test-url ----
team_ok() { [[ -z "$TEAM_ID" || "$1" == "$TEAM_ID" ]]; }   # a team the state does not report (Mac not registered yet) matches on the bundle alone

SAFARI_WAS_RUNNING=0
safari_session_begin() {   # remember whether Safari was already running, so only a Safari we started is quit afterwards
  (( NO_BROWSER )) && return 0
  [[ -z "$CONSOLE_USER" ]] && return 0
  if /usr/bin/pgrep -x Safari >/dev/null 2>&1; then SAFARI_WAS_RUNNING=1; else SAFARI_WAS_RUNNING=0; fi
}
safari_session_end() {
  (( NO_BROWSER )) && return 0
  [[ -z "$CONSOLE_USER" ]] && return 0
  (( ! SAFARI_WAS_RUNNING )) && run_as_user /usr/bin/pkill -TERM -x Safari >/dev/null 2>&1
  return 0
}
safari_probe() {   # safari_probe <url> <evidence file>  -> SP_N (AppSSO beginAuthorization events) and SP_EXT (extension bundle IDs that received it)
  local url="$1" out="$2" t0
  t0=$(/bin/date '+%Y-%m-%d %H:%M:%S')
  run_as_user /usr/bin/open -g -a Safari "$url" >/dev/null 2>&1
  /bin/sleep 15
  capture "$out" /usr/bin/log show --info --debug --style default --start "$t0" --predicate '(subsystem == "com.apple.AppSSO") AND (eventMessage CONTAINS "beginAuthorization")'
  SP_N=$(/usr/bin/grep -v '^#' "$out" | /usr/bin/grep -c 'beginAuthorization')
  SP_EXT=$(/usr/bin/grep -v '^#' "$out" | /usr/bin/grep -o 'extensionBundleId = [A-Za-z0-9.]*' | /usr/bin/sed 's/^extensionBundleId = //' | /usr/bin/sort -u | /usr/bin/tr '\n' ' ')
  SP_EXT="${SP_EXT% }"
}

safari_navigation_test() {   # background Safari navigation to each payload URL; look for AppSSO authorization activity
  local url n idx=0 out h
  if (( NO_BROWSER )); then vcheck SKIP safari-navigation "skipped (--no-browser-test)"; return; fi
  if [[ -z "$CONSOLE_USER" ]]; then vcheck SKIP safari-navigation "no console user logged in"; return; fi
  if [[ -z "$URLS" ]]; then vcheck SKIP safari-navigation "no SSO payload URLs known"; return; fi
  while IFS= read -r url; do
    [[ -z "$url" ]] && continue
    h=$(url_host "$url")
    if print -r -- "$UNRESOLVED_HOSTS" | /usr/bin/grep -qxF "$h"; then
      vcheck INFO "safari-navigation:$url" "skipped - $h is a URL prefix, not a web host"
      continue
    fi
    idx=$(( idx + 1 ))
    (( idx > 3 )) && break
    out="$D6/safari-navigation-$idx.txt"
    safari_probe "$url" "$out"
    if (( ${SP_N:-0} > 0 )); then
      vcheck PASS "safari-navigation:$url" "AppSSO began ${SP_N} authorization(s) after Safari opened it - the URL was handed to ${SP_EXT:-the extension}"
    else
      vcheck WARN "safari-navigation:$url" "no AppSSO authorization activity within 15 s of Safari opening it - the URL was not handed to the extension (see the associated-domain and AASA results)"
    fi
  done <<< "$URLS"
}

url_path() {   # https://host:port/path?query#fragment -> /path  ("/" when empty; no query, no fragment)
  local u="${1#*://}" p
  if [[ "$u" == */* ]]; then p="/${u#*/}"; else p="/"; fi
  p="${p%%\?*}"; p="${p%%#*}"
  print -r -- "$p"
}

payload_url_match() {   # <url> -> prints the payload URLs entry that covers it (scheme, host, path prefix); fails if none does
  local url="$1" scheme host path pu pscheme phost ppath pp
  scheme=$(print -r -- "${url%%://*}" | lc); host=$(url_host "$url" | lc); path=$(url_path "$url")
  while IFS= read -r pu; do
    [[ -z "$pu" ]] && continue
    pscheme=$(print -r -- "${pu%%://*}" | lc); phost=$(url_host "$pu" | lc); ppath=$(url_path "$pu"); pp="${ppath%/}"
    if [[ "$pscheme" == "$scheme" && "$phost" == "$host" && "$path" == "$pp"* ]]; then print -r -- "$pu"; return 0; fi
  done <<< "$URLS"
  return 1
}

test_urls() {   # --test-url: static checks (payload prefix, swcutil, AASA) plus a live Safari probe for every URL asked for
  local url idx=0 host match rows mine swc_txt aasa_txt v c_ok apps_c reasons pred out swc_ok=0
  (( ${#TEST_URLS[@]} )) || return 0
  [[ -s "$D6/swcutil-show.txt" ]] && /usr/bin/grep -q 'exit code: 0' "$D6/swcutil-show.txt" && swc_ok=1
  for url in "${TEST_URLS[@]}"; do
    idx=$(( idx + 1 ))
    host=$(url_host "$url")
    match=$(payload_url_match "$url")
    aasa_fetch origin "$host"
    if [[ "$AF_RC" == 6 || "$AF_RC" == 60 ]]; then
      vcheck INFO "test-url:$url" "$host is not a web host that can serve an AASA file (curl rc=${AF_RC}); nothing to test"
      continue
    fi
    # the AASA copy devices use (Apple's CDN)
    c_ok=0; apps_c=""
    aasa_fetch cdn "$host"
    if [[ "$AF_CODE" == 200 ]]; then
      apps_c=$(aasa_authsrv_apps "$AF_BODY" | /usr/bin/tr '\n' ' ')
      v=$(aasa_verdict "$AF_BODY"); [[ "${v%%|*}" == PASS ]] && c_ok=1
      if (( c_ok )); then aasa_txt="Apple's AASA copy lists this extension"
      elif [[ -n "${apps_c// /}" ]]; then aasa_txt="Apple's AASA copy does NOT list this extension (it lists: ${apps_c% })"
      else aasa_txt="Apple's AASA copy has no authsrv apps"; fi
    else
      aasa_txt="Apple's AASA copy is unreadable (HTTP ${AF_CODE})"
    fi
    # what macOS itself decided
    swc_txt="swcutil was not available"
    if (( swc_ok )); then
      rows=$(swc_authsrv_rows "$D6/swcutil-show.txt" | /usr/bin/awk -F'|' -v h="$host" '{ d=$1; sub(/\?.*$/,"",d); if (d==h) print }')
      mine=$(print -r -- "$rows" | /usr/bin/awk -F'|' -v ext="$EXT_ID" -v team="$TEAM_ID" 'NF { n=index($2,"."); t=substr($2,1,n-1); b=substr($2,n+1); if ((team=="" || t==team) && (ext==b || index(ext, b ".")==1)) print }')
      if   print -r -- "$mine" | /usr/bin/grep -q '|approved|'; then swc_txt="swcutil: approved for this extension"
      elif print -r -- "$mine" | /usr/bin/grep -q '|denied|';   then swc_txt="swcutil: DENIED for this extension"
      elif [[ -n "$mine" ]]; then swc_txt="swcutil: entry present but not approved yet"
      elif [[ -n "$rows" ]]; then swc_txt="swcutil: entries exist only for other apps ($(print -r -- "$rows" | /usr/bin/awk -F'|' '{ printf "%s ", $2 }'))"
      else swc_txt="swcutil: no entry for this host"; fi
    fi
    # prediction from the static evidence
    pred="not handled"
    if [[ -n "$match" ]]; then
      if print -r -- "$swc_txt" | /usr/bin/grep -q 'approved for this extension'; then pred="handled"
      elif print -r -- "$swc_txt" | /usr/bin/grep -q 'DENIED'; then pred="not handled"
      elif (( c_ok )); then pred="handled"; fi
    fi
    reasons=""
    [[ -z "$match" ]] && reasons+="No URLs entry in the payload covers this URL (a matching prefix would have to be added to URLs). "
    if [[ "$aasa_txt" == *"does NOT list"* || "$aasa_txt" == *"no authsrv"* ]]; then reasons+="The domain's own AASA does not authorize this extension, which the profile cannot change. "; fi
    out="$D6/test-url-$idx.txt"
    if (( NO_BROWSER )) || [[ -z "$CONSOLE_USER" ]]; then
      vcheck INFO "test-url:$url" "prediction only (live Safari test skipped): ${pred}. ${reasons}Payload prefix: ${match:-none}; ${swc_txt}; ${aasa_txt}"
      continue
    fi
    safari_probe "$url" "$out"
    if (( ${SP_N:-0} > 0 )); then
      vcheck PASS "test-url:$url" "handed to ${SP_EXT:-an extension} (${SP_N} AppSSO authorization(s) within 15 s). Payload prefix: ${match:-none by the prefix reading used here}; ${swc_txt}; ${aasa_txt}"
    else
      vcheck WARN "test-url:$url" "NOT handed to any extension (0 AppSSO authorizations within 15 s). ${reasons}Payload prefix: ${match:-none}; ${swc_txt}; ${aasa_txt}"
    fi
  done
}

# ---- v2.8: what is in the network path, and does the Microsoft sign-in endpoint redirect to http:// ----
NET_AGENT_PATTERN='Netskope|stAgentSvc|nsAuxiliarySvc|Zscaler|GlobalProtect|PanGPS|falcon|crowdstrike|CrowdStrike|wdav|Microsoft Defender|mdatp|Cisco Secure Client|vpnagentd|acumbrellaagent|Forcepoint|CloudflareWARP|Cloudflare WARP|iboss'

agent_family() {   # command line -> the web-filter / VPN / proxy product it belongs to
  case "$1" in
    *[Nn]etskope*|*stAgentSvc*|*nsAuxiliarySvc*) print "Netskope" ;;
    *Zscaler*)                                   print "Zscaler" ;;
    *GlobalProtect*|*PanGPS*)                    print "GlobalProtect" ;;
    *[Ff]alcon*|*[Cc]rowd[Ss]trike*)             print "CrowdStrike" ;;
    *wdav*|*"Microsoft Defender"*|*mdatp*)       print "Microsoft Defender" ;;
    *"Cisco Secure Client"*|*vpnagentd*|*acumbrellaagent*) print "Cisco Secure Client or Umbrella" ;;
    *Forcepoint*)                                print "Forcepoint" ;;
    *Cloudflare*)                                print "Cloudflare WARP" ;;
    *iboss*)                                     print "iboss" ;;
  esac
}

lstart_to_epoch() { /bin/date -j -f '%a %b %e %H:%M:%S %Y' "$1" +%s 2>/dev/null; }            # local time, exactly as ps prints it
utc_str_to_epoch() { /bin/date -j -u -f '%m-%d-%Y %H:%M:%S' "${1% UTC}" +%s 2>/dev/null; }     # "11-10-2026 11:01:55 UTC"
epoch_utc_hms() { /bin/date -u -r "$1" '+%H:%M:%S UTC' 2>/dev/null; }                              # epoch -> "11:02:07 UTC"

last_registration_window() {   # -> "start_epoch end_epoch start_label end_label" for the last device registration attempt; fails if none logged
  local tl s e sl el
  tl=$(apple_registration_timeline "$D4/log-show-registration-timeline-with-tz.txt" 2>/dev/null)
  sl=$(print -r -- "$tl" | /usr/bin/grep 'device registration started' | /usr/bin/tail -1 | /usr/bin/sed -E 's/^ *([0-9-]+ [0-9:]+ UTC).*/\1/')
  [[ -z "$sl" ]] && return 1
  el=$(print -r -- "$tl" | /usr/bin/awk -v s="$sl" 'f && /registration finished/ { print; exit } index($0, s) && /device registration started/ { f=1 }' | /usr/bin/sed -E 's/^ *([0-9-]+ [0-9:]+ UTC).*/\1/')
  s=$(utc_str_to_epoch "$sl"); [[ -z "$s" ]] && return 1
  if [[ -n "$el" ]]; then e=$(utc_str_to_epoch "$el"); else e=$(( s + 120 )); fi
  print -r -- "${s}|${e:-$s}|${sl}|${el:-unknown}"
}

check_network_agents() {   # web filters / VPNs / proxies: what is running, since when, and how that lines up with the last registration attempt
  local line lst cmd fam e rows fams f cnt first last fe ft le lt rel win ws we wsl wel prof
  capture "$D6/network-agents.txt" /bin/zsh -c "/bin/ps -axo lstart=,pid=,command= | /usr/bin/grep -E '$NET_AGENT_PATTERN' | /usr/bin/grep -v 'grep -E'"
  capture "$D6/systemextensions-list.txt" /usr/bin/systemextensionsctl list
  capture "$D6/nc-list.txt" /usr/sbin/scutil --nc list
  win=$(last_registration_window)
  ws=""; we=""; wsl=""; wel=""
  [[ -n "$win" ]] && IFS='|' read -r ws we wsl wel <<< "$win"
  rows=""
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    lst="${line:0:24}"; cmd="${line:24}"
    fam=$(agent_family "$cmd"); [[ -z "$fam" ]] && continue
    e=$(lstart_to_epoch "$lst"); [[ -z "$e" ]] && continue
    rows+="${fam}|${e}|${lst:11:8}"$'\n'
  done < "$D6/network-agents.txt"
  if [[ -z "$rows" ]]; then
    vcheck INFO network-agents "none of the known web-filter / VPN / proxy agents is running (Netskope, Zscaler, GlobalProtect, CrowdStrike, Defender, Cisco, Forcepoint, Cloudflare WARP, iboss)"
  else
    fams=$(print -r -- "$rows" | /usr/bin/cut -d'|' -f1 | /usr/bin/sort -u)
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      cnt=$(print -r -- "$rows" | /usr/bin/awk -F'|' -v f="$f" '$1==f' | /usr/bin/wc -l | /usr/bin/tr -d ' ')
      first=$(print -r -- "$rows" | /usr/bin/awk -F'|' -v f="$f" '$1==f { print $2 "|" $3 }' | /usr/bin/sort -t'|' -k1,1n | /usr/bin/head -1)
      last=$(print -r -- "$rows" | /usr/bin/awk -F'|' -v f="$f" '$1==f { print $2 "|" $3 }' | /usr/bin/sort -t'|' -k1,1n | /usr/bin/tail -1)
      fe="${first%%|*}"; ft="${first#*|}"; le="${last%%|*}"; lt="${last#*|}"
      rel=""
      if [[ -n "$ws" ]]; then
        if (( fe <= ws )); then rel="; it was already running when the last registration attempt started ($wsl)"
        elif (( fe <= we )); then rel="; its first process started DURING the last registration attempt ($wsl to $wel)"
        else rel="; its first process started AFTER the last registration attempt finished ($wel)"; fi
      fi
      vcheck INFO "network-agent:$f" "${cnt} process(es) running, started ${ft} to ${lt} on the device clock (the first one at $(epoch_utc_hms "$fe"))${rel}. Running is not the same as steering traffic; the TLS lines show whether it is."
    done <<< "$fams"
  fi
  prof=$(/usr/bin/awk '
    /<key>ProfileDisplayName<\/key>/ { getline; v=$0; gsub(/<[^>]*>/,"",v); gsub(/^[ \t]+|[ \t]+$/,"",v); name=v; next }
    /<key>PayloadType<\/key>/ { getline; v=$0; gsub(/<[^>]*>/,"",v); gsub(/^[ \t]+|[ \t]+$/,"",v)
      d=""
      if (v=="com.apple.webcontent-filter") d="content filter"; else if (v=="com.apple.vpn.managed") d="VPN"
      else if (v=="com.apple.vpn.managed.applayer") d="per-app VPN"; else if (v=="com.apple.dnsProxy.managed") d="DNS proxy"
      else if (v=="com.apple.proxy.http.global") d="GLOBAL HTTP PROXY"; else if (v=="com.apple.relay.managed") d="relay"
      if (d != "") { k=name " (" d ")"; if (!(k in seen)) { seen[k]=1; printf "%s; ", k } } }
  ' "$XMLP" 2>/dev/null)
  if [[ -n "$prof" ]]; then vcheck INFO network-filter-profiles "installed profiles with network-affecting payloads: ${prof%; }"
  else vcheck INFO network-filter-profiles "no installed profile carries a content filter, VPN, DNS proxy, relay or global HTTP proxy payload"; fi
}

check_signin_endpoint() {   # Microsoft extension only: does anything in the network path redirect Microsoft's sign-in endpoint to a non-https URL?
  local loc lhost iss
  [[ "$EXT_ID" == *microsoft* ]] || return 0
  http_probe signin-openid GET "https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration" --max-redirs 0 -H 'Accept: application/json'
  iss=$(tls_issuer "$HP_VERB")
  if [[ "$HP_CODE" == 200 ]] && /usr/bin/grep -q '"authorization_endpoint"' "$HP_BODY"; then
    if [[ "$iss" == *DigiCert* || "$iss" == *Microsoft* ]]; then
      vcheck PASS signin-openid "login.microsoftonline.com served its OpenID configuration over https with TLS issuer '${iss}'"
    else
      vcheck WARN signin-openid "login.microsoftonline.com answered, but the TLS issuer is '${iss:-unknown}', not the DigiCert or Microsoft chain seen on Macs without interception - inspection suspected"
    fi
  elif [[ "$HP_CODE" == 000 ]]; then
    vcheck WARN signin-openid "login.microsoftonline.com is unreachable (curl rc=${HP_RC})"
  else
    vcheck FAIL signin-openid "HTTP ${HP_CODE} (curl rc=${HP_RC}) instead of 200 from Microsoft's OpenID configuration endpoint - something in the path is answering for it"
  fi
  http_probe signin-authorize GET "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=29d9ed98-a469-4536-ade2-f981bc1d605e&response_type=code&scope=openid&redirect_uri=msauth%3A%2F%2Fmicrosoft.aad.brokerplugin" --max-redirs 0
  loc=$(/usr/bin/grep -i '^location:' "$HP_HDR" 2>/dev/null | /usr/bin/head -1 | /usr/bin/sed -E 's/^[Ll]ocation:[[:space:]]*//' | /usr/bin/tr -d '\r')
  lhost=$(url_host "$loc")
  if [[ "$loc" == http://* ]]; then
    vcheck FAIL signin-authorize "the sign-in endpoint answered HTTP ${HP_CODE} and redirected to a NON-https URL (host ${lhost}). Microsoft does not do that, so something in the network path is - the same symptom as MSAL -51116 'The server has redirected to a non-https url'"
  elif [[ -n "$loc" ]]; then
    vcheck INFO signin-authorize "HTTP ${HP_CODE}, redirected to ${loc%%\?*}"
  elif [[ "$HP_CODE" == 200 ]]; then
    vcheck PASS signin-authorize "the sign-in page was served directly over https (HTTP 200, no redirect)"
  elif [[ "$HP_CODE" == 000 ]]; then
    vcheck WARN signin-authorize "the sign-in endpoint is unreachable (curl rc=${HP_RC})"
  else
    vcheck INFO signin-authorize "HTTP ${HP_CODE}, no redirect"
  fi
}

# ---- v3.0 part A: read the profiles plist generically (payload settings, Setup Assistant keys, Okta, Kerberos payloads) ----
plist_flat() {   # <plist xml> <ERE on the path>  -> path=value for every leaf whose path matches (one tag per line, as `profiles` prints it)
  PAT="$2" /usr/bin/awk '
    BEGIN { pat = ENVIRON["PAT"]; depth = 0 }
    function pathof(   i, p, c) {
      p = ""
      for (i = 2; i <= depth; i++) { c = comp[i]; if (c ~ /^\[/) p = p c; else p = p "." c }
      return p
    }
    { line = $0; gsub(/^[ \t]+|[ \t]+$/, "", line) }
    line ~ /^<key>/ { key = line; sub(/^<key>/, "", key); sub(/<\/key>.*$/, "", key); next }
    line == "<dict>" || line == "<array>" {
      depth++; typ[depth] = (line == "<dict>") ? "D" : "A"
      if (depth > 1 && typ[depth-1] == "A") { comp[depth] = "[" cnt[depth-1] "]"; cnt[depth-1]++ } else { comp[depth] = key }
      cnt[depth] = 0; next
    }
    line == "</dict>" || line == "</array>" { depth--; next }
    line ~ /^<(string|integer|real|date)>/ || line ~ /^<(true|false) ?\/>$/ {
      v = line
      if (v ~ /^<true/) v = "true"; else if (v ~ /^<false/) v = "false"; else gsub(/<[^>]*>/, "", v)
      if (typ[depth] == "A") { p = pathof() "[" cnt[depth] "]"; cnt[depth]++ } else { p = pathof() "." key }
      if (p ~ pat) print p "=" v
    }
  ' "$1" 2>/dev/null
}

sso_prefixes() { /usr/bin/sed -nE 's/^(.*)\.PayloadType=com\.apple\.extensiblesso$/\1.PayloadContent/p' "$FLAT" 2>/dev/null; }   # one prefix per Extensible SSO payload (its settings live under PayloadContent)

flat_get() {   # <payload prefix>  -> "relative.key=value" for every leaf under that payload
  /usr/bin/awk -v p="$1." 'index($0, p) == 1 { print substr($0, length(p) + 1) }' "$FLAT" 2>/dev/null
}
flat_val() {   # <payload prefix> <relative key>  -> first value
  flat_get "$1" | /usr/bin/awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }'
}
flat_list() {  # <payload prefix> <array key, e.g. Hosts>  -> every item
  flat_get "$1" | /usr/bin/awk -F= -v k="$2" 'index($1, k "[") == 1 { sub(/^[^=]*=/, ""); print }'
}

print_payload_settings() {   # prints every Platform SSO and extension-data setting the installed SSO payloads define (secrets hidden)
  local p ext typ team n=0
  [[ -s "$FLAT" ]] || { print "    (no Extensible SSO payload found in the installed profiles)"; return 0; }
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    n=$(( n + 1 ))
    ext=$(flat_val "$p" ExtensionIdentifier); typ=$(flat_val "$p" Type); team=$(flat_val "$p" TeamIdentifier)
    print "    payload ${n}: ${ext:-unknown extension}   type=${typ:-?}   team=${team:-?}"
    flat_get "$p" | /usr/bin/awk -F= '
      $1 ~ /^(PlatformSSO|ExtensionData)\./ {
        k = $1; v = $0; sub(/^[^=]*=/, "", v)
        n = split(k, parts, "."); last = parts[n]
        if (last ~ /(Token|Secret)$/) v = "<set; value hidden>"
        printf "        %s = %s\n", k, v
      }'
    flat_list "$p" Hosts | /usr/bin/awk '{ printf "        Hosts: %s\n", $0 }'
    flat_list "$p" URLs  | /usr/bin/awk '{ printf "        URLs: %s\n", $0 }'
    [[ -n "$(flat_val "$p" Realm)" ]] && print "        Realm: $(flat_val "$p" Realm)"
  done <<< "$(sso_prefixes)"
  (( n )) || print "    (no Extensible SSO payload found in the installed profiles)"
}

check_setup_assistant_keys() {   # reports the Setup Assistant (Simplified Setup) keys and whether this Mac can use them
  local p reg first ade="no" shown=0
  [[ -s "$FLAT" ]] || return 0
  /usr/bin/grep -q 'Enrolled via DEP: Yes' "$D3/profiles-status-enrollment.txt" 2>/dev/null && ade="yes"
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    reg=$(flat_val "$p" PlatformSSO.EnableRegistrationDuringSetup); first=$(flat_val "$p" PlatformSSO.EnableCreateFirstUserDuringSetup)
    [[ -z "$reg" && -z "$first" ]] && continue
    shown=1
    if [[ "$ade" == yes ]]; then
      vcheck INFO payload-setup-assistant "EnableRegistrationDuringSetup = ${reg:-not set}, EnableCreateFirstUserDuringSetup = ${first:-not set}; this Mac is ADE-enrolled, so Setup Assistant can use them. Okta documents turning EnableRegistrationDuringSetup on for macOS 26 or later; Apple says to use it when Platform SSO is configured before enrollment. Some Workspace ONE UEM console versions have been reported to stop Setup Assistant on macOS 26 when these keys are on - if a Mac hangs in Setup Assistant, check these two keys first."
    else
      vcheck INFO payload-setup-assistant "EnableRegistrationDuringSetup = ${reg:-not set}, EnableCreateFirstUserDuringSetup = ${first:-not set}; this Mac is not ADE-enrolled, so the Setup Assistant keys have no effect here."
    fi
  done <<< "$(sso_prefixes)"
  (( shown )) || true
}

check_okta() {   # Okta Verify Platform SSO: the documented profile pieces
  local p ext is_okta=0 has_mobile has_ext orgs nurl nhost uhosts vanity ver auth urls miss pairs a b
  [[ "$EXT_ID" == *okta* ]] && is_okta=1
  while IFS= read -r p; do [[ -z "$p" ]] && continue; ext=$(flat_val "$p" ExtensionIdentifier); [[ "$ext" == *okta* ]] && is_okta=1; done <<< "$(sso_prefixes)"
  (( is_okta )) || return 0
  has_mobile=$(/usr/bin/grep -c '\.PayloadType=com\.okta\.mobile$' "$FLAT"); has_ext=$(/usr/bin/grep -c '\.PayloadType=com\.okta\.mobile\.auth-service-extension$' "$FLAT")
  if (( has_mobile > 0 && has_ext > 0 )); then
    vcheck PASS okta-preference-domains "both Okta preference-domain payloads are installed: com.okta.mobile and com.okta.mobile.auth-service-extension"
  else
    miss=""; (( has_mobile )) || miss+="com.okta.mobile "; (( has_ext )) || miss+="com.okta.mobile.auth-service-extension "
    vcheck FAIL okta-preference-domains "Okta requires a preference payload for each of its two preference domains; missing: ${miss% }"
  fi
  orgs=$(/usr/bin/sed -nE 's/^.*\.OktaVerify\.OrgUrl=(.*)$/\1/p' "$FLAT" | /usr/bin/sort -u)
  if [[ -z "$orgs" ]]; then
    vcheck FAIL okta-org-url "no OktaVerify.OrgUrl is defined in any installed payload"
  else
    uhosts=""
    while IFS= read -r p; do [[ -z "$p" ]] && continue; while IFS= read -r a; do [[ -n "$a" ]] && uhosts+="$(url_host "$a")"$'\n'; done <<< "$(flat_list "$p" URLs)"; done <<< "$(sso_prefixes)"
    while IFS= read -r nurl; do
      [[ -z "$nurl" ]] && continue
      nhost=$(url_host "$nurl"); vanity=0
      case "$nhost" in *.okta.com|*.oktapreview.com|*.okta-emea.com|*.okta-gov.com|*.okta.mil) ;; *) vanity=1 ;; esac
      if (( vanity )); then
        vcheck WARN okta-org-url "OktaVerify.OrgUrl host ${nhost} is not an *.okta.com style tenant name (possible custom/vanity domain). Okta's setup pages use the org URL (customerorg.okta.com), and custom (vanity) domains have been reported not to work for Platform SSO. Verify with Okta."
      elif print -r -- "$uhosts" | /usr/bin/grep -qxF "$nhost"; then
        vcheck PASS okta-org-url "OktaVerify.OrgUrl host ${nhost} matches the host in the SSO payload URLs"
      else
        vcheck WARN okta-org-url "OktaVerify.OrgUrl host ${nhost} does not appear in the SSO payload URLs ($(print -r -- "$uhosts" | /usr/bin/sort -u | /usr/bin/tr '\n' ' '))"
      fi
    done <<< "$orgs"
  fi
  ver=$(/usr/bin/sed -nE 's/^.*\.PlatformSSO\.ProtocolVersion=(.*)$/\1/p' "$FLAT" | /usr/bin/sort -u | /usr/bin/head -1)
  if [[ "$ver" == "2.0" ]]; then vcheck PASS okta-protocol-version "PlatformSSO.ProtocolVersion = 2.0, as Okta documents"
  elif [[ -n "$ver" ]]; then vcheck WARN okta-protocol-version "PlatformSSO.ProtocolVersion = ${ver}; Okta's documented value is 2.0"
  else vcheck WARN okta-protocol-version "PlatformSSO.ProtocolVersion is not set; Okta's documented value is 2.0"; fi
  urls=$(while IFS= read -r p; do [[ -n "$p" ]] && flat_list "$p" URLs; done <<< "$(sso_prefixes)")
  auth=$(while IFS= read -r p; do [[ -n "$p" ]] && flat_val "$p" PlatformSSO.AuthenticationMethod; done <<< "$(sso_prefixes)" | /usr/bin/head -1)
  miss=""
  print -r -- "$urls" | /usr/bin/grep -q '/oauth2/v1/token' || miss+="/oauth2/v1/token "
  print -r -- "$urls" | /usr/bin/grep -q '/v1/auth/device-sign' || miss+="/v1/auth/device-sign "
  if [[ "$auth" == *SecureEnclave* ]]; then print -r -- "$urls" | /usr/bin/grep -q '/device-access/api/v1/nonce' || miss+="/device-access/api/v1/nonce "; fi
  if [[ -z "$miss" ]]; then vcheck PASS okta-urls "the SSO payload URLs include the Okta token, device-sign$( [[ "$auth" == *SecureEnclave* ]] && print ' and nonce') paths"
  else vcheck WARN okta-urls "the SSO payload URLs are missing Okta path(s) that Okta documents: ${miss% }"; fi
  pairs=$(ad_pairs "$XMLP")
  a=$(print -r -- "$pairs" | /usr/bin/grep -c '^B7F62B65BN\.com\.okta\.mobile|'); b=$(print -r -- "$pairs" | /usr/bin/grep -c '^B7F62B65BN\.com\.okta\.mobile\.auth-service-extension|')
  if (( a > 0 && b > 0 )); then vcheck PASS okta-associated-domains "the Associated Domains payload has both Okta app identifiers (B7F62B65BN.com.okta.mobile and its auth-service-extension)"
  else vcheck WARN okta-associated-domains "Okta documents an Associated Domains entry for each of B7F62B65BN.com.okta.mobile and B7F62B65BN.com.okta.mobile.auth-service-extension; found ${a} and ${b}"; fi
}

okta_logs_collect() {   # Okta Verify's own logs live in the user's group container; copy the recent ones when present
  local src dst f n=0
  [[ -z "$USER_HOME" ]] && return 0
  src="$USER_HOME/Library/Group Containers/B7F62B65BN.group.okta.macverify.shared/Logs"
  [[ -d "$src" ]] || return 0
  dst="$D4/idp-extension-files/okta-verify"
  /bin/mkdir -p "$dst"
  while IFS= read -r -d '' f; do
    /bin/cp "$f" "$dst/" 2>/dev/null && n=$(( n + 1 ))
    (( n >= 30 )) && break
  done < <(/usr/bin/find "$src" -type f -mtime -3 -size -10M -print0 2>/dev/null)
  log "  Okta Verify logs: copied ${n} file(s) from the last 3 days"
}

# ---- v3.0 part B: AppSSO debug logging, leftover state, Kerberos ----
DSCLBIN=/usr/bin/dscl
DIGBIN=/usr/bin/dig
NCBIN=/usr/bin/nc

appsso_logging_status() {   # read-only: are AppSSO debug logs persisted? (log config --status)
  local out="$D6/appsso-log-config.txt" txt
  capture "$out" "$LOGBIN" config --status --subsystem com.apple.AppSSO
  txt=$(/usr/bin/grep -v '^#' "$out" 2>/dev/null | /usr/bin/tr '\n' ' ' | /usr/bin/sed -E 's/ +/ /g; s/ $//')
  if [[ -z "${txt// /}" ]]; then
    vcheck INFO appsso-debug-logging "could not read the AppSSO log configuration (log config --status printed nothing)"
  elif print -r -- "$txt" | /usr/bin/grep -qiE 'persist[_ :-]*debug'; then
    vcheck INFO appsso-debug-logging "AppSSO debug logging is persisted, so the log slices hold the debug detail: ${txt}"
  else
    vcheck INFO appsso-debug-logging "AppSSO debug logging is NOT persisted (${txt}). The unified-log slices only hold what macOS keeps by default, so an earlier attempt may lack detail. Before you reproduce a problem, run this script with --debug-logging on (Microsoft documents the same log setting), reproduce, run it again, then use --debug-logging off."
  fi
}

check_psso_leftovers() {   # read-only: installed SSO payloads, leftover registration, and the PSSO link on local accounts
  local p ext typ list="" n=0 has_psso=0 line u uid raw uidattr uidchk has_alt has_uid out con st f
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    n=$(( n + 1 )); ext=$(flat_val "$p" ExtensionIdentifier); typ=$(flat_val "$p" Type)
    list+="${ext:-unknown} (${typ:-?}); "
    [[ -n "$(flat_get "$p" | /usr/bin/grep -m1 '^PlatformSSO\.')" ]] && has_psso=1
  done <<< "$(sso_prefixes)"
  if (( n )); then vcheck INFO sso-payloads "${n} Extensible SSO payload(s) installed: ${list%; }"
  else vcheck INFO sso-payloads "no Extensible SSO payload is installed"; fi
  if { [[ "$REG" == true ]] || [[ -n "$UST" ]]; } && (( ! has_psso )); then
    vcheck WARN registration-without-profile "a Platform SSO registration exists (device registered: ${REG:-no}, user state: ${UST:-none}) but no installed SSO payload carries Platform SSO settings. This looks like leftover state: the profile was removed but the registration was not cleaned up. Microsoft documents deregistering in Company Portal > Preferences > Deregister."
  fi
  # the Platform SSO link on each local account (presence only; the values are never copied)
  out="$D2/local-account-psso-link.txt"; : > "$out"
  print "# Platform SSO link on local accounts (presence only; values are not copied)" >> "$out"
  con=$(print -r -- "$CONSOLE_USER" | lc)
  while IFS= read -r u; do
    [[ -z "$u" ]] && continue
    raw=$("$DSCLBIN" . -read "/Users/$u" AltSecurityIdentities 2>/dev/null)
    uidattr=$("$DSCLBIN" . -read "/Users/$u" dsAttrTypeNative:PlatformSSOUniqueIdentifier 2>/dev/null)
    uidchk=$("$DSCLBIN" . -read "/Users/$u" UniqueID 2>/dev/null)   # every account has a UniqueID; an attribute that is simply absent prints nothing
    if [[ -z "$uidchk" ]]; then
      print "account ${u}: directory attributes could not be read" >> "$out"
      vcheck INFO "local-account-psso-link:${u}" "the directory attributes of this account could not be read, so the Platform SSO link was not checked"
      continue
    fi
    has_alt=no; has_uid=no
    print -r -- "$raw" | /usr/bin/grep -q 'PlatformSSO:' && has_alt=yes
    [[ -n "$uidattr" && "$uidattr" != *"No such key"* && "$uidattr" != *"does not exist"* ]] && has_uid=yes
    print "account ${u}: AltSecurityIdentities has a PlatformSSO entry: ${has_alt}; PlatformSSOUniqueIdentifier present: ${has_uid}" >> "$out"
    if [[ "$has_alt" == yes || "$has_uid" == yes ]]; then
      if [[ "$REG" != true ]]; then
        vcheck WARN "local-account-psso-link:${u}" "the account still carries a Platform SSO link (PlatformSSO entry: ${has_alt}, unique identifier: ${has_uid}) but this Mac is not registered - leftover state from an earlier registration"
      else
        vcheck PASS "local-account-psso-link:${u}" "the account carries a Platform SSO link (PlatformSSO entry: ${has_alt}, unique identifier: ${has_uid})"
      fi
    elif [[ "$(print -r -- "$u" | lc)" == "$con" && "$REG" == true && "$UST" == *Normal* ]]; then
      vcheck INFO "local-account-psso-link:${u}" "this Mac and user show as registered, but the logged-in account carries no PlatformSSO entry in AltSecurityIdentities. Microsoft says a Platform Single Sign-on section normally appears under the account in System Settings > Users & Groups; check it there (the attribute check itself is not verified for every extension)."
    fi
  done <<< "$(/usr/bin/grep -v '^#' "$D2/local-accounts-list.txt" 2>/dev/null | /usr/bin/awk '$2 ~ /^[0-9]+$/ && $2 + 0 >= 500 { print $1 }' | /usr/bin/head -8)"
}

kerberos_state_rows() {   # <app-sso platform -s output> -> realm|importSuccessful|failedToConnect|exchangeRequired for each kerberosStatus entry
  /usr/bin/awk '
    /"kerberosStatus"/ { inb = 1; next }
    inb && /^  \]/ { inb = 0 }
    inb && /"realm"/ { v = $0; sub(/^[^:]*: *"/, "", v); sub(/".*$/, "", v); realm = v }
    inb && /"importSuccessful"/ { imp = ($0 ~ /true/) ? "true" : "false" }
    inb && /"failedToConnect"/ { fail = ($0 ~ /true/) ? "true" : "false" }
    inb && /"exchangeRequired"/ { exch = ($0 ~ /true/) ? "true" : "false" }
    inb && /^    \}/ { print realm "|" imp "|" fail "|" exch; realm = ""; imp = ""; fail = ""; exch = "" }
  ' "$1" 2>/dev/null
}

kerberos_klist_tgts() {   # <klist output> -> "krbtgt principal|issued|expires" per TGT
  /usr/bin/awk '/krbtgt\// { iss = substr($0, 1, 20); expv = substr($0, 23, 20); n = split($0, f, " "); print f[n] "|" iss "|" expv }' "$1" 2>/dev/null
}

kerberos_url_test() {   # one --kerberos-url: curl --negotiate as the logged-in user, then look for the HTTP/<host> service ticket in klist
  local url="$1" idx="$2" host code out kl rc
  host=$(url_host "$url"); out="$D6/kerberos-url-${idx}.txt"
  code=$(run_as_user /usr/bin/curl -sS -o /dev/null -D "$out.hdr" -w '%{http_code}' --negotiate -u : --max-time 15 --max-redirs 0 "$url" 2>"$out.err"); rc=$?
  { print "# curl --negotiate -u : (run as ${CONSOLE_USER}) ${url}"; print "# HTTP code: ${code:-none}   curl rc: ${rc}"; /usr/bin/sed -E 's/^(Authorization|Cookie):.*/\1: <hidden>/' "$out.hdr" 2>/dev/null; /bin/cat "$out.err" 2>/dev/null; } > "$out"
  /bin/rm -f "$out.hdr" "$out.err"
  kl=$(run_as_user /usr/bin/klist 2>/dev/null)
  if (( rc == 2 )); then
    vcheck INFO "kerberos-url:${url}" "this Mac's curl does not support --negotiate, so the Kerberos web test could not run"
  elif print -r -- "$kl" | /usr/bin/grep -qi "HTTP/${host}"; then
    vcheck PASS "kerberos-url:${url}" "HTTP ${code:-?} and klist shows a service ticket for HTTP/${host}: the Kerberos sign-in worked"
  elif [[ "$code" == 401 ]]; then
    vcheck WARN "kerberos-url:${url}" "the server answered 401 and no service ticket for HTTP/${host} was issued. Possible causes: no TGT, the host is not in the Kerberos extension's Hosts, a wrong SPN, or the domain controller cannot be reached."
  elif [[ -z "$code" || "$code" == 000 ]]; then
    vcheck WARN "kerberos-url:${url}" "the web server could not be reached (curl rc=${rc})"
  else
    vcheck INFO "kerberos-url:${url}" "HTTP ${code}; no service ticket for HTTP/${host} is in klist (the page may not require Kerberos)"
  fi
}

check_kerberos() {   # gated: only when a Kerberos extension payload, a Kerberos status in the PSSO state, or --kerberos-url is present
  local ri ri_login ri_pw ri_site ri_net tgp tgr tgi tge p ext realm hosts nh state_rows has_state=0 has_payload=0 row r imp fail exch tg line realms="" dup r2 srv h cloud=KERBEROS.MICROSOFTONLINE.COM all_hosts idx=0 u
  /usr/bin/grep -q '"kerberosStatus"' "$S_STATE" 2>/dev/null && has_state=1
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    ext=$(flat_val "$p" ExtensionIdentifier)
    if [[ "$ext" == *KerberosExtension* || -n "$(flat_val "$p" Realm)" ]]; then
      has_payload=1; realm=$(flat_val "$p" Realm); nh=$(flat_list "$p" Hosts | /usr/bin/grep -c .)
      vcheck INFO kerberos-extension-config "Kerberos extension payload: Realm ${realm:-not set}, ${nh} host(s) listed"
      [[ -n "$realm" ]] && realms+="${realm}"$'\n'
    fi
  done <<< "$(sso_prefixes)"
  if (( ! has_state && ! has_payload && ${#KERBEROS_URLS[@]} == 0 )); then return 0; fi
  # Apple: Hosts must be unique across all installed Extensible SSO payloads
  all_hosts=$(while IFS= read -r p; do [[ -n "$p" ]] && flat_list "$p" Hosts; done <<< "$(sso_prefixes)" | lc | /usr/bin/sort)
  dup=$(print -r -- "$all_hosts" | /usr/bin/uniq -d | /usr/bin/tr '\n' ' ')
  if [[ -n "$dup" ]]; then vcheck WARN kerberos-hosts-unique "Apple requires every Hosts entry to be unique across all installed Extensible SSO payloads; listed more than once: ${dup% }"
  elif [[ -n "$all_hosts" ]]; then vcheck PASS kerberos-hosts-unique "no Hosts entry is listed twice across the installed SSO payloads"; fi
  # what the PSSO state says about its Kerberos tickets
  if (( has_state )); then
    while IFS= read -r row; do
      [[ -z "$row" ]] && continue
      IFS='|' read -r r imp fail exch <<< "$row"
      realms+="${r}"$'\n'
      if [[ "$fail" == true ]]; then vcheck WARN "kerberos-status:${r}" "the PSSO state says it failed to connect to the Kerberos service for ${r} (importSuccessful=${imp}, failedToConnect=true) - check the network path to the domain controller or Entra"
      elif [[ "$imp" == true && "$exch" != true ]]; then vcheck PASS "kerberos-status:${r}" "the PSSO state reports the Kerberos ticket import for ${r} succeeded"
      else vcheck WARN "kerberos-status:${r}" "the PSSO state reports importSuccessful=${imp}, exchangeRequired=${exch} for ${r}"; fi
    done <<< "$(kerberos_state_rows "$S_STATE")"
  fi
  # the tickets the logged-in user holds right now (klist must run as that user; as root it would show root's cache)
  if [[ ! -f "$D6/klist.txt" ]]; then capture_user "$D6/klist.txt" klist; fi
  tg=$(kerberos_klist_tgts "$D6/klist.txt")
  if [[ -n "$tg" ]]; then
    while IFS= read -r line; do
      tgp="${line%%|*}"; tgr="${line#*|}"; tgi="${tgr%%|*}"; tge="${line##*|}"
      vcheck INFO kerberos-tgt-times "TGT ${tgp}: issued ${tgi}, expires ${tge}"
    done <<< "$tg"
  else
    vcheck WARN kerberos-tgt-times "klist (run as the logged-in user) shows no krbtgt ticket although Kerberos is configured"
  fi
  # configured realms and their domain controllers
  [[ -f "$D2/app-sso-listrealms.txt" ]] || capture_user "$D2/app-sso-listrealms.txt" app-sso -l
  realms+=$(/usr/bin/grep -v '^#' "$D2/app-sso-listrealms.txt" 2>/dev/null | /usr/bin/sed -nE 's#.*<string>([^<]+)</string>.*#\1#p')$'\n'
  realms=$(print -r -- "$realms" | /usr/bin/grep -v '^$' | /usr/bin/sort -u)
  if [[ -z "$realms" ]]; then
    vcheck INFO kerberos-realms "no Kerberos realm is configured through the Kerberos extension (app-sso -l is empty) or the PSSO state"
  else
    vcheck INFO kerberos-realms "Kerberos realm(s): $(print -r -- "$realms" | /usr/bin/tr '\n' ' ')"
    while IFS= read -r r; do
      [[ -z "$r" ]] && continue
      if [[ "$(print -r -- "$r" | /usr/bin/tr '[:lower:]' '[:upper:]')" == "$cloud" ]]; then
        vcheck INFO "kerberos-dc:${r}" "cloud Kerberos realm: the ticket is issued through Microsoft Entra ID, so there is no domain controller to reach, and it is not a Kerberos extension realm, so app-sso -i is not run for it"
        continue
      fi
      capture_user "$D2/app-sso-realminfo-${r}.txt" app-sso -i "$r"
      ri="$D2/app-sso-realminfo-${r}.txt"
      ri_login=$(plist_str "$ri" login_date); ri_pw=$(plist_str "$ri" password_changed_date); ri_site=$(plist_str "$ri" site_code); ri_net=$(plist_str "$ri" networkAvailable)
      if [[ -n "${ri_login}${ri_pw}${ri_site}${ri_net}" ]]; then
        if [[ "$ri_net" == 0 ]]; then
          vcheck WARN "kerberos-realm-info:${r}" "app-sso reports networkAvailable=0 for this realm (judging by the name, the Kerberos extension currently considers the network unavailable). Last Kerberos login ${ri_login:-unknown} (UTC), password last changed ${ri_pw:-unknown} (UTC), AD site ${ri_site:-none}. Compare with the kerberos-dc line."
        else
          vcheck INFO "kerberos-realm-info:${r}" "last Kerberos login ${ri_login:-unknown} (UTC), password last changed ${ri_pw:-unknown} (UTC), AD site ${ri_site:-none}, networkAvailable=${ri_net:-unknown}"
        fi
      fi
      srv=$("$DIGBIN" +short +time=3 +tries=1 SRV "_kerberos._tcp.${r}" 2>/dev/null | /usr/bin/head -3)
      { print "# dig SRV _kerberos._tcp.${r}"; print -r -- "$srv"; } > "$D6/kerberos-dc-${r}.txt"
      if [[ -z "$srv" ]]; then
        vcheck WARN "kerberos-dc:${r}" "no DNS SRV record for _kerberos._tcp.${r} (Kerberos clients find domain controllers this way). Off the corporate network or VPN this is expected."
      else
        h=$(print -r -- "$srv" | /usr/bin/head -1 | /usr/bin/awk '{ sub(/\.$/, "", $4); print $4 }')
        if "$NCBIN" -z -G 3 "$h" 88 >/dev/null 2>&1; then vcheck PASS "kerberos-dc:${r}" "a domain controller for ${r} (${h}) accepts connections on TCP 88"
        else vcheck WARN "kerberos-dc:${r}" "a domain controller for ${r} (${h}) did not accept a connection on TCP 88 within 3 seconds - without it new tickets cannot be issued and Kerberos sites return 401"; fi
      fi
    done <<< "$realms"
  fi
  for u in "${KERBEROS_URLS[@]}"; do idx=$(( idx + 1 )); kerberos_url_test "$u" "$idx"; done
}

# ---- v3.0 part C: the plain-language RESULT and the DIAGNOSIS section ----
last_attempt_outcome() {   # prints "success|<UTC time>", "failed|<UTC time>" or "none|" for the last device registration attempt
  local tl line when
  tl=$(apple_registration_timeline "$D4/log-show-registration-timeline-with-tz.txt" 2>/dev/null)
  line=$(print -r -- "$tl" | /usr/bin/grep -E 'registration finished \(success=' | /usr/bin/tail -1)
  [[ -z "$line" ]] && { print "none|"; return; }
  when=$(print -r -- "$line" | /usr/bin/sed -E 's/^ *([0-9-]+ [0-9:]+ UTC).*/\1/')
  if [[ "$line" == *"success=1"* ]]; then print "success|${when}"; else print "failed|${when}"; fi
}

prompt_counts() {   # -> "shown responded" from the registration timeline slice
  local f="$D4/log-show-registration-timeline-with-tz.txt" a b
  a=$(/usr/bin/grep -v '^#' "$f" 2>/dev/null | /usr/bin/grep -c 'Presenting <NotificationRecord app:"com.apple.PlatformSSO')
  b=$(/usr/bin/grep -v '^#' "$f" 2>/dev/null | /usr/bin/grep -c 'Received response <NotificationRecord app:"com.apple.PlatformSSO')
  print "${a:-0} ${b:-0}"
}

compute_result() {   # sets RESULT_CODE and RESULT_LINE (one plain sentence) and RESULT_WHY (one more sentence)
  local nfail nwarn has_cfg=0 has_krb=0 krb_realm="" e2 r2 nkf nkw nkp nother p outcome LA_TIME shown responded lastlogin
  nfail=$(/usr/bin/grep -c '^FAIL|' "$VAL" 2>/dev/null); nwarn=$(/usr/bin/grep -c '^WARN|' "$VAL" 2>/dev/null)
  [[ -n "$EXT_ID" ]] && has_cfg=1
  while IFS= read -r p; do [[ -z "$p" ]] && continue; [[ -n "$(flat_get "$p" | /usr/bin/grep -m1 '^PlatformSSO\.')" ]] && has_cfg=1; done <<< "$(sso_prefixes)"
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    e2=$(flat_val "$p" ExtensionIdentifier); r2=$(flat_val "$p" Realm)
    if [[ "$e2" == *KerberosExtension* || -n "$r2" ]]; then has_krb=1; krb_realm="$r2"; fi
  done <<< "$(sso_prefixes)"
  IFS="|" read -r outcome LA_TIME <<< "$(last_attempt_outcome)"; read -r shown responded <<< "$(prompt_counts)"
  lastlogin=$(state_val lastLoginDate)
  RESULT_WHY=""
  if [[ "$REG" != true ]]; then
    if (( ! has_cfg )) && [[ -z "$UST" ]]; then
      if (( has_krb )); then
        nkf=$(/usr/bin/grep -cE '^FAIL\|kerberos' "$VAL" 2>/dev/null); nkw=$(/usr/bin/grep -cE '^WARN\|kerberos' "$VAL" 2>/dev/null); nkp=$(/usr/bin/grep -cE '^PASS\|kerberos' "$VAL" 2>/dev/null)
        nother=$(( nfail - ${nkf:-0} ))
        RESULT_CODE="KERBEROS-ONLY"; RESULT_LINE="This Mac does not use Platform SSO. It uses the Kerberos extension (realm ${krb_realm:-not set})."
        if (( ${nkf:-0} + ${nkw:-0} > 0 )); then RESULT_WHY="${nkf:-0} Kerberos check(s) failed and ${nkw:-0} need attention. Read the kerberos-* lines and the DIAGNOSIS."
        elif (( ${nkp:-0} > 0 )); then RESULT_WHY="${nkp} Kerberos check(s) passed and none failed."
        else RESULT_WHY="No Kerberos check could judge the result; see the kerberos-* lines."; fi
        RESULT_WHY="${RESULT_WHY} The Platform SSO checks do not apply and are skipped.$( (( nother > 0 )) && print " ${nother} other check(s) failed.")"
      else
        RESULT_CODE="NO-PSSO"; RESULT_LINE="No Platform SSO configuration was found on this Mac."
        RESULT_WHY="There is no SSO profile with Platform SSO settings and no registration. Check that the profile is assigned and installed (System Settings > General > Device Management)."
      fi
    else
      RESULT_CODE="NOT-REGISTERED"; RESULT_LINE="Platform SSO is NOT registered on this Mac."
      if [[ "$outcome" == failed ]]; then RESULT_WHY="The last registration attempt (${LA_TIME}) FAILED."
      elif (( shown > 0 && responded == 0 )); then RESULT_WHY="${shown} registration prompt(s) were shown and none was answered. The user must open the Platform SSO notification and sign in."
      elif (( shown > 0 )); then RESULT_WHY="${shown} registration prompt(s) were shown and the user answered ${responded}, but no registration attempt finished in the last ${LOG_WINDOW}."
      else RESULT_WHY="No registration attempt was found in the last ${LOG_WINDOW}. The profile may be new, the notification may not have appeared, or the window is too short (use --log-window)."; fi
    fi
  elif [[ -z "$UST" || "$UST" != *Normal* ]]; then
    RESULT_CODE="DEVICE-ONLY"; RESULT_LINE="The Mac is registered, but the user is NOT registered."
    RESULT_WHY="User state: ${UST:-none}. The user still has to complete the registration, or it failed."
  elif (( nfail > 0 )); then
    RESULT_CODE="REGISTERED-WITH-FAILURES"; RESULT_LINE="Platform SSO is registered (user state Normal), but ${nfail} automated check(s) FAILED."
    RESULT_WHY="Registration works, but something around it is wrong. Read the DIAGNOSIS and the FAIL lines below."
  else
    RESULT_CODE="REGISTERED"; RESULT_LINE="Platform SSO is REGISTERED and the user state is Normal."
    RESULT_WHY="No automated check failed (${nwarn} warning(s)). Last login: ${lastlogin:-not shown}."
  fi
}

build_diagnosis() {   # prints only; reads $VAL and the logs. Plain sentences: what we see, what it means, what to do.
  local n=0 nonhttps outcome LA_TIME shown responded vhas doms d sw swv apps has_psso=0
  psso_configured && has_psso=1
  vhas() { /usr/bin/grep -qE "^$1" "$VAL" 2>/dev/null; }
  dx() { n=$(( n + 1 )); print "  ${n}. $1"; print "       What it means: $2"; print "       What to do:    $3"; }
  nonhttps=$(/usr/bin/grep -rhs 'non-https' "$D4/idp-extension-files" 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')
  IFS="|" read -r outcome LA_TIME <<< "$(last_attempt_outcome)"; read -r shown responded <<< "$(prompt_counts)"
  print "DIAGNOSIS (what the checks suggest; confirm in the raw files)"
  if (( ${nonhttps:-0} > 0 )) || vhas 'FAIL\|signin-authorize'; then
    dx "The Microsoft sign-in step failed with MSAL error -51116, 'The server has redirected to a non-https url' (${nonhttps:-0} matching line(s) in the extension log)." \
       "Microsoft's sign-in service does not redirect to plain http, so something between this Mac and Microsoft (a web filter, VPN, proxy or security agent) is probably answering instead." \
       "Look at the network-agent lines in the list below. Ask your security team to repeat the registration with those products off, or to exempt Microsoft sign-in and the Company Portal SSO extension. Run this script with --tests-only right after the next attempt."
  fi
  if vhas 'FAIL\|apple-cdn-tls'; then
    dx "Apple's AASA servers (app-site-association.cdn-apple.com and app-site-association.networking.apple) are being TLS-inspected on this network." \
       "macOS validates each SSO extension through Apple's CDN. Microsoft documents that these two domains must not be TLS-inspected." \
       "Ask the network team to exempt *.cdn-apple.com and *.networking.apple from TLS inspection, then register again."
  fi
  if vhas 'FAIL\|payload-foreign-domain:'; then
    doms=$(/usr/bin/grep -E '^FAIL\|payload-foreign-domain:' "$VAL" | /usr/bin/cut -d'|' -f2 | /usr/bin/sed 's/^[^:]*://' | /usr/bin/sort -u | /usr/bin/tr '\n' ' ')
    dx "The profile lists a domain that belongs to another vendor: ${doms% }." \
       "That domain's own AASA file lists only the other vendor's apps, so macOS refuses to let this extension act for it. The entry cannot work, and a URL kept in the URLs list stays reserved, so the vendor's own SSO profile could not use it." \
       "Remove the domain from the URLs list and from the Associated Domains payload. See the payload-foreign-domain line for the evidence, including what macOS decided."
  fi
  if vhas 'FAIL\|(domain-association|aasa-origin|aasa-cdn)' || /usr/bin/grep -qE '^WARN\|pair:.*DENIED' "$VAL" 2>/dev/null; then
    doms=$( { /usr/bin/grep -E '^FAIL\|(domain-association|aasa-origin|aasa-cdn):' "$VAL" | /usr/bin/cut -d'|' -f2 | /usr/bin/sed -E 's/^[^:]+://'; /usr/bin/grep -E '^WARN\|pair:.*DENIED' "$VAL" | /usr/bin/cut -d'|' -f2 | /usr/bin/sed -E 's/^pair:[^@]*@//'; } | /usr/bin/sort -u )
    dx "macOS or the domain's AASA file does not authorize the extension for: $(print -r -- "$doms" | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/ $//')." \
       "An extension may only act for a domain when that domain's own apple-app-site-association file lists the app. Without that, macOS refuses." \
       "See the per-domain lines below. If a domain's file lists only other apps, adding that domain to your profile cannot make this extension act for it: remove the entry, or use the extension the domain's file names. A missing profile entry can be added; a file on someone else's domain cannot be changed."
    print "       Per domain:"
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      sw=$(/usr/bin/grep -E "^[A-Z]+\|domain-association:${d}\|" "$VAL" | /usr/bin/head -1)
      [[ -z "$sw" ]] && sw=$(/usr/bin/grep -E "^[A-Z]+\|pair:[^|]*@${d}\|" "$VAL" | /usr/bin/head -1)
      case "$sw" in *DENIED*) swv="denied";; *"approved for this extension"*) swv="approved";; "") swv="no entry judged";; *) swv="not approved";; esac
      apps=$(/usr/bin/grep -E "^FAIL\|aasa-cdn:${d}\|" "$VAL" | /usr/bin/sed -nE 's/^[^|]*\|[^|]*\|authsrv lists \[([^]]*)\].*/\1/p' | /usr/bin/head -1)
      print "         - ${d}: swcutil says ${swv}; the domain's AASA file lists: ${apps:-(not shown)}"
    done <<< "$doms"
  fi
  if (( has_psso )) && [[ "$REG" != true ]] && (( shown > 0 && responded == 0 )); then
    dx "${shown} registration prompt(s) were shown and none was answered." \
       "Registration only starts after the user opens the Platform SSO notification and signs in. Microsoft notes that users can swipe it away or close the dialog." \
       "Ask the user to open the notification, or to sign out and in again to bring it back, and complete the sign-in."
  fi
  if (( has_psso )) && [[ "$outcome" == failed && "$REG" != true ]] && (( ${nonhttps:-0} == 0 )); then
    dx "The last registration attempt (${LA_TIME}) failed." \
       "macOS logs the reason as <private>. The extension's own log usually has the real reason." \
       "Read the files under 04-psso-registration-logs/idp-extension-files (Company Portal or Okta Verify logs) and the Hub logs. If AppSSO debug logging was off, run --debug-logging on, reproduce the problem, and run the script again."
  fi
  if vhas 'FAIL\|extension-installed'; then
    dx "The SSO extension named in the profile is not registered with macOS." \
       "macOS cannot find the extension app that the profile points to." \
       "Check that the app (Company Portal, Okta Verify or Hub) is installed, then check the extension-installed line."
  fi
  if vhas '(WARN|FAIL)\|clock-skew'; then
    dx "This Mac's clock differs from Apple's time server." \
       "Assertions and tokens carry timestamps, and a large offset can make the identity provider reject them." \
       "Turn on automatic date and time (System Settings > General > Date & Time) and run the script again."
  fi
  if vhas 'WARN\|hub-allow-list'; then
    dx "Microsoft's extension turned the Hub app away." \
       "Hub's own sign-in requests to Microsoft are matched by Microsoft's extension and rejected unless Hub is allowed." \
       "See the hub-allow-list line for the settings involved. The effect on users was not measured."
  fi
  if vhas 'WARN\|(registration-without-profile|local-account-psso-link)'; then
    dx "There is leftover or mismatched Platform SSO state." \
       "A registration or an account link exists without a matching profile or registration, which usually follows a profile removal." \
       "Microsoft documents deregistering in Company Portal > Preferences > Deregister; wiping the Mac is often faster. See the registration-without-profile and local-account-psso-link lines."
  fi
  if vhas '(WARN|FAIL)\|(kerberos-status|kerberos-dc|kerberos-hosts-unique|kerberos-url|kerberos-tgt-times|kerberos-realm-info)'; then
    dx "A Kerberos check needs attention." \
       "Kerberos tickets cannot be issued or used until the realm, the domain controller and the Hosts list are right." \
       "See the kerberos-* lines: they say whether the PSSO state, the domain controller lookup, the Hosts list or the test URL is the problem."
  fi
  if vhas '(WARN|FAIL)\|okta-'; then
    dx "An Okta profile check needs attention." \
       "Okta documents a specific profile: two preference-domain payloads, two Associated Domains entries and three URL paths." \
       "See the okta-* lines for what is missing or different."
  fi
  if vhas '(FAIL)\|payload-(extension-identity|auth-method|urls-unique)'; then
    dx "The profile and the Mac disagree." \
       "The installed payload names a different extension or method than the one macOS loaded, or lists a URL twice." \
       "See the payload-* lines, and compare the payload settings printed further down with the vendor's documentation."
  fi
  if (( has_psso )) && [[ "$REG" != true || "$outcome" == failed ]] && /usr/bin/grep -q '^INFO|appsso-debug-logging|AppSSO debug logging is NOT persisted' "$VAL" 2>/dev/null; then
    dx "AppSSO debug logging is not persisted on this Mac." \
       "macOS keeps debug messages only briefly unless asked to persist them, so details of an earlier attempt may be missing from the logs." \
       "Run sudo ./${SCRIPT_PATH:t} --debug-logging on, reproduce the problem, run the script again, then use --debug-logging off."
  fi
  (( n )) || print "  The automated checks found nothing to fix."
}

psso_configured() {   # true when this Mac has Platform SSO settings in an SSO payload, or any registration state
  local p
  { [[ -n "$(state_val registrationCompleted)" ]] || [[ -n "$(state_val state)" ]] || [[ -n "$(state_val extensionIdentifier)" ]]; } && return 0
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    [[ -n "$(flat_get "$p" | /usr/bin/grep -m1 '^PlatformSSO\.')" ]] && return 0
  done <<< "$(sso_prefixes)"
  return 1
}

krb_configured() {   # true when a Kerberos extension payload, or a Kerberos status in the PSSO state, is present
  local p
  /usr/bin/grep -q '"kerberosStatus"' "$S_STATE" 2>/dev/null && return 0
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    [[ "$(flat_val "$p" ExtensionIdentifier)" == *KerberosExtension* || -n "$(flat_val "$p" Realm)" ]] && return 0
  done <<< "$(sso_prefixes)"
  return 1
}

plist_str() {   # <plist file> <key> -> the <string> value that follows <key>
  /usr/bin/awk -v k="$2" '$0 ~ "<key>" k "</key>" { getline; v = $0; gsub(/<[^>]*>/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit }' "$1" 2>/dev/null
}

check_apple_cdn_tls() {
  local h iss
  for h in app-site-association.cdn-apple.com app-site-association.networking.apple; do
    http_probe "apple-$h" GET "https://$h/"
    iss=$(tls_issuer "$HP_VERB")
    if [[ "$HP_CODE" != 000 ]]; then
      if [[ "$iss" == *Apple* ]]; then
        vcheck PASS "apple-cdn-tls:$h" "reachable; TLS issuer '$iss' (not intercepted)"
      else
        vcheck FAIL "apple-cdn-tls:$h" "reachable but TLS issuer is '${iss:-unknown}', not Apple - TLS inspection suspected (Apple/Microsoft state this host must not be inspected)"
      fi
    else
      vcheck WARN "apple-cdn-tls:$h" "could not connect (curl rc=$HP_RC) - firewall/proxy may block Apple's AASA CDN"
    fi
  done
}

check_idp_endpoints() {
  local u kp
  u=$(state_val jwksEndpointURL)
  if [[ -n "$u" && "$u" != "<null>" ]]; then
    http_probe idp-jwks GET "$u" -H 'Accept: application/json'
    if [[ "$HP_CODE" == 200 ]] && /usr/bin/grep -q '"keys"' "$HP_BODY"; then
      vcheck PASS idp-jwks "HTTP 200 with a JWKS key set ($u)"
    else
      vcheck FAIL idp-jwks "HTTP ${HP_CODE} (curl rc=$HP_RC) or no key set at $u"
    fi
  else
    vcheck SKIP idp-jwks "no jwksEndpointURL in state"
  fi
  u=$(state_val nonceEndpointURL)
  [[ -z "$u" || "$u" == "<null>" ]] && u=$(state_val tokenEndpointURL)   # Apple: nonce endpoint defaults to the token endpoint
  kp=$(state_val nonceResponseKeypath)
  [[ -z "$kp" || "$kp" == "<null>" ]] && kp=Nonce                        # Apple: default key path is Nonce
  if [[ -n "$u" && "$u" != "<null>" ]]; then
    http_probe idp-nonce POST "$u" -H 'Accept: application/json' -H 'Content-Type: application/x-www-form-urlencoded' -H "client-request-id: $(/usr/bin/uuidgen)" -d 'grant_type=srv_challenge'
    if [[ "$HP_CODE" == 200 ]] && /usr/bin/grep -q "\"$kp\"" "$HP_BODY"; then
      vcheck PASS idp-nonce "HTTP 200 and the response contains \"$kp\" (Apple server-nonce request, no credentials sent) - $u"
    else
      vcheck FAIL idp-nonce "HTTP ${HP_CODE} (curl rc=$HP_RC), no \"$kp\" in the response: $(/usr/bin/head -c 120 "$HP_BODY" 2>/dev/null | /usr/bin/tr '\n' ' ')"
    fi
    /usr/bin/sed -E "s/(\"$kp\"[[:space:]]*:[[:space:]]*\")[^\"]+/\1[REDACTED]/" "$HP_BODY" > "$HP_BODY.red" 2>/dev/null && /bin/mv "$HP_BODY.red" "$HP_BODY"
  else
    vcheck SKIP idp-nonce "no nonceEndpointURL/tokenEndpointURL in state"
  fi
  u=$(state_val tokenEndpointURL)
  if [[ -n "$u" && "$u" != "<null>" ]]; then
    http_probe idp-token HEAD "$u"
    if [[ "$HP_CODE" != 000 ]]; then
      vcheck PASS idp-token "token endpoint reachable over TLS (HTTP ${HP_CODE}; issuer '$(tls_issuer "$HP_VERB")') - $u"
    else
      vcheck FAIL idp-token "token endpoint unreachable (curl rc=$HP_RC) - $u"
    fi
  else
    vcheck SKIP idp-token "no tokenEndpointURL in state"
  fi
}

validation_summary() {
  local p w f i s
  p=$(/usr/bin/grep -c '^PASS|' "$VAL"); w=$(/usr/bin/grep -c '^WARN|' "$VAL"); f=$(/usr/bin/grep -c '^FAIL|' "$VAL")
  i=$(/usr/bin/grep -c '^INFO|' "$VAL"); s=$(/usr/bin/grep -c '^SKIP|' "$VAL")
  print "[PSSO validation summary] PASS=${p:-0}  WARN=${w:-0}  FAIL=${f:-0}  INFO=${i:-0}  SKIP=${s:-0}   (every check is listed under 'PSSO validation checks'; raw evidence is in 06-validation/)"
  /usr/bin/grep -E '^(FAIL|WARN)\|' "$VAL" | while IFS='|' read -r st name det; do print "    $st  $name - $det"; done
}

validation_full() {
  local st name det
  print "[PSSO validation checks]"
  while IFS='|' read -r st name det; do printf '    %-5s %s - %s\n' "$st" "$name" "$det"; done < "$VAL"
}

hub_health_details() {   # <log show --style default slice of '[platformSSO] health' lines> -> attributes per evaluation, UTC
  local out ts st attrs
  out=$(/usr/bin/awk '
    /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] / {
      match($0, /^[0-9-]+ [0-9:]+\.[0-9]+[+-][0-9][0-9][0-9][0-9]/); stamp=substr($0, RSTART, RLENGTH); sub(/\.[0-9]+/, "", stamp)
      inattr=0
      if (match($0, /\[platformSSO\] health attributes: /)) { inattr=1; attrs=substr($0, RSTART+RLENGTH); next }
      if (match($0, /\[platformSSO\] health state is [a-z]+/)) { st=substr($0, RSTART+30, RLENGTH-30); print stamp "|" st "|" attrs; attrs="" }
      next
    }
    inattr && /[^ \t]/ { attrs = attrs "; " $0 }
  ' "$1" 2>/dev/null)
  if [[ -n "$out" ]]; then
    print -r -- "$out" | while IFS='|' read -r ts st attrs; do
      print -r -- "    $(stamp_utc "$ts")   [device clock $ts]   $st: $attrs"
    done
  fi
}

write_sysdiagnose_record() {   # prints the record; needs SD_* variables set by the sysdiagnose step
  print "SYSDIAGNOSE CAPTURE RECORD"
  print "=========================="
  print "This text file is NOT part of Apple's archive. ${SCRIPT_PATH:t} v$SCRIPT_VERSION wrote it to document how the"
  print "archive in this folder was produced. The .tar.gz is Apple's own sysdiagnose output, unmodified."
  print ""
  print "ARCHIVE"
  if [[ -n "$SD_OUT" ]]; then
    print "  file    : ${SD_OUT:t}"
    print "  size    : $(/usr/bin/wc -c < "$SD_OUT" | /usr/bin/tr -d ' ') bytes"
    print "  SHA-256 : $(/usr/bin/shasum -a 256 "$SD_OUT" | /usr/bin/awk '{print $1}')"
  else
    print "  (no archive was produced - see 'sysdiagnose output' below)"
  fi
  print ""
  print "COMMAND THAT WAS RUN"
  print "  /usr/bin/sysdiagnose ${SD_FLAGS[*]}"
  print "  - run as root (started with sudo by the account '${SUDO_USER:-root}'; desktop user: ${CONSOLE_USER:-none})"
  print "  - the folder after -f is ${SCRIPT_PATH:t}'s temporary working folder; it is zipped into this bundle as is"
  print "  - 'y' was piped to standard input to answer a confirmation prompt if one appeared"
  print "    (the output below shows whether sysdiagnose asked anything)"
  print "  - -u and -b were added only because this macOS lists them in its own usage text (reproduced at the end)"
  print "  Equivalent command to reproduce it by hand:  sudo /usr/bin/sysdiagnose -f <any folder> -u -b"
  print ""
  print "WHEN"
  print "  started  : $SD_START_LOCAL   ($SD_START_UTC)"
  print "  finished : $SD_END_LOCAL   ($SD_END_UTC)"
  print "  attempts : $SD_TRIES   (the script waits and retries while another sysdiagnose is running)"
  print "  exit code: $SD_RC"
  print ""
  print "THIS MAC"
  /usr/bin/sw_vers 2>/dev/null | /usr/bin/tr -s '\t' ' ' | /usr/bin/sed 's/^/  /'
  print "  model: $(/usr/sbin/sysctl -n hw.model 2>/dev/null)"
  print ""
  print "SYSDIAGNOSE OUTPUT (what the command printed, verbatim)"
  print -r -- "--------------------------------------------------------"
  /bin/cat "$SD_STDOUT" 2>/dev/null
  print ""
  print "SYSDIAGNOSE USAGE TEXT ON THIS MAC (sysdiagnose -h, verbatim)"
  print -r -- "--------------------------------------------------------------"
  print -r -- "$SD_HELP"
}

number_files() {   # number_files <dir> <name>...  -> NN-<name> in the order given; leftovers are numbered after them
  local dir="$1" n=0 name
  shift
  for name in "$@"; do
    [[ -e "$dir/$name" ]] || continue
    n=$(( n + 1 ))
    /bin/mv "$dir/$name" "$dir/$(printf '%02d' "$n")-$name" && RENAMES+=("$name|$(printf '%02d' "$n")-$name")
  done
  while IFS= read -r name; do
    [[ -z "$name" || "$name" == [0-9][0-9]-* ]] && continue
    n=$(( n + 1 ))
    /bin/mv "$dir/$name" "$dir/$(printf '%02d' "$n")-$name" && RENAMES+=("$name|$(printf '%02d' "$n")-$name")
  done < <(/bin/ls -1 "$dir" 2>/dev/null)
}

rewrite_renamed_names() {   # rewrite_renamed_names <text file>...  -> old file names become their numbered names
  local e old new esc f script="$STAGE/renames.sed"
  : > "$script"
  for e in "${RENAMES[@]}"; do
    old="${e%%|*}"; new="${e#*|}"
    [[ "$old" == *.* ]] || continue
    esc="${old//./\\.}"
    print -r -- "s/(^|[^A-Za-z0-9._-])${esc}/\\1${new}/g" >> "$script"
  done
  for f in "$@"; do
    [[ -f "$f" ]] && /usr/bin/sed -E -f "$script" "$f" > "$f.tmp" && /bin/mv "$f.tmp" "$f"
  done
}

# ---- payload settings vs facts about this Mac ----
xml_nested_value() {   # <profiles xml> <outer key> <inner key>  -> first string value of inner key inside the outer key's dict
  /usr/bin/awk -v outer="<key>$2</key>" -v inner="<key>$3</key>" '
    index($0, outer) { s=1; next }
    s==1 && index($0, inner) { s=2; next }
    s==2 && /<string>/ { gsub(/<[^>]*>/,""); gsub(/^[ \t]+|[ \t]+$/,""); print; exit }
  ' "$1" 2>/dev/null
}

check_payload_vs_device() {   # needs XMLP S_STATE EXT_ID TEAM_ID CONSOLE_USER D2
  local x="$XMLP" p_ext p_team p_am lt dups names n ln con local_all others a claim full mean ids id team bundle
  # 1. the payload names the extension macOS actually loaded
  p_ext=$(xml_values "$x" ExtensionIdentifier | /usr/bin/sort -u)
  p_team=$(xml_values "$x" TeamIdentifier | /usr/bin/sort -u)
  if [[ -z "$p_ext" ]]; then
    vcheck SKIP payload-extension-identity "the profiles output has no Extensible SSO settings to compare"
  elif (( ! PSSO_CFG )); then
    vcheck SKIP payload-extension-identity "no Platform SSO configuration on this Mac: the installed SSO payload(s) are credential extensions (for example Kerberos), which macOS does not load as a Platform SSO extension"
  elif print -r -- "$p_ext" | /usr/bin/grep -qxF "$EXT_ID" && { [[ -z "$p_team" || -z "$TEAM_ID" ]] || print -r -- "$p_team" | /usr/bin/grep -qxF "$TEAM_ID"; }; then
    vcheck PASS payload-extension-identity "the payload names $EXT_ID (team ${TEAM_ID:-?}), the extension macOS loaded"
  else
    vcheck FAIL payload-extension-identity "the payload names [$(print -r -- "$p_ext" | /usr/bin/tr '\n' ' ')] (team [$(print -r -- "$p_team" | /usr/bin/tr '\n' ' ')]) but the loaded extension is ${EXT_ID:-none} (team ${TEAM_ID:-?})"
  fi
  # 2. authentication method in the payload vs the login type the device registered with
  p_am=$(xml_nested_value "$x" PlatformSSO AuthenticationMethod)
  lt=$(state_val loginType)
  if (( ! PSSO_CFG )); then
    vcheck SKIP payload-auth-method "no Platform SSO configuration on this Mac, so there is no authentication method to compare"
  elif [[ -z "$p_am" || -z "$lt" ]]; then
    vcheck SKIP payload-auth-method "payload or device login type not available"
  elif [[ "$lt" == *"$p_am"* ]]; then
    vcheck PASS payload-auth-method "payload AuthenticationMethod $p_am matches the registered login type ($lt)"
  else
    vcheck WARN payload-auth-method "payload asks for $p_am but the device registered as $lt - the registration may predate a profile change"
  fi
  # 3. URLs must be unique across all installed Extensible SSO payloads (Apple)
  dups=$(xml_values "$x" URLs | /usr/bin/sort | /usr/bin/uniq -d)
  if [[ -n "$dups" ]]; then
    vcheck FAIL payload-urls-unique "listed more than once across the installed SSO payloads: $(print -r -- "$dups" | /usr/bin/tr '\n' ' ')- Apple requires each URL to be unique"
  elif [[ -n "$(xml_values "$x" URLs)" ]]; then
    vcheck PASS payload-urls-unique "no URL is listed twice across the installed SSO payloads"
  fi
  # 4. accounts exempted from Platform SSO vs the accounts that really exist
  names=$(xml_values "$x" NonPlatformSSOAccounts)
  local_all=$(/usr/bin/grep -v '^#' "$D2/local-accounts-list.txt" 2>/dev/null | /usr/bin/awk '$2 ~ /^[0-9]+$/ && $2 + 0 >= 500 { print $1 }')
  con=$(print -r -- "$CONSOLE_USER" | lc)
  if [[ -z "$names" ]]; then
    vcheck INFO payload-nonplatform-accounts "NonPlatformSSOAccounts is not set - no local account is exempt from Platform SSO registration prompts"
  else
    while IFS= read -r n; do
      [[ -z "$n" ]] && continue
      ln=$(print -r -- "$n" | lc)
      if [[ -n "$con" && "$ln" == "$con" ]]; then
        vcheck FAIL "payload-nonplatform-account:$n" "the logged-in user '$n' is exempt from Platform SSO - registration will never be offered to them"
      elif [[ -z "$local_all" ]]; then
        vcheck INFO "payload-nonplatform-account:$n" "listed as exempt; the local account list was not available to confirm it exists"
      elif print -r -- "$local_all" | lc | /usr/bin/grep -qxF "$ln"; then
        vcheck PASS "payload-nonplatform-account:$n" "listed as exempt and a local account with that name exists"
      else
        vcheck WARN "payload-nonplatform-account:$n" "listed as exempt but no local account is named '$n' (local accounts: $(print -r -- "$local_all" | /usr/bin/tr '\n' ' ')) - check for a typo or a different admin account name"
      fi
    done <<< "$names"
    if [[ -n "$local_all" ]]; then
      others=""
      while IFS= read -r a; do
        [[ -z "$a" ]] && continue
        ln=$(print -r -- "$a" | lc)
        [[ "$ln" == "$con" ]] && continue
        print -r -- "$names" | lc | /usr/bin/grep -qxF "$ln" && continue
        others+="$a "
      done <<< "$local_all"
      [[ -n "$others" ]] && vcheck INFO payload-accounts-not-exempt "local accounts that are NOT exempt from Platform SSO (they may be offered registration): ${others}"
    fi
  fi
  # 5. token-to-user mapping: report what is defined (Microsoft documents two choices for AccountName)
  claim=$(xml_nested_value "$x" TokenToUserMapping AccountName)
  full=$(xml_nested_value "$x" TokenToUserMapping FullName)
  if [[ -z "$claim" ]]; then
    vcheck SKIP payload-account-name "no TokenToUserMapping in the payload"
  else
    case "$claim" in
      com.apple.PlatformSSO.AccountShortName) mean="the UPN prefix becomes the local account short name - Microsoft's recommended choice" ;;
      preferred_username)                      mean="the Entra preferred_username value becomes the account name - Microsoft's documented alternative" ;;
      *)                                       mean="a value the script has no note for, for example an attribute your IdP issues" ;;
    esac
    vcheck INFO payload-account-name "TokenToUserMapping AccountName = '$claim' ($mean); FullName = '${full:-<not set>}'. Microsoft documents two choices for AccountName: com.apple.PlatformSSO.AccountShortName (UPN prefix) or preferred_username. Console account name on this Mac: ${CONSOLE_USER:-unknown}"
  fi
  # 6. Associated Domains: the application identifier should be the extension's host app
  ids=$(xml_values "$x" ApplicationIdentifier | /usr/bin/sort -u)
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    team="${id%%.*}"; bundle="${id#*.}"
    if team_ok "$team" && [[ "$EXT_ID" == "$bundle" || "$EXT_ID" == "$bundle".* ]]; then
      vcheck PASS "payload-app-identifier:$id" "the Associated Domains entry is for the extension's host app"
    elif [[ -n "$TEAM_ID" && "$team" == "$TEAM_ID" ]]; then
      vcheck WARN "payload-app-identifier:$id" "same team as the extension but a different bundle than $EXT_ID - possible typo, domains would be associated with the wrong app"
    else
      vcheck INFO "payload-app-identifier:$id" "an Associated Domains entry for a different app/team than the active extension"
    fi
  done <<< "$ids"

  # 7. With Microsoft's extension active: is Hub turned away by its allow list? (Microsoft log: "bundle identifier X is not in the allow list or Safari SSO is disabled")
  if [[ "$EXT_ID" == *microsoft* ]]; then
    local hb hn rej_total=0 rej_txt="" listed=0 blocked=0 al apl blk all_managed sso_on pf listed_txt blocked_txt adv
    al=$( { xml_values "$x" AppAllowList; xml_values "$x" AppWhiteList; } | /usr/bin/tr ',' '\n' | /usr/bin/sed -E 's/^ +//; s/ +$//' | /usr/bin/grep -v '^$')
    apl=$(xml_values "$x" AppPrefixAllowList | /usr/bin/tr ',' '\n' | /usr/bin/sed -E 's/^ +//; s/ +$//' | /usr/bin/grep -v '^$')
    blk=$(xml_values "$x" AppBlockList | /usr/bin/tr ',' '\n' | /usr/bin/sed -E 's/^ +//; s/ +$//' | /usr/bin/grep -v '^$')
    all_managed=$(xml_int "$x" Enable_SSO_On_All_ManagedApps)
    sso_on=$(xml_int "$x" browser_sso_interaction_enabled)
    for hb in "${HUB_BUNDLES[@]}"; do
      hn=$(/usr/bin/grep -rhs "bundle identifier ${hb} is not in the allow list" "$D4/idp-extension-files" 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')
      if (( ${hn:-0} > 0 )); then rej_total=$(( rej_total + hn )); rej_txt+="${hb} x${hn}  "; fi
      print -r -- "$al" | /usr/bin/grep -qxF "$hb" && listed=1
      print -r -- "$blk" | /usr/bin/grep -qxF "$hb" && blocked=1
      while IFS= read -r pf; do [[ -n "$pf" && "$hb" == "$pf"* ]] && listed=1; done <<< "$apl"
    done
    listed_txt=no;  (( listed ))  && listed_txt=yes
    blocked_txt=no; (( blocked )) && blocked_txt=yes
    if (( rej_total > 0 )); then
      if (( blocked )); then adv="Hub's bundle ID is on AppBlockList in the payload installed on this Mac - remove it from the block list if Hub should be served."
      elif (( listed )); then adv="Hub is already on an allow list in the payload installed on this Mac, so check that this is the payload version you edited, and that Safari SSO (browser_sso_interaction_enabled) is not turned off."
      else adv="Options: add Hub's bundle ID to AppAllowList or its prefix to AppPrefixAllowList; Enable_SSO_On_All_ManagedApps = 1 admits only MDM-managed apps (Microsoft)."; fi
      vcheck WARN hub-allow-list "Microsoft's extension turned Hub away ${rej_total} time(s): ${rej_txt% }. Its log says 'not in the allow list or Safari SSO is disabled'. Payload: Hub on an allow list = ${listed_txt}; on AppBlockList = ${blocked_txt}; Enable_SSO_On_All_ManagedApps = ${all_managed:-unset}; browser_sso_interaction_enabled = ${sso_on:-unset} (Microsoft documents 1 as the default). ${adv} The effect on users was not measured."
    elif (( blocked )); then
      vcheck INFO hub-allow-list "Hub's bundle ID is on AppBlockList, so Microsoft's extension will not serve it; no rejection of Hub was logged in this window"
    elif (( listed )); then
      vcheck PASS hub-allow-list "the payload's allow lists cover Hub and no rejection was logged"
    else
      vcheck INFO hub-allow-list "Hub is not on the payload's allow lists (Enable_SSO_On_All_ManagedApps = ${all_managed:-unset}); no rejection of Hub was logged in this window"
    fi
  fi
}

# Hub's own SOAuthorization requests, linked to their results by request UUID. Adds one vcheck.
hub_authorization_check() {
  local f="$D4/log-show-psso-all.txt" rows total=0 ok=0 bad=0 open=0 own_bad=0 detail
  if [[ ! -s "$f" ]] || ! /usr/bin/grep -q 'Intelligent Hub.*beginAuthorizationWithRequestParameters' "$f" 2>/dev/null; then
    vcheck SKIP hub-authorization "no Hub SOAuthorization requests in the captured log window"
    return
  fi
  # one pass over the log: find Hub's requests (and the extension each went to), then classify every line that carries one of their request IDs
  rows=$(/usr/bin/awk '
    NR == FNR {
      if ($0 ~ /Intelligent Hub.*beginAuthorizationWithRequestParameters/ && match($0, /[0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9A-Fa-f]+/) && RLENGTH == 36) {
        u = substr($0, RSTART, RLENGTH); ext = "unknown-extension"
        if (match($0, /extensionBundleId = [A-Za-z0-9.]+/)) { ext = substr($0, RSTART, RLENGTH); sub(/^extensionBundleId = /, "", ext) }
        ids[u] = 1; extof[u] = ext
      }
      next
    }
    {
      line = $0; rest = line
      while (match(rest, /[0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9A-Fa-f]+/)) {
        u = substr(rest, RSTART, RLENGTH); n = RLENGTH; rest = substr(rest, RSTART + RLENGTH)
        if (n == 36 && (u in ids)) {
          if (line ~ /Code=-[0-9]+|error: [^(]/) { bad[u] = 1; if (match(line, /Code=-[0-9]+/)) code[u] = substr(line, RSTART + 5, RLENGTH - 5) }
          else if (line ~ /error: \(null\)/) ok[u] = 1
        }
      }
    }
    END { for (u in ids) print (bad[u] ? "bad" : (ok[u] ? "ok" : "open")) "|" extof[u] "|" code[u] }
  ' "$f" "$f" 2>/dev/null)
  ok=$(print -r -- "$rows" | /usr/bin/grep -c '^ok|'); bad=$(print -r -- "$rows" | /usr/bin/grep -c '^bad|'); open=$(print -r -- "$rows" | /usr/bin/grep -c '^open|')
  total=$(( ${ok:-0} + ${bad:-0} + ${open:-0} ))
  own_bad=$(print -r -- "$rows" | /usr/bin/grep -c '^bad|com\.ws1\.hub\.')
  detail=$(print -r -- "$rows" | /usr/bin/awk -F'|' '$1=="bad" { k=$2 " (error code " ($3==""?"?":$3) ")"; c[k]++ } END { for (k in c) printf "%dx via %s; ", c[k], k }')
  if (( ${bad:-0} > 0 && ${own_bad:-0} > 0 )); then
    vcheck FAIL hub-authorization "${bad} of ${total} Hub SOAuthorization request(s) ended in an error, including requests to Hub's own extension: ${detail}"
  elif (( ${bad:-0} > 0 )); then
    vcheck WARN hub-authorization "${bad} of ${total} Hub SOAuthorization request(s) ended in an error: ${detail}${ok:-0} ended with error: (null). The effect on users was not measured; see hub-allow-list when Microsoft's extension is the one rejecting them"
  elif (( ${open:-0} > 0 )); then
    vcheck WARN hub-authorization "${open} of ${total} Hub SOAuthorization request(s) have no completion line in the window; ${ok:-0} ended with error: (null)"
  else
    vcheck PASS hub-authorization "all ${total} Hub SOAuthorization request(s) ended with error: (null)"
  fi
}

# Attributes "authority must have AAD tenant" (-51100) errors in the Microsoft SSO extension log to the requester:
# the bundle named on the "Created Browser SSO request" line with the same TID. Sets TENANT_TOTAL / TENANT_HUB / TENANT_SAFARI / TENANT_OTHER.
tenant_error_attribution() {
  local f tally who n
  TENANT_TOTAL=0; TENANT_HUB=0; TENANT_SAFARI=0; TENANT_OTHER=0
  tally=$(
    { /usr/bin/find "$D4" -name 'SSOExtension*' -type f 2>/dev/null; } | while IFS= read -r f; do
      /usr/bin/grep -q 'authority must have AAD tenant' "$f" 2>/dev/null || continue
      /usr/bin/awk '
        { tid = ""; if (match($0, /TID=[0-9]+/)) tid = substr($0, RSTART, RLENGTH) }
        /Created Browser SSO request for bundle identifier/ {
          b = $0; sub(/.*Created Browser SSO request for bundle identifier /, "", b); sub(/[ ,].*$/, "", b); sub(/\.$/, "", b)
          if (tid != "") who[tid] = b
        }
        /authority must have AAD tenant/ { cnt[(tid != "" && (tid in who)) ? who[tid] : "unattributed"]++ }
        END { for (k in cnt) print k "\t" cnt[k] }' "$f"
    done | /usr/bin/awk -F'\t' '{ s[$1] += $2 } END { for (k in s) print k "\t" s[k] }'
  )
  while IFS=$'\t' read -r who n; do
    [[ -z "$who" ]] && continue
    TENANT_TOTAL=$(( TENANT_TOTAL + n ))
    case "$who" in
      com.ws1.hub.*) TENANT_HUB=$(( TENANT_HUB + n )) ;;
      com.apple.Safari) TENANT_SAFARI=$(( TENANT_SAFARI + n )) ;;
      *) TENANT_OTHER=$(( TENANT_OTHER + n )) ;;
    esac
  done <<< "$tally"
}

# Redact OAuth codes / tokens that appear as URL parameters inside log text.
redact_log_secrets() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  /usr/bin/sed -E 's/((^|[?&" ])(code|activation_code|access_token|refresh_token|id_token|client_secret|assertion)=)[^&" ]+/\1[REDACTED]/g' "$f" > "$f.redacted" && /bin/mv "$f.redacted" "$f"
}

log "Collector v$SCRIPT_VERSION started on $HOST (macOS $OS_VER), console user: ${CONSOLE_USER:-none}"

# =============================================================================
# 00 - system context
# =============================================================================
log "== 00 system context"
capture "$D0/sw_vers.txt"          /usr/bin/sw_vers
capture "$D0/uname.txt"            /usr/bin/uname -a
capture "$D0/date-timezone.txt"    /bin/zsh -c 'date; /usr/sbin/systemsetup -gettimezone'
capture "$D0/console-user.txt"     /bin/zsh -c "print console_user=${CONSOLE_USER:-none} uid=${CONSOLE_UID:-none}; /usr/bin/stat -f%Su /dev/console"
capture "$D0/hardware.txt"         /usr/sbin/system_profiler SPHardwareDataType
capture "$D0/hub-and-sso-pkgs.txt" /bin/zsh -c "/usr/sbin/pkgutil --pkgs | /usr/bin/grep -iE 'airwatch|omnissa|ws1|workspaceone|microsoft|intune|companyportal'"
capture "$D0/companyportal-pkg-info.txt" /usr/sbin/pkgutil --pkg-info com.microsoft.CompanyPortalMac

# =============================================================================
# 01 - sysdiagnose  (documented flags: -f <dir>; -u / -b only if this OS lists them)
# =============================================================================
SD_REC="$D1/00-how-this-sysdiagnose-was-captured.txt"
if (( SKIP_SYSDIAG )); then
  log "== 01 sysdiagnose SKIPPED (--skip-sysdiagnose)"
  print "No sysdiagnose was captured in this run: ${SCRIPT_PATH:t} was started with --skip-sysdiagnose or --tests-only." > "$SD_REC"
else
  log "== 01 sysdiagnose (this takes several minutes - do not interrupt)"
  SD_HELP=$(/usr/bin/sysdiagnose -h 2>&1)
  typeset -a SD_FLAGS; SD_FLAGS=(-f "$D1")
  print -r -- "$SD_HELP" | /usr/bin/grep -Eq '^[[:space:]]*-u([[:space:],]|$)' && SD_FLAGS+=(-u)
  print -r -- "$SD_HELP" | /usr/bin/grep -Eq '^[[:space:]]*-b([[:space:],]|$)' && SD_FLAGS+=(-b)
  SD_STDOUT="$STAGE/sysdiagnose-stdout.txt"
  SD_START_LOCAL=$(/bin/date '+%m-%d-%Y %H:%M:%S %Z'); SD_START_UTC=$(/bin/date -u '+%m-%d-%Y %H:%M:%S UTC')
  SD_TRIES=0
  while :; do
    SD_TRIES=$(( SD_TRIES + 1 ))
    log "  running (attempt $SD_TRIES): /usr/bin/sysdiagnose ${SD_FLAGS[*]}"
    print -r -- y | /usr/bin/sysdiagnose "${SD_FLAGS[@]}" > "$SD_STDOUT" 2>&1
    SD_RC=${pipestatus[2]}
    if /usr/bin/grep -q 'already in flight' "$SD_STDOUT" 2>/dev/null && (( SD_TRIES < 21 )); then
      log "  another sysdiagnose is already running - waiting 15 s, then trying again (attempt $SD_TRIES of 21)"
      /bin/sleep 15
      continue
    fi
    break
  done
  SD_END_LOCAL=$(/bin/date '+%m-%d-%Y %H:%M:%S %Z'); SD_END_UTC=$(/bin/date -u '+%m-%d-%Y %H:%M:%S UTC')
  log "  sysdiagnose exit code: $SD_RC (attempts: $SD_TRIES)"
  SD_OUT=$(/usr/bin/find "$D1" -maxdepth 1 -name 'sysdiagnose_*' 2>/dev/null | /usr/bin/head -1)
  if [[ -n "$SD_OUT" ]]; then
    log "  sysdiagnose output: ${SD_OUT:t} ($(/usr/bin/du -sh "$SD_OUT" | /usr/bin/awk '{print $1}'))"
  else
    problem "sysdiagnose produced no archive (see 01-sysdiagnose/00-how-this-sysdiagnose-was-captured.txt)"
  fi
  write_sysdiagnose_record > "$SD_REC"
fi

# =============================================================================
# 02 - PSSO state + extension checks  (user context)
#   NOTE: the binary is 'app-sso' (not 'app-so'); pluginkit grep uses -i
#   (case-insensitive). 'grep -I' only means "ignore binary files".
# =============================================================================
log "== 02 PSSO state / extension checks (as ${CONSOLE_USER:-none})"
capture_user "$D2/app-sso-platform-state.txt"  app-sso platform -s
redact_appsso "$D2/app-sso-platform-state.txt"
flag_cli_errors "$D2/app-sso-platform-state.txt" "app-sso platform -s"
log "  app-sso state output: device keys/certificate redacted"
capture_user "$D2/app-sso-listrealms.txt"      app-sso -l
flag_cli_errors "$D2/app-sso-listrealms.txt" "app-sso -l"
capture_user "$D2/app-sso-help.txt"            app-sso --help
capture_user "$D2/pluginkit-all.txt"           pluginkit -m
capture_user "$D2/pluginkit-auth-service-extension.txt" \
             /bin/zsh -c 'pluginkit -m | grep -i auth-service-extension'
capture "$D2/local-accounts-list.txt" /usr/bin/dscl . -list /Users UniqueID
capture_user "$D2/pluginkit-sso-related.txt" \
             /bin/zsh -c 'pluginkit -m | grep -iE "ssoextension|PlatformSSO|AppSSO"'
log "  (pluginkit filters: rc=1 with no output lines = no match)"
if [[ -n "$CONSOLE_USER" ]]; then
  capture "$D2/local-account-dscl.txt" /usr/bin/dscl . -read "/Users/$CONSOLE_USER" RecordName UniqueID NFSHomeDirectory
  capture "$D2/local-account-id.txt"   /usr/bin/id "$CONSOLE_USER"
fi

# =============================================================================
# 03 - proof that MDM delivered the PSSO payload
# =============================================================================
log "== 03 MDM / profile evidence"
capture "$D3/profiles-status-enrollment.txt"   /usr/bin/profiles status -type enrollment
capture "$D3/profiles-show-enrollment.txt"     /usr/bin/profiles show -type enrollment
capture "$D3/profiles-list.txt"                /usr/bin/profiles list
capture "$D3/profiles-show-all.txt"            /usr/bin/profiles show -all
capture "$D3/profiles-show-configuration.txt"  /usr/bin/profiles show -type configuration
capture "$D3/profiles-show-all-xml.txt"        /usr/bin/profiles show -all -output stdout-xml
capture "$D3/configurationprofiles-dir-listing.txt" \
        /bin/zsh -c 'find /var/db/ConfigurationProfiles -maxdepth 2 -exec ls -ldeO {} +'
for f in "$D3"/profiles-*.txt; do redact_file "$f"; done
log "  profiles output passed through secret redactor"
{
  print "# PSSO-related lines (+context) from redacted 'profiles show -all'"
  /usr/bin/grep -n -i -B2 -A25 -E 'com\.apple\.extensiblesso|PlatformSSO|TokenToUserMapping|ExtensionIdentifier' \
      "$D3/profiles-show-all.txt" \
    || print "NO MATCH: no extensiblesso / PlatformSSO payload text found in profiles output."
} > "$D3/psso-payload-extract.txt" 2>&1

PRED_MDM='(process == "mdmclient" OR process == "profiled") AND (eventMessage CONTAINS[c] "extensiblesso" OR eventMessage CONTAINS[c] "PlatformSSO" OR eventMessage CONTAINS[c] "InstallProfile" OR eventMessage CONTAINS[c] "Installing profile" OR eventMessage CONTAINS[c] "RemoveProfile" OR eventMessage CONTAINS[c] "Removing profile" OR eventMessage CONTAINS[c] "Removed profile")'
capture "$D3/log-show-mdm-profile-install.txt" \
        /usr/bin/log show --info --debug --style default --last "$LOG_WINDOW" --predicate "$PRED_MDM"

# =============================================================================
# 04 - proof the device attempted PSSO registration
# =============================================================================
log "== 04 PSSO registration-attempt logs"
PRED_PSSO='(subsystem == "com.apple.AppSSO") OR (process == "AppSSODaemon") OR (process == "AppSSOAgent") OR (subsystem CONTAINS[c] "CompanyPortalMac") OR (eventMessage CONTAINS[c] "PlatformSSO") OR (eventMessage CONTAINS[c] "Platform SSO")'
PRED_POD='(subsystem == "com.apple.AppSSO") AND (category == "PODiagnostics")'
PRED_TL='(subsystem == "com.apple.AppSSO" AND (eventMessage CONTAINS "beginDeviceRegistration" OR eventMessage CONTAINS "finishRegistrationWithStatus" OR eventMessage CONTAINS "beginUserRegistration" OR eventMessage CONTAINS "handleUserRegistrationForUser" OR eventMessage CONTAINS "createOrRepairDeviceConfiguration" OR eventMessage CONTAINS "Sending nonce request" OR eventMessage CONTAINS "Sending login request" OR eventMessage CONTAINS "Login Result" OR eventMessage CONTAINS "savePendingSSOTokens" OR eventMessage CONTAINS "removeUserConfigurationForIdentifier" OR eventMessage CONTAINS "Failed to find credential" OR eventMessage CONTAINS "config version changed")) OR (subsystem == "com.apple.macbuddy" AND eventMessage CONTAINS "PlatformSSO") OR (subsystem == "com.ws1.hub.ssoextension" AND (eventMessage CONTAINS "beginUserRegistration" OR eventMessage CONTAINS "beginDeviceRegistration" OR eventMessage CONTAINS "presenting ui" OR eventMessage CONTAINS "registerUser" OR eventMessage CONTAINS "Register user" OR eventMessage CONTAINS "Unhandled registration error" OR eventMessage CONTAINS "registrationDidComplete")) OR (process == "usernoted" AND eventMessage CONTAINS "com.apple.PlatformSSO.notifications" AND (eventMessage CONTAINS "Presenting" OR eventMessage CONTAINS "Received response" OR eventMessage CONTAINS "Removing displayed"))'
capture "$D4/log-show-psso-all.txt" \
        /usr/bin/log show --info --debug --style compact --last "$LOG_WINDOW" --predicate "$PRED_PSSO"
capture "$D4/log-show-appsso-PODiagnostics.txt" \
        /usr/bin/log show --info --debug --style compact --last "$LOG_WINDOW" --predicate "$PRED_POD"
capture "$D4/log-show-registration-timeline-with-tz.txt" \
        /usr/bin/log show --info --debug --style default --last "$LOG_WINDOW" --predicate "$PRED_TL"
for f in "$D3/log-show-mdm-profile-install.txt" "$D4"/log-show-*.txt; do redact_log_secrets "$f"; done
log "  OAuth code/token URL parameters in log slices redacted"
{
  print "# PSSO payload settings as logged by AppSSO (the 'profiles' command does not show these settings)."
  print "# Form A: multi-line block (SOConfigurationHost) - first 2 occurrences"
  if /usr/bin/grep -qE 'SOConfigurationHost\].*: \{$' "$D4/log-show-psso-all.txt"; then
    /usr/bin/grep -n -m2 -A34 -E 'SOConfigurationHost\].*: \{$' "$D4/log-show-psso-all.txt"
  else
    print "(none in this window)"
  fi
  print ""
  print "# Form B: single-line escaped dictionary containing the PlatformSSO settings - first 2 occurrences, unescaped"
  if /usr/bin/grep -qE 'BundleIdentifier = .*PlatformSSO' "$D4/log-show-psso-all.txt"; then
    /usr/bin/grep -m2 -E 'BundleIdentifier = .*PlatformSSO' "$D4/log-show-psso-all.txt" \
      | /usr/bin/awk '{ gsub(/\\134n/,"\n"); gsub(/\\134"/,"\""); print; print "----" }'
  else
    print "(none in this window)"
  fi
} > "$D4/psso-config-seen-by-appsso.txt" 2>&1
redact_file "$D4/psso-config-seen-by-appsso.txt"
{
  print "# Log lines that carry a user string (from log-show-psso-all.txt). Values are exactly as macOS logged them."
  print "# NOTE: macOS itself masks some (b***n) and logs others as <private>."
  /usr/bin/grep -E 'userName|loginUserName|login_hint|preferred_username|activatePlatformSSOForUser|platformSSOEnabledForUsername|Platform SSO not configured for user|Activate for user|verifyPasswordLogin|beginUserRegistration|savePendingSSOTokens|configuration for user|no device configuration' \
      "$D4/log-show-psso-all.txt" | /usr/bin/grep -vE '^[[:space:]]*UserName = '
} > "$D4/username-trace.txt" 2>&1
log "  username-trace.txt written"

# IdP-extension log files (paths from Microsoft/community docs; harmless if absent)
copy_if_exists "/Library/Logs/Microsoft/Intune" "$D4/idp-extension-files"
if [[ -n "$USER_HOME" ]]; then
  copy_if_exists "$USER_HOME/Library/Logs/Microsoft/Intune" "$D4/idp-extension-files/user"
  copy_if_exists "$USER_HOME/Library/Containers/com.microsoft.CompanyPortalMac.ssoextension/Data/Library/Caches/Logs/Microsoft/SSOExtension" "$D4/idp-extension-files"
fi
okta_logs_collect

# =============================================================================
# 05 - Workspace ONE Intelligent Hub logs
# =============================================================================
log "== 05 Intelligent Hub logs"
[[ -x "$HUBCLI" ]] || HUBCLI=$(command -v hubcli 2>/dev/null)
if (( TESTS_ONLY )); then
  log "  hubcli archive SKIPPED (--tests-only)"
elif [[ -n "$HUBCLI" && -x "$HUBCLI" ]]; then
  capture "$D5/hubcli-help.txt"       "$HUBCLI" --help
  capture "$D5/hubcli-logs-help.txt"  "$HUBCLI" logs --help
  /bin/mkdir -p "$D5/hubcli-archive"
  capture "$D5/hubcli-logs-collect.txt" \
          "$HUBCLI" logs --collect --duration "$HUB_DURATION" --archive "$D5/hubcli-archive"
  if [[ -z "$(/bin/ls -A "$D5/hubcli-archive" 2>/dev/null)" ]]; then
    problem "hubcli ran but wrote nothing to hubcli-archive - check hubcli-logs-collect.txt and hubcli-logs-help.txt (flags can change between Hub versions)"
  fi
else
  problem "hubcli NOT FOUND (expected /usr/local/bin/hubcli) - Hub file logs were NOT collected"
fi
copy_if_exists "/Library/Application Support/AirWatch/Data/Munki/Managed Installs/Logs/ManagedSoftwareUpdate.log" "$D5/files"
capture "$D5/airwatch-dir-listing.txt" \
        /bin/zsh -c 'ls -laeO "/Library/Application Support/AirWatch" "/Library/Logs" 2>&1'
PRED_HUB='(process == "awcmd") OR (process == "hubd") OR (process == "IntelligentHubAgent") OR (subsystem BEGINSWITH "com.ws1")'
capture "$D5/log-show-hub.txt" \
        /usr/bin/log show --info --debug --style compact --last "$LOG_WINDOW" --predicate "$PRED_HUB"
capture "$D5/log-show-hub-health-with-tz.txt" \
        /usr/bin/log show --info --debug --style default --last "$LOG_WINDOW" --predicate '(eventMessage CONTAINS "platformSSO") AND (eventMessage CONTAINS "health")'
for f in "$D5"/log-show-*.txt; do redact_log_secrets "$f"; done
log "  OAuth code/token URL parameters in Hub log slices redacted (hubcli archive + sysdiagnose are NOT redacted)"

# =============================================================================
# 06 - automated validation tests (no user action needed)
# =============================================================================
log "== 06 validation tests (automated)"
S_STATE="$D2/app-sso-platform-state.txt"
XMLP="$D3/profiles-show-all-xml.txt"
FLAT="$STAGE/ssoflat.txt"
plist_flat "$XMLP" '(\.PayloadType$|\.ExtensionIdentifier$|\.TeamIdentifier$|\.Type$|\.Realm$|\.Hosts\[|\.URLs\[|\.PlatformSSO\.|\.ExtensionData\.|OktaVerify\.)' > "$FLAT"
VAL="$STAGE/validation.txt"; : > "$VAL"; UNRESOLVED_HOSTS=""
EXT_ID=$(state_val extensionIdentifier); TEAM_ID=$(state_val extensionTeamIdentifier)
if [[ -z "$TEAM_ID" && -n "$EXT_ID" ]]; then   # the state reports no team until registration completes; the payload names it
  P_EXT_ALL=$(xml_values "$XMLP" ExtensionIdentifier | /usr/bin/sort -u); P_TEAM_ALL=$(xml_values "$XMLP" TeamIdentifier | /usr/bin/sort -u)
  if print -r -- "$P_EXT_ALL" | /usr/bin/grep -qxF "$EXT_ID" && [[ "$(print -r -- "$P_TEAM_ALL" | /usr/bin/grep -c .)" == 1 ]]; then
    TEAM_ID="$P_TEAM_ALL"
    vcheck INFO extension-team "the app-sso state reports no team identifier (normal before registration completes); using $TEAM_ID from the SSO payload"
  else
    vcheck INFO extension-team "no team identifier in the state or a single matching payload; AASA and association checks match on the bundle ID alone"
  fi
fi

# --- on-device state
PSSO_CFG=0; psso_configured && PSSO_CFG=1
REG=$(state_val registrationCompleted)
if (( ! PSSO_CFG )); then vcheck SKIP device-registration "this Mac has no Platform SSO configuration (no Platform SSO settings in an installed SSO payload and no registration state), so there is nothing to register"
elif [[ "$REG" == true ]]; then vcheck PASS device-registration "registrationCompleted = true"
else vcheck FAIL device-registration "registrationCompleted = ${REG:-<missing>} - Platform SSO is not registered on this Mac"; fi

UST=$(state_val state)
if (( ! PSSO_CFG )); then vcheck SKIP user-registration "no Platform SSO configuration on this Mac, so no user registration is expected"
elif [[ -z "$UST" ]]; then vcheck FAIL user-registration "no user configuration in the state - no user is registered"
elif [[ "$UST" == *Normal* ]]; then vcheck PASS user-registration "user state = $UST"
else vcheck FAIL user-registration "user state = $UST (expected POUserStateNormal)"; fi

if [[ -z "$EXT_ID" ]] && (( ! PSSO_CFG )); then vcheck SKIP extension-installed "no Platform SSO configuration on this Mac, so no Platform SSO extension is expected"
elif [[ -z "$EXT_ID" ]]; then vcheck SKIP extension-installed "no extensionIdentifier in the state (payload not applied?)"
elif /usr/bin/grep -q -F "$EXT_ID" "$D2/pluginkit-all.txt" 2>/dev/null; then vcheck PASS extension-installed "$EXT_ID is registered with pluginkit"
else vcheck FAIL extension-installed "$EXT_ID is not listed by pluginkit (host app missing or never launched?)"; fi

NKEYS=0
for k in _deviceSigningKeyData _deviceEncryptionKeyData; do /usr/bin/grep -q "\"$k\"" "$S_STATE" 2>/dev/null && NKEYS=$(( NKEYS + 1 )); done
if (( ! PSSO_CFG )); then vcheck SKIP device-keys "no Platform SSO configuration on this Mac, so no device keys are expected"
elif (( NKEYS == 2 )); then vcheck PASS device-keys "device signing and encryption keys are present"
else vcheck FAIL device-keys "only ${NKEYS} of 2 device keys are present in the state"; fi
LT=$(state_val loginType)
if [[ "$LT" == *SecureEnclave* ]]; then
  if [[ -z "$UST" ]]; then vcheck SKIP user-secure-enclave-key "no user is registered yet, so no user key is expected ($LT)"
  elif /usr/bin/grep -q '"_sepKeyData"' "$S_STATE" 2>/dev/null; then vcheck PASS user-secure-enclave-key "user Secure Enclave key is present ($LT)"
  else vcheck FAIL user-secure-enclave-key "login type is $LT but no user Secure Enclave key is in the state"; fi
fi

TOK_EXP=$(/usr/bin/awk '/^Expiration:/ { getline; print; exit }' "$S_STATE" 2>/dev/null)
if [[ -z "$TOK_EXP" ]]; then
  if (( ! PSSO_CFG )); then vcheck SKIP sso-token "no Platform SSO configuration on this Mac, so no token is expected"
  elif [[ "$REG" != true || -z "$UST" ]]; then vcheck SKIP sso-token "no token yet - registration is not complete"
  else vcheck WARN sso-token "no SSO token block in the state"; fi
elif [[ "$TOK_EXP" == *"Not Expired"* ]]; then vcheck PASS sso-token "token valid until ${TOK_EXP%% *}"
else vcheck FAIL sso-token "SSO token expired: $TOK_EXP"; fi

# --- payload: URLs, associated domains, hosts to test
URLS=$(xml_values "$XMLP" URLs | /usr/bin/sort -u)
ASSOC_HOSTS=$(xml_values "$XMLP" AssociatedDomains | /usr/bin/grep '^authsrv:' | /usr/bin/sed -E 's/^authsrv://; s/\?.*$//' | /usr/bin/sort -u)
EXT_URL_HOSTS=$(ext_payload_url_hosts | /usr/bin/sort -u)
EXT_ASSOC_HOSTS=$(ad_pairs "$XMLP" | while IFS='|' read -r pa pd; do [[ -n "$pa" ]] && app_is_active "$pa" && print -r -- "${pd%%\?*}"; done | /usr/bin/sort -u)
HOSTS=""
while IFS= read -r u; do [[ -n "$u" ]] && HOSTS+="$(url_host "$u")"$'\n'; done <<< "$URLS"
for k in nonceEndpointURL tokenEndpointURL jwksEndpointURL; do
  u=$(state_val $k); [[ -n "$u" && "$u" != "<null>" ]] && HOSTS+="$(url_host "$u")"$'\n'
done
HOSTS=$(print -r -- "$HOSTS" | /usr/bin/grep -v '^$' | /usr/bin/sort -u | /usr/bin/head -6)
[[ -n "$URLS" || -n "$ASSOC_HOSTS" ]] && vcheck INFO payload-urls "URLs: $(print -r -- "$URLS" | /usr/bin/tr '\n' ' ')| authsrv associated domains: $(print -r -- "$ASSOC_HOSTS" | /usr/bin/tr '\n' ' ')"
check_payload_vs_device
hub_authorization_check

# --- evidence captures
capture "$D6/swcutil-show.txt" /usr/bin/swcutil show
capture "$D6/scutil-proxy.txt" /usr/sbin/scutil --proxy
capture "$D6/sntp-time.apple.com.txt" run_timeout 20 /usr/bin/sntp time.apple.com
capture_user "$D6/pluginkit-idp-extension-detail.txt" pluginkit -m -A -D -vvv -p com.apple.AppSSO.idp-extension
capture_user "$D6/app-sso-platform-messages.txt" app-sso platform -m
if [[ -f "$D6/app-sso-platform-messages.txt" ]]; then
  /usr/bin/sed -E 's/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*/[REDACTED-JWT]/g' "$D6/app-sso-platform-messages.txt" > "$D6/app-sso-platform-messages.red" && /bin/mv "$D6/app-sso-platform-messages.red" "$D6/app-sso-platform-messages.txt"
fi
capture "$D6/sso-crash-reports.txt" /bin/zsh -c "/bin/ls -lt /Library/Logs/DiagnosticReports '${USER_HOME:-/nonexistent}/Library/Logs/DiagnosticReports' 2>/dev/null | /usr/bin/grep -iE 'sso|appsso|platformsso'"
NCRASH=$(/usr/bin/grep -v '^#' "$D6/sso-crash-reports.txt" 2>/dev/null | /usr/bin/grep -ciE 'sso')
if (( ${NCRASH:-0} > 0 )); then vcheck WARN sso-crash-reports "${NCRASH} SSO/AppSSO diagnostic report(s) exist (see 06-validation/sso-crash-reports.txt)"
else vcheck PASS sso-crash-reports "no SSO/AppSSO crash or diagnostic reports found"; fi
PX=$(/usr/bin/grep -E 'HTTPEnable|HTTPSEnable|ProxyAutoConfigEnable' "$D6/scutil-proxy.txt" 2>/dev/null | /usr/bin/tr -s ' \n' ' ')
vcheck INFO system-proxy "${PX:-no proxy flags found} - the curl tests below do not use the system proxy"

# --- clock
SKEW=$(/usr/bin/awk '/^[+-][0-9]/ { print $1; exit }' "$D6/sntp-time.apple.com.txt" 2>/dev/null)
if [[ -z "$SKEW" ]]; then vcheck WARN clock-skew "could not query time.apple.com (UDP 123 blocked?) - clock accuracy not verified"
else
  SKEW_V=$(/usr/bin/awk -v o="$SKEW" 'BEGIN { if (o < 0) o = -o; if (o > 300) print "FAIL"; else if (o > 60) print "WARN"; else print "PASS" }')
  vcheck "$SKEW_V" clock-skew "offset ${SKEW}s vs time.apple.com (WARN over 60 s, FAIL over 300 s; assertions and tokens carry timestamps)"
fi

# --- Kerberos (only when the PSSO state has a Kerberos mapping)
if /usr/bin/grep -q '"upn"' "$S_STATE" 2>/dev/null; then
  capture_user "$D6/klist.txt" klist
  if /usr/bin/grep -q 'krbtgt' "$D6/klist.txt" 2>/dev/null; then vcheck PASS kerberos-tgt "a krbtgt ticket is in the user's cache"
  else vcheck WARN kerberos-tgt "PSSO state has a Kerberos mapping but klist shows no krbtgt ticket"; fi
else
  krb_configured || vcheck SKIP kerberos-tgt "no Kerberos mapping in the PSSO state and no Kerberos extension payload"
fi

# --- network: Apple's AASA CDN, IdP endpoints, per-host associated-domain / AASA checks
if (( PSSO_CFG )); then check_apple_cdn_tls
else vcheck SKIP apple-cdn-tls "Apple's AASA servers matter only for Platform SSO and its Associated Domains; this Mac has no Platform SSO configuration"; fi
check_idp_endpoints
while IFS= read -r h; do [[ -n "$h" ]] && check_host "$h"; done <<< "$HOSTS"
check_association_pairs
check_network_agents
check_signin_endpoint
check_setup_assistant_keys
check_okta
check_psso_leftovers
check_kerberos
appsso_logging_status

# --- functional: Safari navigation to each payload URL (background; see --no-browser-test)
safari_session_begin
safari_navigation_test
test_urls
safari_session_end
NF=$(/usr/bin/grep -c '^FAIL|' "$VAL"); NW=$(/usr/bin/grep -c '^WARN|' "$VAL")
log "  validation finished: FAIL=${NF:-0} WARN=${NW:-0}"
compute_result
log "  RESULT: ${RESULT_CODE} - ${RESULT_LINE}"

# =============================================================================
# Quick findings (automated greps - NOT a verdict; review the raw files)
# =============================================================================
log "== quick findings"
{
  S="$D2/app-sso-platform-state.txt"
  POD="$D4/log-show-appsso-PODiagnostics.txt"
  HH="$D5/log-show-hub.txt"
  print "RESULT: ${RESULT_LINE}"
  print "        ${RESULT_WHY}"
  print ""
  print "QUICK FINDINGS - automated greps only; confirm in the raw files"
  print "Generated: $(/bin/date '+%m-%d-%Y %H:%M:%S %Z')   Log window: $LOG_WINDOW"
  print ""
  validation_summary
  print ""
  build_diagnosis
  print ""

  print "[MDM payload] profiles containing a com.apple.extensiblesso payload:"
  SSO_ROWS=$(/usr/bin/awk '
    /attribute: name:/ { match($0,/_computerlevel\[[0-9]+\]/); k=substr($0,RSTART,RLENGTH); nm=$0; sub(/^.*attribute: name: /,"",nm); name[k]=nm }
    /attribute: installationDate:/ { match($0,/_computerlevel\[[0-9]+\]/); k=substr($0,RSTART,RLENGTH); d=$0; sub(/^.*attribute: installationDate: /,"",d); inst[k]=d }
    /payload\[[0-9]+\] type[ \t]*= com\.apple\.extensiblesso/ { match($0,/_computerlevel\[[0-9]+\]/); hit[substr($0,RSTART,RLENGTH)]=1 }
    END { for (k in hit) print name[k] "|" inst[k] }' "$D3/profiles-show-all.txt" 2>/dev/null)
  SSO_INST_EPOCH=0
  if [[ -n "$SSO_ROWS" ]]; then
    while IFS='|' read -r pn pd; do
      print "    $pn  (installed $pd)"
      pe=$(to_epoch_tz "$(print -r -- "$pd" | /usr/bin/sed -E 's/ ([+-][0-9]{4})$/\1/')")
      [[ -n "$pe" ]] && (( pe > SSO_INST_EPOCH )) && SSO_INST_EPOCH=$pe
    done < <(print -r -- "$SSO_ROWS")
  else
    print "    NONE found in 'profiles show -all'"
  fi
  print ""
  sso_payload_summary "$D3/profiles-show-all-xml.txt" "$D4/psso-config-seen-by-appsso.txt"
  print ""
  print "[Platform SSO settings defined in the installed SSO payload(s) - compare with your vendor's documentation; secrets are hidden]"
  print_payload_settings
  print ""
  print "[MDM] profile install / update / removal events in the log window (UTC converted from each line's own offset):"
  INST="$D3/log-show-mdm-profile-install.txt"
  profile_events "$INST"
  /usr/bin/grep -E 'ErrorChain.*(SingleSignOn|PSSO|extensiblesso)' "$INST" 2>/dev/null | /usr/bin/sed -E 's/^([0-9-]+ [0-9:.]+)[+-][0-9]{4} .*(\(InstallProfile\).*)$/    \1  FAILED \2/' | /usr/bin/cut -c1-240
  CP_EPOCH=$(/usr/bin/grep -m1 'install-time' "$D0/companyportal-pkg-info.txt" 2>/dev/null | /usr/bin/awk '{print $2}')
  EXT_ID=$(/usr/bin/grep -m1 '"extensionIdentifier"' "$S" 2>/dev/null | /usr/bin/sed -E 's/.*: "([^"]*)".*/\1/')
  if [[ -n "$CP_EPOCH" ]]; then
    print "[Company Portal pkg] installed: $(/bin/date -r "$CP_EPOCH" '+%m-%d-%Y %H:%M:%S %Z')"
  elif [[ "$EXT_ID" == *[Mm]icrosoft* ]]; then
    print "[Company Portal pkg] receipt not found"
  fi
  print ""

  print "[app-sso platform -s]"
  for k in extensionIdentifier extensionTeamIdentifier loginType registrationCompleted state lastEncryptionKeyChange authGracePeriodStart lastLoginDate sharedDeviceKeys; do
    v=$(/usr/bin/grep -m1 "\"$k\"" "$S" 2>/dev/null | /usr/bin/sed -E 's/^[[:space:]]*"[^"]*"[[:space:]]*:[[:space:]]*//; s/,$//')
    print "    $k = ${v:-<not present>}"
  done
  /usr/bin/grep -A4 '^SSO Tokens:' "$S" 2>/dev/null | /usr/bin/sed 's/^/    /'
  REG_TRUE=0
  /usr/bin/grep -q '"registrationCompleted" : true' "$S" 2>/dev/null && REG_TRUE=1
  USER_STATE=$(/usr/bin/grep -m1 '"state"' "$S" 2>/dev/null | /usr/bin/sed -E 's/.*: "([^"]*)".*/\1/')
  if (( REG_TRUE )) && [[ -n "$USER_STATE" && "$USER_STATE" != *Normal* ]]; then
    print "    CHECK: device registration is complete but the user state is '$USER_STATE' (usually 'POUserStateNormal (0)' once user registration finishes)."
    print "           See the registration timeline below for whether user registration finished, and re-run after a log out/in."
  fi
  REG_UTC=$(/usr/bin/grep -m1 '"lastEncryptionKeyChange"' "$S" 2>/dev/null | /usr/bin/sed -E 's/.*: "([^"]*)".*/\1/')
  REG_EPOCH=$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$REG_UTC" '+%s' 2>/dev/null)
  if (( SSO_INST_EPOCH > 0 )) && [[ -n "$REG_EPOCH" ]]; then
    d_inst=$(( SSO_INST_EPOCH - REG_EPOCH ))
    if (( d_inst > 60 )); then
      print "    NOTE: the SSO profile was (re)installed $(fmt_dur $d_inst) AFTER the last device key change. Removing and reapplying the payload can prompt for registration again - see the 'Platform SSO PROMPT' lines in the timeline."
    else
      print "    SSO profile was installed $(fmt_dur $d_inst) before the last device key change (normal order: profile first, then registration)."
    fi
  fi
  print "    (lastEncryptionKeyChange/authGracePeriodStart approximate when registration completed;"
  print "     if that is older than the log window, zero registration events in the logs is expected)"
  print ""

  n_req=$(/usr/bin/grep -c 'Sending login request' "$POD" 2>/dev/null)
  n_res=$(/usr/bin/grep -c 'Login Result = ' "$POD" 2>/dev/null)
  n_ok=$(/usr/bin/grep -c 'Login Result = POLoginResultSuccess' "$POD" 2>/dev/null)
  print "[PSSO login attempts, PODiagnostics] requests=${n_req:-0} results=${n_res:-0} success=${n_ok:-0}"
  if (( ${n_req:-0} > ${n_res:-0} )); then
    print "    NOTE: $(( ${n_req:-0} - ${n_res:-0} )) login request(s) have no result line in this slice (inconclusive, not necessarily a failure)"
  fi
  TLF="$D4/log-show-registration-timeline-with-tz.txt"
  print "[registration timeline - Apple-side, IdP-agnostic; UTC converted from each line's own UTC offset]"
  apple_registration_timeline "$TLF"
  n_pshow=$(/usr/bin/grep -v '^#' "$TLF" 2>/dev/null | /usr/bin/grep -c 'Presenting <NotificationRecord app:"com.apple.PlatformSSO')
  n_presp=$(/usr/bin/grep -v '^#' "$TLF" 2>/dev/null | /usr/bin/grep -c 'Received response <NotificationRecord app:"com.apple.PlatformSSO')
  print "    Platform SSO registration prompts shown: ${n_pshow:-0}; user responded: ${n_presp:-0}"
  n_s0=$(/usr/bin/grep -v '^#' "$TLF" 2>/dev/null | /usr/bin/grep -c 'finishRegistrationWithStatus:message:\] success = 0')
  n_rm=$(/usr/bin/grep -v '^#' "$TLF" 2>/dev/null | /usr/bin/grep -c 'PODaemonProcess removeUserConfigurationForIdentifier')
  if (( ${n_s0:-0} > 0 )); then
    print "    CHECK: ${n_s0} registration(s) finished with success=0 (the reason is logged as <private> by macOS; look at the IdP extension lines in the Hub slice)."
  fi
  if (( ${n_rm:-0} > 0 )); then
    if (( ${n_s0:-0} > 0 )); then
      print "    CHECK: AppSSO removed the user configuration ${n_rm} time(s) and a registration finished with success=0 (a rolled-back user registration)."
    else
      print "    NOTE: AppSSO removed the user configuration ${n_rm} time(s) (expected when the SSO payload is removed or a registration is redone)."
    fi
  fi
  print "    (macOS prints each log line in the zone in effect when it was written; trust the UTC column, not mixed local times)"
  print ""
  print "[registration timeline - Microsoft Hub notifications] Microsoft.PlatformSSO.* seen by Hub (local time):"
  RT=$(/usr/bin/grep -hE 'Received notification:.*\(Microsoft\.PlatformSSO\.' "$D4/log-show-psso-all.txt" "$HH" 2>/dev/null | /usr/bin/sort -u | /usr/bin/sed -E 's/^([0-9-]+ [0-9:.]+) .*\((Microsoft\.PlatformSSO\.[A-Za-z.]+)\).*/    \1  \2/')
  if [[ -n "$RT" ]]; then print -r -- "$RT"; else print "    (none in window - expected if registration predates the window or Hub is not installed)"; fi
  print ""

  hh_bad=$(/usr/bin/grep -c '\[platformSSO\] health state is unhealthy' "$HH" 2>/dev/null)
  hh_ok=$(/usr/bin/grep -c '\[platformSSO\] health state is healthy' "$HH" 2>/dev/null)
  hh_sudo=$(/usr/bin/grep -c 'sudo: unknown user app-sso' "$HH" 2>/dev/null)
  print "[Hub health check, PSSO] unhealthy=${hh_bad:-0} healthy=${hh_ok:-0}  'sudo: unknown user app-sso' errors=${hh_sudo:-0}"
  if (( ${hh_bad:-0} + ${hh_ok:-0} == 0 )) && [[ "$EXT_ID" == *ws1* || "$EXT_ID" == *omnissa* || "$EXT_ID" == *airwatch* ]]; then
    hh_lines=0; [[ -s "$HH" ]] && hh_lines=$(/usr/bin/wc -l < "$HH" | /usr/bin/tr -d ' ')
    hh_tz_lines=0; [[ -s "$D5/log-show-hub-health-with-tz.txt" ]] && hh_tz_lines=$(/usr/bin/wc -l < "$D5/log-show-hub-health-with-tz.txt" | /usr/bin/tr -d ' ')
    note_quiet "Hub PSSO health was not captured. ${HH:t} has ${hh_lines} line(s) and log-show-hub-health-with-tz.txt has ${hh_tz_lines} line(s); neither contains '[platformSSO] health'. This is a gap in the evidence, not a pass."
  fi
  hub_health_details "$D5/log-show-hub-health-with-tz.txt"
  tenant_error_attribution
  if (( TENANT_TOTAL > 0 )); then
    if (( TENANT_HUB > 0 )); then
      note_quiet "'authority must have AAD tenant' (MSIDErrorDomain -51100) appeared ${TENANT_TOTAL} time(s) in the Microsoft SSO extension log: ${TENANT_HUB} for Hub (com.ws1.hub.*), ${TENANT_SAFARI} for Safari, ${TENANT_OTHER} for other or unattributed requesters. Hub's own requests hit this error; check the request in 04-psso-registration-logs."
    else
      note_quiet "'authority must have AAD tenant' (MSIDErrorDomain -51100) appeared ${TENANT_TOTAL} time(s) in the Microsoft SSO extension log: none for Hub, ${TENANT_SAFARI} for Safari, ${TENANT_OTHER} for other or unattributed requesters. Hub's own requests did not hit this error."
    fi
  fi
  REG_UTC=$(/usr/bin/grep -m1 '"lastEncryptionKeyChange"' "$S" 2>/dev/null | /usr/bin/sed -E 's/.*: "([^"]*)".*/\1/')
  REG_EPOCH=$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$REG_UTC" '+%s' 2>/dev/null)
  HUB_EXT=0
  [[ "$EXT_ID" == *ws1* || "$EXT_ID" == *omnissa* || "$EXT_ID" == *airwatch* ]] && HUB_EXT=1
  if (( ! HUB_EXT && ${hh_bad:-0} > 0 )); then
    print "    (Hub's PSSO health check evaluates Hub's own SSO extension; this Mac uses ${EXT_ID:-no extension}, so 'unhealthy' here is expected and is not a PSSO problem)"
  fi
  if (( HUB_EXT && ${hh_bad:-0} > 0 && REG_TRUE )) && [[ -n "$REG_EPOCH" ]]; then
    hub_health_vs_registration "$D5/log-show-hub-health-with-tz.txt" "$REG_EPOCH"
    print "    registration time (approx., lastEncryptionKeyChange): $(TZ=UTC /bin/date -r "$REG_EPOCH" '+%m-%d-%Y %H:%M:%S UTC')"
    if (( HH_BEFORE + HH_AFTER == 0 )); then
      print "    (could not place the 'unhealthy' evaluations in time - see log-show-hub-health-with-tz.txt)"
    elif (( HH_AFTER > 0 )) && [[ -z "$USER_STATE" || "$USER_STATE" == *Normal* ]]; then
      print "    MISMATCH: ${HH_AFTER} 'unhealthy' evaluation(s) occurred AFTER registration completed (app-sso says registrationCompleted=true and the user state is Normal or not reported); ${HH_BEFORE} before."
    elif (( HH_AFTER > 0 )); then
      print "    Consistent: ${HH_AFTER} 'unhealthy' evaluation(s) after device registration, but the user state is '$USER_STATE' (user registration not complete), so 'not registered' is accurate."
    else
      print "    Consistent: all ${HH_BEFORE} 'unhealthy' evaluation(s) predate registration (none seen after it)"
    fi
  fi
  print ""

  PL="$D4/log-show-psso-all.txt"
  username_findings
  print ""

  PK=$(/usr/bin/grep -v '^#' "$D2/pluginkit-auth-service-extension.txt" 2>/dev/null | /usr/bin/grep -c .)
  print "[pluginkit] lines matching 'auth-service-extension': ${PK:-0}"
  print "[pluginkit] SSO-related extensions:"
  /usr/bin/grep -v '^#' "$D2/pluginkit-sso-related.txt" 2>/dev/null | /usr/bin/sed 's/^/    /'
  print ""
  print "[hub] hubcli archive files : $(/usr/bin/find "$D5/hubcli-archive" -type f 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
  print "[sysdiagnose] output present : $([[ -n "${SD_OUT:-}" ]] && print yes || print no)"
  print ""
  validation_full
  print ""
  if (( ${#NOTES} )); then
    print "NOTES (${#NOTES}) - informational, not failures:"; for n in "${NOTES[@]}"; do print "  - $n"; done; print ""
  fi
  if (( ${#PROBLEMS} )); then
    print "PROBLEMS (${#PROBLEMS}):"; for p in "${PROBLEMS[@]}"; do print "  - $p"; done
  else
    print "PROBLEMS: none recorded"
  fi
} > "$STAGE/QUICK-FINDINGS.txt"

{
  /bin/cat "$STAGE/QUICK-FINDINGS.txt"
  for part in sw_vers uname date-timezone console-user hardware hub-and-sso-pkgs companyportal-pkg-info; do
    print ""
    print "================================================================================"
    print "SYSTEM CONTEXT: ${part}"
    print "================================================================================"
    /bin/cat "$D0/${part}.txt" 2>/dev/null
  done
} > "$WORK/Apple_PSSO_Configuration.txt"

# ---- number the files in each folder so they read in order, and fix the names quoted in the text files
typeset -a RENAMES; RENAMES=()
/bin/mkdir -p "$D6/network-probes"
for f in "$D6"/net-*; do [[ -e "$f" ]] && /bin/mv "$f" "$D6/network-probes/"; done
number_files "$D2" app-sso-platform-state.txt app-sso-listrealms.txt local-account-dscl.txt local-account-id.txt local-accounts-list.txt local-account-psso-link.txt pluginkit-sso-related.txt pluginkit-auth-service-extension.txt pluginkit-all.txt app-sso-help.txt
number_files "$D3" profiles-status-enrollment.txt profiles-show-enrollment.txt profiles-list.txt profiles-show-configuration.txt profiles-show-all.txt profiles-show-all-xml.txt psso-payload-extract.txt log-show-mdm-profile-install.txt configurationprofiles-dir-listing.txt
number_files "$D4" log-show-registration-timeline-with-tz.txt log-show-appsso-PODiagnostics.txt psso-config-seen-by-appsso.txt username-trace.txt log-show-psso-all.txt idp-extension-files
number_files "$D5" hubcli-logs-collect.txt hubcli-archive log-show-hub.txt log-show-hub-health-with-tz.txt hubcli-help.txt hubcli-logs-help.txt airwatch-dir-listing.txt files
number_files "$D6" swcutil-show.txt sntp-time.apple.com.txt scutil-proxy.txt pluginkit-idp-extension-detail.txt app-sso-platform-messages.txt klist.txt sso-crash-reports.txt network-agents.txt systemextensions-list.txt nc-list.txt appsso-log-config.txt safari-navigation-1.txt safari-navigation-2.txt safari-navigation-3.txt test-url-1.txt test-url-2.txt test-url-3.txt test-url-4.txt test-url-5.txt test-url-6.txt test-url-7.txt test-url-8.txt test-url-9.txt test-url-10.txt kerberos-url-1.txt kerberos-url-2.txt kerberos-url-3.txt network-probes
rewrite_renamed_names "$WORK/Apple_PSSO_Configuration.txt" "$WORK/collector.log"

cat > "$WORK/README.txt" <<EOF
PSSO + Hub diagnostic bundle - generated by ${SCRIPT_PATH:t} v$SCRIPT_VERSION
Host: $HOST   macOS: $OS_VER   Console user: ${CONSOLE_USER:-none}   Log window: $LOG_WINDOW${MODE_README:+   $MODE_README}
RESULT: ${RESULT_LINE}
        ${RESULT_WHY}

READ IN THIS ORDER
  1. Apple_PSSO_Configuration.txt   validation summary and quick findings first, then OS, timezone, hardware and packages
  2. collector.log                  every command the script ran, with its exit code
  3. The numbered folders, 01 to 06. Inside each folder the files are numbered 01, 02, 03 ... in the order to read them.

FOLDERS
  01-sysdiagnose/             Apple's sysdiagnose archive (unmodified) plus 00-how-this-sysdiagnose-was-captured.txt:
                              the exact command, time, exit code and checksum - give both to Apple Support
  02-psso-state/              what macOS reports about Platform SSO now (app-sso state, pluginkit, local account)
  03-mdm-payload/             the profiles MDM delivered and the install/update/removal log for them
  04-psso-registration-logs/  registration timeline, the payload as AppSSO logged it, user-name trace, unified-log slice
  05-hub-logs/                Intelligent Hub logs (hubcli archive, unified log, health check)
  06-validation/              evidence behind the automated checks (swcutil, clock, Safari tests (payload URLs and any --test-url), IdP/AASA network probes)
  MANIFEST.txt                every file with its size

Username questions: see Apple_PSSO_Configuration.txt "user strings" + "IdP-facing identity", and the username-trace and
local-account files in folders 04 and 02. macOS masks loginUserName (b***n@domain) and logs the registration user name
argument as <private>; the exact full string typed into the IdP sign-in page is not in these logs.

Privacy: logs contain usernames/UPNs/device identifiers. OAuth code/token URL parameters are redacted in the log slices,
but hubcli's Hublogs.tar.gz and the sysdiagnose are NOT redacted. Share on a need-to-know basis.
EOF

( cd "$WORK" && /usr/bin/find . -type f -exec /usr/bin/stat -f '%z  %N' {} + | /usr/bin/sort -k2 ) > "$WORK/MANIFEST.txt"

# =============================================================================
# package -> same directory as this script
# =============================================================================
ZIP="$OUT_DIR/${BUNDLE}-${RESULT_CODE}.zip"
log "== packaging -> $ZIP"
if /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$WORK" "$ZIP"; then
  [[ -n "$CONSOLE_USER" ]] && /usr/sbin/chown "$CONSOLE_USER" "$ZIP"
  print ""
  print "DONE: $ZIP  ($(/usr/bin/du -h "$ZIP" | /usr/bin/awk '{print $1}'))"
  print "RESULT: ${RESULT_LINE}"
  print "        ${RESULT_WHY}"
  if (( ${#NOTES} )); then print "Notes (informational):"; for n in "${NOTES[@]}"; do print "  - $n"; done; fi
  if (( ${#PROBLEMS} )); then
    print "Completed with ${#PROBLEMS} problem(s):"; for p in "${PROBLEMS[@]}"; do print "  - $p"; done
    exit 1
  fi
  exit 0
else
  print -u2 "FAILED to create zip at $ZIP (is the folder writable?)"
  exit 1
fi
