# pssodiag: a Platform SSO diagnostic tool for macOS

`pssodiagv331.zsh` is a single-file zsh script that answers one question on a Mac:

> **Did Apple Platform SSO (PSSO) registration succeed, and is it working the way it was designed to?**

It gathers the evidence an engineer or Apple, Microsoft, Okta or Omnissa support would ask for, runs automated checks against that evidence and against the live network path, and packages everything into **one zip file**. The zip starts with a plain-English `RESULT:` line, and the result is also in the zip's file name, so you can tell a good capture from a bad one without opening it.

It was built for troubleshooting PSSO with **Microsoft Entra ID (the Intune Company Portal SSO extension)**, **Omnissa Workspace ONE Hub (the Hub SSO extension, for example with Omnissa Access)** and **Okta Verify**, plus **Kerberos** through Platform SSO or the Kerberos extension. The registration timeline, state, associated-domain, TLS and network checks work with any Redirect-type extension. A few checks are specific to one vendor, and those are marked.

A companion troubleshooting guide, built around this script, is on the [After Six Computers blog](https://aftersixcomputers.com/how-to-troubleshoot-apple-platform-sso/).

The current version is **3.3.1**. The version is in the script's file name and on the second line of the script.

---

## Contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Recommended workflow for a failing Mac](#recommended-workflow-for-a-failing-mac)
- [The Redirect URL network tests](#the-redirect-url-network-tests)
- [Reading times in the logs](#reading-times-in-the-logs)
- [Options](#options)
- [What happens when you run it](#what-happens-when-you-run-it)
- [The output bundle](#the-output-bundle)
- [Reading the results](#reading-the-results)
- [Checks it runs](#checks-it-runs)
- [Privacy, security and what it changes](#privacy-security-and-what-it-changes)
- [Exit codes](#exit-codes)
- [Compatibility, validation and limitations](#compatibility-validation-and-limitations)
- [FAQ](#faq)
- [Troubleshooting the script](#troubleshooting-the-script)
- [Versioning and file naming](#versioning-and-file-naming)
- [Reporting issues](#reporting-issues)

---

## What it does

1. **Collects evidence**
   - PSSO state from `app-sso platform -s`, the extension registration from `pluginkit`, and the local accounts.
   - The configuration profiles MDM delivered, including the Extensible SSO and Associated Domains payloads, and their install, update and removal events.
   - An **MDM command and app install timeline** (which also lists the commands Intelligent Hub received on its agent channel): every request the MDM server sent this Mac, how the Mac answered, which profile each install was, and the apps the installer actually installed, by name (from `/var/log/install.log`), all in one time order. Each MDM-managed install is paired with the server app-install command that came just before it and shows the installer package it ran; app-install commands after the release are listed too. After an ADE enrollment made in Setup Assistant it lists them in order, calls out long quiet gaps, marks the SSO profile, says whether the SSO profile arrived before or after `DeviceConfigured`, names any app installed more than once before Setup Assistant was released, and flags an installer package that ran more than once. That shows where a "stuck in Setup Assistant" enrollment waited and what it was doing.
   - Unified-log slices for PSSO registration attempts, with every timestamp converted to UTC. macOS prints each log line in the time zone in effect when it was written, which misleads on a Mac that changes zone during Setup Assistant.
   - The identity provider extension's own log files (the Company Portal SSO extension, Okta Verify) when present, and Intelligent Hub's `hubcli` archive and unified log when Hub is installed.
   - A `sysdiagnose` archive, plus a record of exactly how it was captured, so it can be handed to Apple Support.
2. **Tests the Redirect URLs first.** Before it collects anything, it tests that the URLs in a Redirect-type SSO payload are online and reachable from this Mac, and that the payload lists the URLs the vendor requires. See [The Redirect URL network tests](#the-redirect-url-network-tests).
3. **Runs automated checks.** Registration state, the profile against the device, associated domains, TLS inspection, identity provider endpoints, clock skew, running web filters and VPNs, vendor-specific profile checks, Kerberos, leftover state, and live Safari tests. See [Checks it runs](#checks-it-runs).
4. **Answers in plain English.** The summary file, the end of the run and the zip name all carry a `RESULT:` line (registered or not, and why). A DIAGNOSIS section turns each recognized failure pattern into "what we see / what it means / what to do".
5. **Packages the evidence** as a small `PSSO-Diag-<hostname>-<timestamp>-<RESULT>.zip` that you send, plus a separate `...-heavy.zip` holding the Apple `sysdiagnose` (the one very large file), which you send only if asked. Everything else, including the Hub archive, is in the small zip. `--single-zip` puts everything in one zip.

The checks are automated greps and probes. They are a starting point, **not a verdict**. Everything they read is in the zip so you can confirm it.

---

## Requirements

| Requirement | Detail |
|---|---|
| macOS | 26 or 27 (the script warns on other versions). |
| Shell | `zsh`, which ships with macOS. No third-party dependencies: it uses only tools built into macOS. |
| Privileges | **Run as root** (`sudo`), because `sysdiagnose` requires it. Even `--dry-run` needs `sudo`. |
| Full Disk Access | The **terminal app** you run it from needs Full Disk Access. If it does not have it, the script stops with instructions before collecting anything. See [why](#why-does-the-terminal-app-need-full-disk-access). |
| A logged-in user | A user at the desktop (the "console user") is needed for the user-context checks, the Safari tests and the Kerberos web test. Without one, those checks are skipped. |
| MDM-managed Mac | PSSO is delivered by MDM, so the Mac is expected to be enrolled. |
| Network | Outbound HTTPS to Apple's AASA CDN, the identity provider endpoints and any URLs you test, and UDP 123 to `time.apple.com` for the clock check. |
| Optional | Workspace ONE Intelligent Hub (`/usr/local/bin/hubcli`) for Hub log collection. |

### Granting Full Disk Access

1. Open **System Settings > Privacy & Security > Full Disk Access**. (`sudo ./pssodiagv331.zsh --open-fda-settings` opens the pane for you.)
2. Turn on the terminal app you use (Terminal, iTerm and so on), adding it with **+** if needed.
3. Quit the terminal app completely (Command-Q) and reopen it. macOS applies the permission only to terminals started afterwards.

---

## Quick start

```bash
# 1. Make the script executable
chmod +x ./pssodiagv331.zsh

# 2. Optional: syntax check
zsh -n ./pssodiagv331.zsh && echo OK

# 3. Optional: show the plan without collecting anything
sudo ./pssodiagv331.zsh --dry-run

# 4. Run it (it asks "Proceed? [y/N]" unless you pass --yes)
sudo ./pssodiagv331.zsh
```

A file downloaded through a browser, including GitHub's download button, arrives **without the executable bit**, which is why step 1 is there. To skip it, run the script through the interpreter instead: `sudo zsh ./pssodiagv331.zsh`. It takes the same options, because the script finds its own path and does not need the bit. A zip keeps the bit inside the archive, so a script unzipped from `pssodiagv331.zip` is already executable. A `git clone` keeps it too, if the file was committed as executable (`git update-index --chmod=+x pssodiagv331.zsh` before the commit).

When it finishes it prints the path of the zip, which is written to **the folder the script is in** unless you pass `--output-dir`. The `RESULT:` line, any informational notes and any collection problems are printed underneath.

### More examples

```bash
# Fast run right after a failed registration attempt
sudo ./pssodiagv331.zsh --tests-only

# Run ONLY the Redirect URL network tests (no collection, no zip), for example after a firewall change
sudo ./pssodiagv331.zsh --test-url

# ...and also test some URLs of your own
sudo ./pssodiagv331.zsh --test-url https://login.microsoftonline.com/ https://example-tenant.example.com/

# Also check, with a Safari test, whether specific sites are handed to the SSO extension
sudo ./pssodiagv331.zsh --tests-only \
  --handoff-url https://login.microsoftonline.com/ \
  --handoff-url https://example-tenant.example.com/

# Kerberos web test against an internal site (runs curl as the logged-in user)
sudo ./pssodiagv331.zsh --kerberos-url https://intranet.example.com/

# Write the zip somewhere else
sudo ./pssodiagv331.zsh --output-dir /Users/Shared/diag

# Unattended, with a longer log window
sudo ./pssodiagv331.zsh --yes --log-window 3d
```

---

## Recommended workflow for a failing Mac

macOS keeps debug messages for the Platform SSO log subsystem only briefly unless it is asked to persist them. If you can reproduce the problem:

1. **Turn on persistent debug logging.**
   `sudo ./pssodiagv331.zsh --debug-logging on`
   It prints the exact `log config` command, asks first, changes the setting for the `com.apple.AppSSO` subsystem only, and exits without collecting anything. (For the Microsoft extension, Microsoft also suggests Company Portal > Settings > *Turn on advanced logging*.)
2. **Reproduce the problem.**
3. **Run the script right afterwards.**
   `sudo ./pssodiagv331.zsh --tests-only`
   This skips `sysdiagnose` and the `hubcli` archive and uses a three hour log window, so the evidence reflects the attempt you just made.
4. **Turn logging back to the default.**
   `sudo ./pssodiagv331.zsh --debug-logging off`

The script also reports, in every run, whether AppSSO debug logging is currently persisted (`appsso-debug-logging`), and the DIAGNOSIS section suggests the steps above when a failure would have benefited from it.

---

## The Redirect URL network tests

The first thing the script does on every run, before it collects anything, is test the **Redirect URLs** of the Redirect-type SSO payloads installed on the Mac. A firewall or web filter that blocks one of these URLs, a URL that is missing from the payload or has a typo, or a site that is offline, is among the most common reasons Platform SSO fails, and it takes seconds to see. Each URL and its result are shown on the screen **as it is tested**:

```text
Testing Microsoft Redirect URLs (the 3 that Microsoft requires)...
  https://login.microsoftonline.com                reachable (HTTP 200, 0.24 s)
  https://login.microsoft.com                      reachable (HTTP 200, 0.28 s)
  https://sts.windows.net                          NOT reachable - timed out (a firewall or proxy may be dropping the connection, or the site is offline)
```

The vendor is recognized from the extension named in the payload, and each vendor has a built-in list:

| Vendor | URLs the script knows | Tests, in this order |
|---|---|---|
| **Microsoft** | Required: `https://login.microsoftonline.com`, `https://login.microsoft.com`, `https://sts.windows.net`. Optional, for sovereign clouds: `https://login.partner.microsoftonline.cn`, `https://login.chinacloudapi.cn`, `https://login.microsoftonline.us`, `https://login-us.microsoftonline.com` ([Microsoft's list](https://learn.microsoft.com/en-us/intune/device-configuration/settings-catalog/configure-platform-sso-macos?tabs=secure-enclave)) | 1. Are the three required URLs online and reachable? 2. Does the payload include any of the optional URLs, and if so, are those reachable? 3. Does the payload include the three required URLs? |
| **Okta** | Your org's `/device-access/api/v1/nonce`, `/oauth2/v1/token` and `/v1/auth/device-sign` ([Okta's list](https://help.okta.com/oie/en-us/content/topics/oda/macos-pw-sync/configure-psso-se-macos-generic.htm)). The org host, including a custom domain, is read from the payload's URLs and `OktaVerify.OrgUrl` | Are they reachable? Does the payload include them? (The nonce URL is required for Secure Enclave and optional for password sync.) |
| **Omnissa Hub** | `https://<your Access tenant>/mpsso` ([Omnissa's documentation](https://docs.omnissa.com/AccessPlatformSSO/ApplePlatformSSO/)); the tenant is read from the payload | Is it reachable? Does the payload include it? |

**Apple's associated-domain servers.** After the vendor tests (whenever there is a Redirect payload, and always when you run `--test-url` on its own) the script also tests `https://app-site-association.cdn-apple.com` and `https://app-site-association.networking.apple`. macOS validates every SSO domain through Apple's CDN, and Microsoft documents that these two hosts must not be blocked or TLS-inspected, so a failure here is a **FAIL** and, in a full run, triggers the "Continue?" question.

After those, the script tests every **additional** Redirect URL the payload lists. If one nearly matches an expected URL it says so, for example "looks like a typo of https://login.microsoftonline.com". A Redirect payload for an extension the script has no list for has its own URLs tested. A Credential payload, such as Kerberos, has Hosts and no Redirect URLs, so it is skipped.

**How each URL is judged**
- **Reachable** means the server answered over HTTPS. Any HTTP status counts, because these are API endpoints that often answer a plain request with 404 or 405.
- **Up but failing** means the server answered with a 5xx error, so the service may be offline.
- **Not reachable** comes with a plain-English reason: the name does not resolve (DNS filtering, a typo, or a site that no longer exists), connection refused, timed out, connection reset, a TLS or certificate problem (the certificate issuer is shown), or a proxy that refused the connection.
- A required URL that fails, or a required URL missing from the payload, is a **FAIL**. A failing optional or additional URL is a **WARN**. An additional entry that does not resolve and does not look like a typo is **INFO**, because an entry can be a URL prefix that macOS matches and nothing is served there.
- The tests use the macOS system HTTPS proxy when one is set. With a proxy auto-config (PAC) file they connect directly, and the output says so, because a failure can then mean the Mac needs the PAC's proxy.

**Running them on their own.** `sudo ./pssodiagv331.zsh --test-url` runs only these tests and exits: no collection, no zip, no prompt, and no Full Disk Access needed (it does need `sudo`, to read the installed profiles). Put URLs after it to test those too (at most 10). The exit status is `0` when everything is fine and `1` when a required URL is unreachable or missing, or a URL you listed fails. Use it to re-test after a firewall or profile change.

**In a full run** they come first. If a required URL fails, the script asks `Continue with the full collection? [Y/n]` so you can stop and fix the network first; `--yes` continues without asking. The results are in the bundle as the `redirect-url:*` and `redirect-url-payload:*` checks, the full transcript is `06-validation/redirect-url-tests.txt`, and the DIAGNOSIS explains any failure.

---

## Reading times in the logs

Every time the script writes itself is **UTC**: `collector.log`, the header of each evidence file, the findings, the `Collected` line in `README.txt`, and the Company Portal receipt time. The raw log slices are different, and that matters when a Mac changes time zone part-way through. In the bundles collected so far the Mac started Setup Assistant in Pacific time (UTC-8) and switched to the right zone when user registration began, so the Mac's clock jumps by whole hours inside one file.

| File | How the time is written |
|---|---|
| `log show` slices in default style (the MDM slices, the registration timeline with time zone) | The Mac's clock plus a per-line UTC offset, for example `-0800` and later `-0700`. Unambiguous. |
| `log show` slices in compact style (the AppSSO slice) | The Mac's clock only, **with no offset**. Ambiguous across a zone change. |
| `install.log` events | The Mac's clock plus an hours-only offset, for example `-08`. |
| `app-sso` state, `swcutil`, `profiles show` install dates | UTC. |

The `Times:` lines at the top of the findings give the zone now, whether the Mac sets its zone automatically, and the measured instant of any offset change (the `timezone-change` check records the same). To read a compact-style line, treat it as UTC minus the earlier offset before that instant and UTC minus the later offset after it. The timelines in the findings already convert every line to UTC.

---

## Options

| Option | Meaning |
|---|---|
| `-y`, `--yes` | Skip the confirmation prompt. |
| `-n`, `--dry-run` | Print the plan and exit; collect nothing. |
| `--log-window <N>` | Unified-log lookback, for example `90m`, `6h`, `1d` (default `1d`). A number followed by `s`, `m`, `h` or `d`. When the ADE enrollment is older than the window, the slices that build the MDM timeline and the registration timeline are widened automatically to reach it, up to 14 days, unless you give `--log-window` yourself (the widening is noted in the findings). |
| `--hub-duration <N>` | `hubcli` log duration, for example `1h`, `1d` (default `1d`). |
| `--skip-sysdiagnose` | Skip the (slow) sysdiagnose step. |
| `--tests-only` | Fast mode: no sysdiagnose, no `hubcli` archive, and a 3 hour log window unless `--log-window` is given. Use it right after a failed attempt. |
| `--no-browser-test` | Skip the background Safari navigation tests (the static checks still run). |
| `--output-dir <path>` | Folder for the finished zip. Default: the folder the script is in. The folder is created if needed and checked for write access before anything is collected. |
| `--single-zip` | Put everything in **one** zip, as releases before 3.2 did. The default writes a small zip plus a separate `-heavy` zip that holds only the sysdiagnose. |
| `--light-only` | Write only the small zip. The `sysdiagnose` is not kept, so add `--skip-sysdiagnose` to avoid waiting for a sysdiagnose you will not use. Cannot be combined with `--single-zip`. |
| `--test-url [url ...]` | Run **only** the [Redirect URL network tests](#the-redirect-url-network-tests), then exit: no collection, no zip, no prompt, no Full Disk Access needed. URLs listed after it are tested too (at most 10, each `http://` or `https://` without spaces). Exit status `0` when all is well, `1` when a required URL is unreachable or missing or a URL you listed fails. |
| `--handoff-url <url>` | Also test, with static checks and a Safari test, whether this URL is handed to the SSO extension. Repeatable, at most 10; each must be an `http://` or `https://` URL without spaces. (Releases before 3.1 called it `--test-url`.) |
| `--kerberos-url <url>` | Kerberos web test: run `curl --negotiate` as the logged-in user, then look in `klist` for a service ticket for `HTTP/<host>`. Repeatable, at most 3. |
| `--debug-logging <on\|off>` | Turn persistent debug logging for the `com.apple.AppSSO` log subsystem on or off (it asks first, `--yes` skips the question), then exit without collecting anything. With `--dry-run` it only shows what it would do. |
| `--open-fda-settings` | Open the Full Disk Access pane, print the steps, and exit. |
| `-h`, `--help` | Show the version and options. |

---

## What happens when you run it

A full run takes about five minutes on the machines it was developed on. `sysdiagnose` is the slowest step, at roughly two to three minutes.

| Step | What it does |
|---|---|
| Start-up gate | Checks it is on macOS, running as root, and that the terminal has Full Disk Access. Prints the plan and asks to proceed. |
| Redirect URL tests | The first tests: each vendor's default URLs plus the URLs in the payload, shown live. If a required URL fails, it asks whether to continue. |
| 00 System context | OS version, hardware, time zone, installed SSO-related packages. |
| 01 sysdiagnose | Runs `sysdiagnose` with `-u -b` only when this macOS lists those flags. If another sysdiagnose is already running it waits and retries (up to 21 times, 15 seconds apart). |
| 02 PSSO state | `app-sso` state, `pluginkit` listings, local accounts, and Kerberos realm information, run as the console user where needed. |
| 03 MDM evidence | Installed profiles (secrets redacted), the SSO payload extract, and profile install, update and removal events. |
| 04 Registration logs | Unified-log slices for registration attempts, the PSSO configuration as AppSSO logged it, username traces, and the identity provider extension's own log files (including Okta Verify's logs from the last three days). |
| 05 Hub logs | `hubcli` archive and Hub unified-log slices (`--tests-only` skips the archive). |
| 06 Validation | The automated checks, including network probes, the vendor checks and the Safari tests. |
| Findings and packaging | Computes the result, writes the summary, numbers the files in reading order, and zips everything. |

The script works in a temporary staging folder under `/private/var/tmp` and removes it when it exits, including on Ctrl-C.

---

## The output bundle

The zip is named `PSSO-Diag-<hostname>-<YYYYMMDD-HHMMSS>-<RESULT>.zip`, where `<RESULT>` is one of `REGISTERED`, `REGISTERED-WITH-FAILURES`, `DEVICE-ONLY`, `NOT-REGISTERED`, `KERBEROS-ONLY` or `NO-PSSO`. It contains one folder with this layout:

By default the Apple `sysdiagnose`, which is the one very large file (over 100 MB), is moved into a second zip with the same name plus `-heavy` (`PSSO-Diag-<hostname>-<timestamp>-<RESULT>-heavy.zip`). **Nothing else moves**: the Hub archive stays in the small zip. The heavy zip's folder path matches the small zip, so unzipping both into one folder merges them. The small zip keeps a `MOVED-TO-HEAVY-ZIP.txt` in `01-sysdiagnose/` that lists the file with its size and SHA-256. Send the small zip first: it holds every finding and log slice. The sysdiagnose and `hubcli`'s `Hublogs.tar.gz` are not redacted, so share them on a need-to-know basis.

```text
PSSO-Diag-<host>-<timestamp>/
  README.txt                       RESULT, reading order, script version, run mode
  Apple_PSSO_Configuration.txt     START HERE: RESULT, validation summary, DIAGNOSIS, then findings
  collector.log                    every command the script ran, with exit codes
  MANIFEST.txt                     every file with its size
  MOVED-TO-HEAVY-ZIP.txt           (in 01-sysdiagnose) the sysdiagnose that moved to the -heavy zip, with its size and SHA-256
  01-sysdiagnose/                  Apple's archive (unmodified) + how-it-was-captured record
  02-psso-state/                   app-sso state, pluginkit, local accounts, Kerberos realm info
  03-mdm-payload/                  installed profiles, SSO payload, install/update/removal log, MDM command log, app install events
  04-psso-registration-logs/       registration timeline, AppSSO config, user-name trace, extension logs
  05-hub-logs/                     Intelligent Hub logs, the health-check slice and the agent-channel command slice (log-show-hub-commands.txt)
  06-validation/                   evidence behind the automated checks (network probes in a subfolder)
```

Inside each numbered folder the files are numbered (`01-`, `02-`, ...) in the order to read them.

### The sysdiagnose record

`01-sysdiagnose/00-how-this-sysdiagnose-was-captured.txt` states the exact command line, start and finish times, exit code, attempt count, macOS version and model, the archive's size and **SHA-256**, and the command's own output and usage text. Give it to Apple Support together with the `.tar.gz` so they know exactly how it was produced. The archive itself is never modified.

---

## Reading the results

Open `Apple_PSSO_Configuration.txt`. It starts with the answer (generic example):

```text
RESULT: Platform SSO is NOT registered on this Mac.
        The last registration attempt (11-10-2026 11:02:20 UTC) FAILED.
```

| Result (and zip suffix) | Meaning |
|---|---|
| `REGISTERED` | Device and user are registered, the user state is Normal, and no automated check failed. |
| `REGISTERED-WITH-FAILURES` | Registered, but at least one check failed. Read the FAIL lines. |
| `DEVICE-ONLY` | The Mac is registered but the user is not. |
| `NOT-REGISTERED` | No registration. The second line says why: a failed attempt, a prompt nobody answered, or no attempt in the log window. |
| `KERBEROS-ONLY` | The Mac does not use Platform SSO but has the Kerberos extension configured (for example an AD-bound Mac). The second line says whether the Kerberos checks passed. The Platform SSO checks are skipped. |
| `NO-PSSO` | No Platform SSO configuration, and no Kerberos extension, was found on this Mac. |

**What works (NOT-REGISTERED only).** When registration did not happen, the findings file, the `README.txt` in the zip and the screen at the end of the run add a short block under the result: a `WHAT WORKS` list of the checks that need no registration (sign-in and Apple server URLs reachable, Apple's associated-domains servers reachable and not intercepted, the Microsoft sign-in endpoint, the extension installed, domains approved by macOS, AASA files listing the extension, the clock), each with a count such as `5 of 5`, and a `NEEDS ATTENTION` list with every FAIL or WARN left. It is the answer to "is the network fine, and what actually stopped registration?" It is not printed for any other result.

Then come the validation summary, the DIAGNOSIS section and the full list of checks (generic example):

```text
[PSSO validation summary] PASS=21  WARN=1  FAIL=2  INFO=9  SKIP=2
    FAIL  device-registration - registrationCompleted = false - Platform SSO is not registered on this Mac
    FAIL  user-registration - no user configuration in the state - no user is registered
    INFO  hub-allow-list - Decision for you: Microsoft's extension turned Hub away 1 time(s) ...

DIAGNOSIS (what the checks suggest; confirm in the raw files)
  1. The last registration attempt (...) failed.
       What it means: macOS logs the reason as <private>. The extension's own log usually has the real reason.
       What to do:    Read the files under 04-psso-registration-logs/idp-extension-files ...
```

| Status | Meaning |
|---|---|
| `PASS` | The check succeeded. |
| `FAIL` | A real problem, or evidence of one. |
| `WARN` | Worth attention, but not necessarily wrong (for example an unused Associated Domains entry that macOS denied). |
| `INFO` | Context only: what is configured, what is running, a prediction. |
| `SKIP` | Not applicable or not possible here (for example a user check on a Mac with no registered user). |

The summary file also prints **every Platform SSO and extension-data setting the installed SSO payloads define**, with secrets hidden, so you can compare them with your vendor's documentation without opening the profile by hand.

Two other terms appear at the end of a run:

- **Notes** are informational (for example "no Hub health evaluation was logged in the window"). They never affect the exit status.
- **Problems** mean a collection step itself failed (for example `hubcli` not found). They make the script exit with status 1.

Everything printed at the end of the run is also in the bundle: the `RESULT:` line, notes and problems are in `Apple_PSSO_Configuration.txt`, `README.txt` and `collector.log`. Only the closing "DONE" line with the zip path is not, because the zip is closed before it prints.

---

## Checks it runs

Every check has a stable name (shown in `code` below), and the raw evidence is in `06-validation/` or the folder named in the check.

**Redirect URL network tests** (the first tests of every run; see [above](#the-redirect-url-network-tests))
- `redirect-url:<vendor>:<url>`: whether each URL is online and reachable, with the reason when it is not. Required URLs FAIL, optional and additional URLs WARN. Apple's two associated-domain servers are tested as vendor `apple` and are required.
- `redirect-url-payload:<vendor>[:<url>]`: whether the payload lists the URLs the vendor requires. A missing URL FAILs.
- `redirect-url-tests`: recorded when there is no Redirect-type payload to test.

**Registration state**
- `device-registration`, `user-registration`, `device-keys`, `user-secure-enclave-key`, `sso-token`: registration completed, user state, key presence, token validity. When nothing is registered yet, dependent checks are skipped instead of repeating the failure. On a Mac that has **no Platform SSO configuration at all** (for example one that only uses the Kerberos extension) these checks, and `payload-extension-identity`, are skipped and the result is `KERBEROS-ONLY` or `NO-PSSO`. When the Mac is **clearly not registered at all** (the `app-sso` state was read without error and holds no extension, no device keys and no user), `user-registration` and `device-keys` are reported as SKIP with the reason "skipped because Platform SSO is not registered on this Mac", and `device-registration` stays the one FAIL that says so. A failed state read, a missing exit-code line or any sign of a partial registration (a loaded extension or device keys) never counts as "not registered", so nothing is skipped in those cases.
- `extension-installed`, `extension-team`: the extension is registered with `pluginkit`; when macOS reports no team ID (normal before registration completes) the team is taken from the SSO payload. When the state names no extension, these checks, the association checks and the Microsoft sign-in checks use the extension and team that the Platform SSO payload names (only when exactly one payload does), and `extension-team` says so. That is why an unregistered Mac now gets a real answer from the association checks instead of a blank identity.
- A registration timeline in UTC: prompts shown and answered, device configuration created, registration finished with `success=0/1`.

**The profile against the device**
- `payload-extension-identity`, `payload-auth-method`, `payload-urls-unique`: the payload names the extension macOS actually loaded, matches the registered login type, and lists each URL once. `payload-extension-identity` always compares with the extension macOS actually loaded, never with the payload's own identity, and is skipped (with the same reason) when nothing is loaded because the Mac never registered.
- `payload-nonplatform-accounts`, `payload-nonplatform-account:*`, `payload-accounts-not-exempt`: whether any accounts are exempted from PSSO, whether those accounts exist locally, and that the logged-in user is not exempted.
- `payload-account-name`: reports the token-to-user mapping that is defined, without judging it.
- `payload-app-identifier:*`: Associated Domains application IDs match the extension's host app.
- `payload-setup-assistant`: reports the Setup Assistant (Simplified Setup) keys and whether the Mac is ADE-enrolled.

**Touch ID and payload review**
- `touch-id-requirement` *(Microsoft extension, Secure Enclave)*: whether Touch ID is required for the Secure Enclave key. It reports "required" when the payload has `enable_se_key_biometric_policy` = true in `ExtensionData` (Microsoft documents it as a Boolean; macOS 14.6 or later and Company Portal 2504 or later), and "not required" when it does not, in which case the key still works with the local password. It is a **WARN** when the policy is on but the ADE profile skips the Touch ID setup pane (`Biometric`), because users could not set up Touch ID. Setup Assistant's own Touch ID pane is separate from this policy.
- `payload-lint` (INFO unless two settings contradict each other): a documentation-backed review of the installed SSO payload. It flags `ExtensionData` keys that are misspelled, differ only in letter case from a documented key, are `com.apple.PlatformSSO.*` names used as keys, or are not on Microsoft's plug-in page; a duplicated top-level `AuthenticationMethod` (the macOS 13-only setting; a WARN if the two values differ); `LoginFrequency` set to the 64800 default; `AllowWebLoginPasswordSync` outside the OpenID method; `EnableAuthorization` on a Microsoft payload; `EnableCreateFirstUserDuringSetup` with Secure Enclave; an account name of `preferred_username` (full UPN) when Platform SSO creates accounts; and Standard authorization mode on a Mac with one local account.

**MDM command and app install timeline** (built from `03-mdm-payload/*log-show-mdm-commands.txt` and `*install-log-events.txt`; the timeline is also in the findings)
- `mdm-await-configuration`: whether the enrollment profile has `AwaitDeviceConfigured` on, which makes Setup Assistant wait for the MDM server to send `DeviceConfigured` ([Apple](https://developer.apple.com/documentation/devicemanagement/token-update) documents no timeout for that wait).
- `mdm-setup-gap`: after an ADE enrollment made in Setup Assistant (inside the log window), the longest stretch with no **delivery** command (a profile or app install) or MDM-managed install start, and the total time from enrollment to the last delivery activity. Inventory polls such as `InstalledApplicationList`, `ProfileList` and `SecurityInfo` do not count, because UEM sends one every few minutes and they hide a long wait. WARN at 10 minutes or more; the message also names any app installed more than once before the release and any installer package that ran twice, and says whether the SSO profile came before or after `DeviceConfigured`. A long app download can explain a gap; otherwise the server was waiting on something and not sending.
- `mdm-sso-profile-delay`: how long after the ADE enrollment the SSO profile reached the Mac. WARN at 5 minutes or more. Healthy enrollments seen so far took a few seconds. Setup Assistant waits for the MDM server meanwhile. The SSO profile is found by its payload type (`com.apple.extensiblesso`) in the installed profiles, not by its name.
- `mdm-sso-before-release`: when the SSO payload sets `EnableRegistrationDuringSetup`, whether the SSO profile was installed **before** the MDM sent `DeviceConfigured`. PASS when it was, because Setup Assistant can then run Platform SSO. **WARN** when it arrived after the release (the message gives how long after), because Setup Assistant had already finished and the Mac was registered from the normal prompt instead. Also a WARN when the enrollment profile has `AwaitDeviceConfigured = 0`, since Setup Assistant then does not wait for the MDM at all. INFO when the order cannot be told from the log window.
- `ade-profile` (INFO): the ADE profile ID this Mac received, the UEM server it enrolled through, and the settings that matter to Setup Assistant (`AwaitDeviceConfigured`, `AutoAdvanceSetup`, supervised, mandatory, how many panes are skipped, whether the Touch ID pane is hidden). The Mac cannot show UEM's own Platform SSO setting for that ADE profile, so use the ID to find the profile in your console and confirm it.
- `uem-condition-1-reconcile`, `uem-condition-2-hub-channel`, `uem-condition-3-dsm-retry`, `uem-condition-4-on-demand`, `uem-onboarding-intervals`, `uem-conditions` (all INFO): four server-side conditions that Omnissa is fixing in **UEM console 2701** can break Platform SSO during Setup Assistant, and a Mac log can show their symptoms and rule them out, but it cannot show UEM's own state, so each verdict is "consistent with", never proof. The same text is written as a `[Known UEM conditions ...]` block in the findings file, after the MDM timeline. The verdicts are `SIGNATURE PRESENT`, `SIGNATURE ABSENT`, `PATTERN SEEN` (an uncalibrated lead), `CANNOT TELL` (the evidence is not in the log window), `NOT APPLICABLE` and `DATA UNAVAILABLE`. (1) **Stale reconciliation status after ADE re-enrollment**: UEM keeps the previous enrollment's reconciliation status, so Platform SSO can find no assigned profiles, treat configuration as complete and queue `DeviceConfigured` before the PSSO profile is delivered. The check reports when `DeviceConfigured` was sent, when the SSO profile arrived, and when the first profile not delivered before the release arrived compared with when Hub registered with UEM. It always names the competing explanation, an ADE profile that is not set up for PSSO, which looks identical on the Mac; whether the serial was enrolled before is Data unavailable. (2) **PSSO commands delivered to Intelligent Hub instead of Apple's MDM client**: Hub's own log records every command it receives on its agent channel (requestor `com.airwatch.mac.agent`), and the check reports how many profile commands Hub received and whether each initialised the Hub-settings payload, and whether the SSO profile reached Apple's MDM client. A profile command without the Hub-settings payload is a lead, not proof, because Hub also receives other profile types. This pattern has not been checked against a confirmed case. (3) **PSSO retry creates a DSM override instead of an MDM command**: reports whether Hub logged its DSM and profile-at-scale modules as enabled (the Mac-side view of the two settings; the mapping is assumed), and whether the SSO profile stalled or never arrived while they were. A stall of that kind also happens when the ADE profile's PSSO App Bundle ID is the extension identifier instead of the app's bundle ID. The override itself is Data unavailable. (4) **On Demand profiles add delay**: Data unavailable, because the Mac's profile data holds no assignment type; the check reports how late the SSO profile arrived. `uem-onboarding-intervals` prints the spacing of `InstalledApplicationList` queries and of a re-sent installer package, so the two onboarding intervals that 2701 sets (2 and 5 minutes) can be compared before and after. `uem-conditions` says "not evaluated" when no ADE enrollment made in Setup Assistant is in the log window.
- `mdm-notnow`: how many commands the Mac answered `NotNow` (told the server to retry later) while in Setup Assistant.
- `timezone-change` (INFO, recorded only when it happens): the device clock offset changed during the log window, with the UTC instant and the clock times either side. See [Reading times in the logs](#reading-times-in-the-logs).

**Associated domains**
- `domain-association:*`: for each host, what `swcutil` decided for the extension. A missing payload entry is only a problem when macOS has no approval either, because some apps (for example Company Portal) carry their domains inside the app.
- `aasa-origin:*`, `aasa-cdn:*`, `aasa-cdn-vs-origin:*`: the domain's `apple-app-site-association` file, at its origin and as Apple's CDN serves it, lists the extension, and whether the two copies differ (Apple's CDN caches for hours).
- `pair:APP@DOMAIN`, `association-pairs`: every app and domain pair in the Associated Domains payload judged individually (the `swcutil` verdict plus whether the domain's file lists that app), with a count of how many pairs were judged where.
- `payload-foreign-domain:*`: one finding when your profile lists, for this extension, a domain that belongs to **another vendor** (for example Microsoft's sign-in domain in a Hub profile). That domain's AASA file lists only the other vendor's apps and macOS denied this extension for it, so the entry cannot work. It replaces the separate `domain-association`, `aasa-origin` and `aasa-cdn` failures for that domain and says what to remove. It applies only to domains listed in this extension's own profile, so a domain that another SSO payload lists is judged as before.

**Network path**
- `apple-cdn-tls:*`: flags TLS inspection of Apple's two AASA hosts, which Microsoft documents as unsupported. Skipped on a Mac with no Platform SSO configuration, where those servers do not matter.
- `idp-jwks`, `idp-nonce`, `idp-token`: the identity provider endpoints named in the PSSO state respond. The nonce request is Apple's documented server-nonce request and sends **no credentials**.
- `clock-skew`: offset against `time.apple.com`.
- `network-agents`, `network-agent:*`, `network-filter-profiles`: which web-filter, VPN and proxy agents are running (Netskope, Zscaler, GlobalProtect, CrowdStrike, Microsoft Defender, Cisco, Forcepoint, Cloudflare WARP, iboss), when their processes started relative to the last registration attempt, and which installed profiles carry content-filter, VPN, DNS-proxy, relay or global-proxy payloads.
- `signin-openid`, `signin-authorize` *(Microsoft extension only)*: whether Microsoft's sign-in endpoint is served over https from the real certificate chain, and whether anything redirects it to a non-https URL, the symptom behind MSAL error `-51116`.

**Functional**
- `safari-navigation:*`: opens the payload URLs in Safari in the background and checks whether AppSSO handed each one to the extension, naming the extension that received it.
- `handoff-url:*` (`--handoff-url`): for any URL you name, checks whether the payload covers it (scheme, host and path prefix), what `swcutil` and the AASA say, and whether Safari actually hands it to the extension. With `--no-browser-test` you get a static prediction only.

**Microsoft and Hub together**
- `hub-allow-list` *(Microsoft extension only)*: whether Microsoft's extension turned the Hub app away because it is not on its allow list. This is **information with a decision note** (no action is needed unless Hub's Microsoft sign-in should use Platform SSO), not a warning.
- `hub-authorization`: whether Hub's own SSO requests ended in an error, and via which extension. Requests rejected by Microsoft's extension are information; an error in Hub's own extension is a FAIL.

**Okta** *(when Okta's extension is active)*
- `okta-preference-domains`, `okta-org-url`, `okta-protocol-version`, `okta-urls`, `okta-associated-domains`: the profile pieces Okta documents (two preference payloads, the org URL, protocol version 2.0, the nonce, token and device-sign paths, and both Okta app identifiers in Associated Domains). A custom domain is accepted, as Okta documents; the check is that the same host is used in the payload URLs and in `OktaVerify.OrgUrl`. Okta Verify's own logs from the last three days are copied into the bundle.

**Kerberos** *(when a Kerberos extension payload, a Kerberos status in the PSSO state, or `--kerberos-url` is present)*
- `kerberos-status:<realm>`: the import and connection status the PSSO state reports per realm.
- `kerberos-tgt`, `kerberos-tgt-times`, `kerberos-realms`, `kerberos-dc:<realm>`: the logged-in user's TGTs, the configured realms, and for AD realms the DNS SRV lookup and TCP 88 reachability of a domain controller. The cloud realm `KERBEROS.MICROSOFTONLINE.COM` has no domain controller to reach.
- `kerberos-realm-info:<realm>`: the useful fields from `app-sso -i <realm>`: the last Kerberos login, when the password was last changed, the AD site, and whether the extension reports the network as available. It warns when `networkAvailable` is 0. It is not run for the cloud realm `KERBEROS.MICROSOFTONLINE.COM`, which is issued through Entra and is not a Kerberos extension realm, so `app-sso -i` has nothing to report for it.
- `kerberos-hosts-unique`, `kerberos-extension-config`: Apple requires every `Hosts` entry to be unique across all installed Extensible SSO payloads.
- `kerberos-url:*` (`--kerberos-url`): `curl --negotiate` as the user, then a check for the `HTTP/<host>` service ticket.

**Leftover state** (read-only)
- `sso-payloads`: which Extensible SSO payloads are installed.
- `registration-without-profile`: a registration exists but no installed payload carries Platform SSO settings.
- `local-account-psso-link:*`: whether local accounts carry a Platform SSO link (presence only; the values are never copied).

**Logging and other**
- `appsso-debug-logging`: whether AppSSO debug logging is persisted.
- `sso-crash-reports`, `system-proxy`.

---

## Privacy, security and what it changes

### What is collected

The bundle contains data that identifies the Mac and its user. Treat it as sensitive:

- usernames, UPNs and local account names (macOS masks some, for example `b***n@domain`, and logs others as `<private>`)
- host name, hardware model, macOS version, device identifiers
- the names and contents of installed configuration profiles, and the SSO and Associated Domains payload settings
- identity provider and tenant URLs, running security products, and log excerpts
- a full `sysdiagnose` and, when Hub is installed, a `hubcli` log archive

### Redaction (best effort)

- Key and certificate material in `app-sso` state and `profiles` output is redacted.
- OAuth `code=`, `activation_code=` and token URL parameters in the log slices are redacted.
- JWT-shaped strings in the saved PSSO sample messages, and the server nonce in the saved nonce response, are redacted.
- Settings whose names end in `Token` or `Secret` are hidden in the payload settings listing.
- **Not redacted:** the `sysdiagnose` archive and the `hubcli` log archive.

Review the bundle before sharing it, share it only through channels your organization permits, and do not attach it to public issues.

### What it changes on the Mac

It is **read-only apart from `sysdiagnose` and the `hubcli` archive**. It does not change profiles, settings, the keychain or the PSSO configuration, and it does not run any reset commands.

- It writes a temporary staging folder under `/private/var/tmp`, removed on exit.
- `sysdiagnose` writes its archive into that staging folder.
- The Safari tests open URLs in Safari in the background (about 15 seconds each). The script quits Safari afterwards only if the script started it. If the extension completes a sign-in for a URL you test, the identity provider may log a sign-in for that user, so prefer identity-provider login URLs.
- The Redirect URL tests send one plain request to each URL, with no credentials.
- The Kerberos web test (`--kerberos-url`) makes a request to the URL as the logged-in user, which may request a service ticket.
- The finished zip is owned by the console user.
- **The one exception is `--debug-logging on|off`, which you request explicitly.** It asks first, changes the log setting for the `com.apple.AppSSO` subsystem only, and exits.

### Network activity

The script makes outbound connections to:

- Apple's AASA CDN (`app-site-association.cdn-apple.com` and `app-site-association.networking.apple`), and each tested host's `/.well-known/apple-app-site-association`
- the identity provider endpoints in the PSSO state (a nonce POST with no credentials, a JWKS GET, a token endpoint HEAD)
- `login.microsoftonline.com` (the sign-in probes, when the Microsoft extension is active)
- `time.apple.com` over UDP 123
- the Redirect URLs (a plain GET with no credentials): Microsoft's, your Okta org's or Access tenant's, and any other URL the payload lists or you name with `--test-url`
- the hosts of any `--handoff-url` and `--kerberos-url` URLs
- for AD Kerberos realms, DNS SRV lookups (`_kerberos._tcp.<realm>`) and a TCP connection to port 88 on the first domain controller returned

The AASA, identity provider and sign-in probes use `curl` and do not use the system proxy configuration. The Redirect URL tests use the system HTTPS proxy when one is configured.

---

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Completed; the zip was written (notes may have been printed). |
| `1` | Completed with one or more collection problems, or the zip (or the `-heavy` zip) could not be written. |
| `2` | Usage error, not root, not macOS, or an unusable `--output-dir`. |
| `3` | The terminal does not have Full Disk Access; nothing was collected. |
| `130` | Interrupted (Ctrl-C); the staging folder is cleaned up. |

`--test-url` on its own exits `0` when every URL is fine and `1` when a required URL is unreachable or missing from the payload, or a URL you listed fails. `--debug-logging` exits `0` when it is cancelled or succeeds, and otherwise with the exit status of the `log config` command it ran. Note that the **result** (`REGISTERED`, `NOT-REGISTERED`, and so on) is not an exit code: a Mac that is not registered still produces a successful run.

---

## Compatibility, validation and limitations

### Compatibility and validation

- **Targets macOS 26 and 27.** Other versions are not supported.
- Developed iteratively against real captures from Macs on macOS 26.7.x and 27.2, using the Microsoft Company Portal and Omnissa Hub extensions, including a Hub with Okta federated through Omnissa Access, and Microsoft Entra Kerberos.
- The **Okta** checks are built from Okta's published profile and have had less live validation than the Microsoft and Hub checks. The **AD Kerberos** domain-controller checks and the **Kerberos web test** rely on tools and behavior (`dig`, `nc`, `curl --negotiate`) that depend on the Mac and network, so treat their results as evidence to confirm.

### Limitations

- **It cannot sign in for you.** It cannot force a PSSO login or token refresh, and it never sends credentials. The closest functional tests are the Safari navigation test and the Kerberos web test.
- **"Handed to the extension" is not "signed in".** The Safari tests show that macOS routed the request to the extension, not that the page then authenticated. They cover Safari and apps that use Apple's networking stack; browsers such as Chrome and Firefox are out of scope.
- **URL matching is an interpretation.** The static `--handoff-url` prediction uses the script's reading of how the payload's `URLs` entries match (scheme, host, path prefix). The live probe is the authority.
- **Log availability varies.** Results depend on what macOS has retained for the log window, and some messages are logged as `<private>`. Turning on persistent debug logging (see [the workflow](#recommended-workflow-for-a-failing-mac)) improves this.
- **Agent detection is heuristic.** A running web-filter or VPN process does not prove it is steering traffic; the TLS lines show whether interception is happening.
- **Some checks are extension-specific** (marked above), and the agent list is a fixed set of common products.
- **Associated-domain results can lag.** macOS evaluates associations on its own schedule; a freshly added pair may not have a `swcutil` entry yet.
- **Some things cannot be checked from the Mac:** whether the profile is assigned in MDM, the device record in the identity provider (for example the Entra join type), server-side logs, and the screen-lock and reboot reliability tests.

---

## FAQ

### Why does the terminal app need Full Disk Access?

**Short answer.** Platform SSO failures are usually explained in files that macOS protects from every process, including `sudo` and root, unless the app that launched them has Full Disk Access. The script cannot read those files without it, so it stops before collecting anything.

**Why it is needed**

- macOS applies its privacy protections (TCC) to the app a command was started from. Running the script with `sudo` from Terminal does not bypass them.
- The script reads locations in that protected category:
  - the Company Portal SSO extension's logs, in its app container (`~/Library/Containers/com.microsoft.CompanyPortalMac.ssoextension/...`)
  - Okta Verify's logs, in its group container
  - the system privacy database, which the script uses to test whether the permission was granted
- Those logs are the most useful evidence. When registration fails, macOS records the reason as `<private>` in the unified log. The extension's own log is where the real reason appears, for example `-51116 ... redirected to a non-https url`.
- macOS gives a script no way to request this permission. A person has to switch it on in System Settings.

**What happens without it**

- Earlier versions of the script ran anyway. They silently skipped those logs and produced a bundle that said "registration failed" without saying why, so support had to ask for a second run.
- The script now checks first. If the permission is missing it prints the steps to grant it and exits with status `3`. It collects nothing, changes nothing on the Mac, and does not start the several-minute `sysdiagnose`.
- Granting the permission requires restarting the terminal app anyway, so stopping at the start avoids a wasted run.
- Stopping is a design choice, not a macOS limit. The script could continue without the permission, but the result would be incomplete in exactly the way that matters most.

**What the permission does and does not do**

- It is granted to the terminal app, not to the script. The script is read-only apart from `sysdiagnose` and the `hubcli` archive.
- Nothing leaves the Mac. Everything goes into one zip that the administrator controls. See [Privacy, security and what it changes](#privacy-security-and-what-it-changes).
- The permission can be switched off afterwards: System Settings > Privacy & Security > Full Disk Access.
- While it is on, anything run in that terminal can read protected data. Grant it only on the Mac being diagnosed, and turn it off when you are finished.
- On managed Macs, an MDM privacy preferences (PPPC) profile can grant the permission to the terminal app. Review it with your security team before use.

---

## Troubleshooting the script

| Symptom | What to do |
|---|---|
| `This script must run as root` | Re-run with `sudo`. |
| `FULL DISK ACCESS IS REQUIRED` | Follow [Granting Full Disk Access](#granting-full-disk-access), then fully quit and reopen the terminal. Not sure why it is needed? See the [FAQ](#why-does-the-terminal-app-need-full-disk-access). |
| `sysdiagnose already in flight` | The script waits and retries automatically. If it still fails, wait for the other sysdiagnose to finish and re-run, or use `--skip-sysdiagnose`. |
| `Bad --log-window` | Use a number plus `s`, `m`, `h` or `d`, for example `90m` or `6h`. |
| `--single-zip and --light-only cannot be used together` | Choose one: one zip with everything, or the small zip only. |
| `The output folder is not writable` | Choose another folder with `--output-dir`. |
| `--test-url needs http:// or https:// URLs without spaces` | Give full URLs (at most 10). A word after `--test-url` that does not start with `http://` or `https://` is read as the next option and fails with `Unknown option`. |
| A URL "does not resolve" but works in a browser | The tests connect directly, or through the system HTTPS proxy. With a proxy auto-config (PAC) file the browser may be using a proxy the test does not. |
| `--kerberos-url needs an http:// or https:// URL` | Give a full URL without spaces (at most 3). |
| `--debug-logging needs on or off` | Use `--debug-logging on` or `--debug-logging off`. |
| Many `FAIL` lines right after enrollment | Registration may not have completed yet; check `device-registration` first, since several checks depend on it. |
| Unsure which version produced a bundle | See the first line of `README.txt` and `collector.log` inside the bundle. |

---

## Versioning and file naming

The script's version is in two places that change together on every release:

- the **file name**: `pssodiagv` followed by the version without dots, for example version `3.1.0` is `pssodiagv331.zsh`
- the **header comment** on line 2, for example `# pssodiagv331.zsh v3.3.1`

The bundle's `README.txt` and `collector.log` also record the script version that produced them, which makes it easy to confirm which file someone actually ran.

---

## Reporting issues

When you open an issue, please include:

- the script version (file name and header), the macOS version, and which SSO extension is in use
- the command line you ran
- the `RESULT:` line, the **validation summary** and the specific lines that look wrong, with usernames, tenant IDs and host names removed

**Do not attach a full bundle or its sysdiagnose to a public issue**; both contain identifying data.
