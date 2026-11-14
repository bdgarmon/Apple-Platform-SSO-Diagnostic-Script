# pssodiag: a Platform SSO diagnostic tool for macOS

`pssodiagv300.zsh` is a single-file zsh script that answers one question on a Mac:

> **Did Apple Platform SSO (PSSO) registration succeed, and is it working the way it was designed to?**

It gathers the evidence an engineer or Apple, Microsoft, Okta or Omnissa support would ask for, runs automated checks against that evidence and against the live network path, and packages everything into **one zip file**. The zip starts with a plain-English `RESULT:` line, and the result is also in the zip's file name, so you can tell a good capture from a bad one without opening it.

It was built for troubleshooting PSSO with **Microsoft Entra ID (the Intune Company Portal SSO extension)**, **Omnissa Workspace ONE Hub (the Hub SSO extension, for example with Omnissa Access)** and **Okta Verify**, plus **Kerberos** through Platform SSO or the Kerberos extension. The registration timeline, state, associated-domain, TLS and network checks work with any Redirect-type extension. A few checks are specific to one vendor, and those are marked.

A companion troubleshooting guide, built around this script, is on the [After Six Computers blog](https://aftersixcomputers.com/how-to-troubleshoot-apple-platform-sso/).

The current version is **3.0.0**. The version is in the script's file name and on the second line of the script.

---

## Contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Recommended workflow for a failing Mac](#recommended-workflow-for-a-failing-mac)
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
- [License and disclaimer](#license-and-disclaimer)

---

## What it does

1. **Collects evidence**
   - PSSO state from `app-sso platform -s`, the extension registration from `pluginkit`, and the local accounts.
   - The configuration profiles MDM delivered, including the Extensible SSO and Associated Domains payloads, and their install, update and removal events.
   - Unified-log slices for PSSO registration attempts, with every timestamp converted to UTC. macOS prints each log line in the time zone in effect when it was written, which misleads on a Mac that changes zone during Setup Assistant.
   - The identity provider extension's own log files (the Company Portal SSO extension, Okta Verify) when present, and Intelligent Hub's `hubcli` archive and unified log when Hub is installed.
   - A `sysdiagnose` archive, plus a record of exactly how it was captured, so it can be handed to Apple Support.
2. **Runs automated checks.** Registration state, the profile against the device, associated domains, TLS inspection, identity provider endpoints, clock skew, running web filters and VPNs, vendor-specific profile checks, Kerberos, leftover state, and live Safari tests. See [Checks it runs](#checks-it-runs).
3. **Answers in plain English.** The summary file, the end of the run and the zip name all carry a `RESULT:` line (registered or not, and why). A DIAGNOSIS section turns each recognized failure pattern into "what we see / what it means / what to do".
4. **Packages everything** as `PSSO-Diag-<hostname>-<timestamp>-<RESULT>.zip`.

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

1. Open **System Settings > Privacy & Security > Full Disk Access**. (`sudo ./pssodiagv300.zsh --open-fda-settings` opens the pane for you.)
2. Turn on the terminal app you use (Terminal, iTerm and so on), adding it with **+** if needed.
3. Quit the terminal app completely (Command-Q) and reopen it. macOS applies the permission only to terminals started afterwards.

---

## Quick start

```bash
# 1. Make the script executable
chmod +x ./pssodiagv300.zsh

# 2. Optional: syntax check
zsh -n ./pssodiagv300.zsh && echo OK

# 3. Optional: show the plan without collecting anything
sudo ./pssodiagv300.zsh --dry-run

# 4. Run it (it asks "Proceed? [y/N]" unless you pass --yes)
sudo ./pssodiagv300.zsh
```

When it finishes it prints the path of the zip, which is written to **the folder the script is in** unless you pass `--output-dir`. The `RESULT:` line, any informational notes and any collection problems are printed underneath.

### More examples

```bash
# Fast run right after a failed registration attempt
sudo ./pssodiagv300.zsh --tests-only

# Also test whether specific sites are handed to the SSO extension
sudo ./pssodiagv300.zsh --tests-only \
  --test-url https://login.microsoftonline.com/ \
  --test-url https://example-tenant.example.com/

# Kerberos web test against an internal site (runs curl as the logged-in user)
sudo ./pssodiagv300.zsh --kerberos-url https://intranet.example.com/

# Write the zip somewhere else
sudo ./pssodiagv300.zsh --output-dir /Users/Shared/diag

# Unattended, with a longer log window
sudo ./pssodiagv300.zsh --yes --log-window 3d
```

---

## Recommended workflow for a failing Mac

macOS keeps debug messages for the Platform SSO log subsystem only briefly unless it is asked to persist them. If you can reproduce the problem:

1. **Turn on persistent debug logging.**
   `sudo ./pssodiagv300.zsh --debug-logging on`
   It prints the exact `log config` command, asks first, changes the setting for the `com.apple.AppSSO` subsystem only, and exits without collecting anything. (For the Microsoft extension, Microsoft also suggests Company Portal > Settings > *Turn on advanced logging*.)
2. **Reproduce the problem.**
3. **Run the script right afterwards.**
   `sudo ./pssodiagv300.zsh --tests-only`
   This skips `sysdiagnose` and the `hubcli` archive and uses a three hour log window, so the evidence reflects the attempt you just made.
4. **Turn logging back to the default.**
   `sudo ./pssodiagv300.zsh --debug-logging off`

The script also reports, in every run, whether AppSSO debug logging is currently persisted (`appsso-debug-logging`), and the DIAGNOSIS section suggests the steps above when a failure would have benefited from it.

---

## Options

| Option | Meaning |
|---|---|
| `-y`, `--yes` | Skip the confirmation prompt. |
| `-n`, `--dry-run` | Print the plan and exit; collect nothing. |
| `--log-window <N>` | Unified-log lookback, for example `90m`, `6h`, `1d` (default `1d`). A number followed by `s`, `m`, `h` or `d`. |
| `--hub-duration <N>` | `hubcli` log duration, for example `1h`, `1d` (default `1d`). |
| `--skip-sysdiagnose` | Skip the (slow) sysdiagnose step. |
| `--tests-only` | Fast mode: no sysdiagnose, no `hubcli` archive, and a 3 hour log window unless `--log-window` is given. Use it right after a failed attempt. |
| `--no-browser-test` | Skip the background Safari navigation tests (the static checks still run). |
| `--output-dir <path>` | Folder for the finished zip. Default: the folder the script is in. The folder is created if needed and checked for write access before anything is collected. |
| `--test-url <url>` | Also test whether this URL is handed to the SSO extension. Repeatable, at most 10; each must be an `http://` or `https://` URL without spaces. |
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

```text
PSSO-Diag-<host>-<timestamp>/
  README.txt                       RESULT, reading order, script version, run mode
  Apple_PSSO_Configuration.txt     START HERE: RESULT, validation summary, DIAGNOSIS, then findings
  collector.log                    every command the script ran, with exit codes
  MANIFEST.txt                     every file with its size
  01-sysdiagnose/                  Apple's archive (unmodified) + how-it-was-captured record
  02-psso-state/                   app-sso state, pluginkit, local accounts, Kerberos realm info
  03-mdm-payload/                  installed profiles, SSO payload, install/update/removal log
  04-psso-registration-logs/       registration timeline, AppSSO config, user-name trace, extension logs
  05-hub-logs/                     Intelligent Hub logs and health-check slice
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

Then come the validation summary, the DIAGNOSIS section and the full list of checks (generic example):

```text
[PSSO validation summary] PASS=21  WARN=1  FAIL=2  INFO=9  SKIP=2
    FAIL  device-registration - registrationCompleted = false - Platform SSO is not registered on this Mac
    FAIL  user-registration - no user configuration in the state - no user is registered
    WARN  hub-allow-list - Microsoft's extension turned Hub away 1 time(s) ...

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

**Registration state**
- `device-registration`, `user-registration`, `device-keys`, `user-secure-enclave-key`, `sso-token`: registration completed, user state, key presence, token validity. When nothing is registered yet, dependent checks are skipped instead of repeating the failure. On a Mac that has **no Platform SSO configuration at all** (for example one that only uses the Kerberos extension) these checks, and `payload-extension-identity`, are skipped and the result is `KERBEROS-ONLY` or `NO-PSSO`.
- `extension-installed`, `extension-team`: the extension is registered with `pluginkit`; when macOS reports no team ID (normal before registration completes) the team is taken from the SSO payload.
- A registration timeline in UTC: prompts shown and answered, device configuration created, registration finished with `success=0/1`.

**The profile against the device**
- `payload-extension-identity`, `payload-auth-method`, `payload-urls-unique`: the payload names the extension macOS actually loaded, matches the registered login type, and lists each URL once.
- `payload-nonplatform-accounts`, `payload-nonplatform-account:*`, `payload-accounts-not-exempt`: whether any accounts are exempted from PSSO, whether those accounts exist locally, and that the logged-in user is not exempted.
- `payload-account-name`: reports the token-to-user mapping that is defined, without judging it.
- `payload-app-identifier:*`: Associated Domains application IDs match the extension's host app.
- `payload-setup-assistant`: reports the Setup Assistant (Simplified Setup) keys and whether the Mac is ADE-enrolled.

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
- `test-url:*` (`--test-url`): for any URL you name, checks whether the payload covers it (scheme, host and path prefix), what `swcutil` and the AASA say, and whether Safari actually hands it to the extension. With `--no-browser-test` you get a static prediction only.

**Microsoft and Hub together**
- `hub-allow-list` *(Microsoft extension only)*: Microsoft's extension turned the Hub app away because it is not on its allow list.
- `hub-authorization`: whether Hub's own SSO requests ended in an error, and via which extension.

**Okta** *(when Okta's extension is active)*
- `okta-preference-domains`, `okta-org-url`, `okta-protocol-version`, `okta-urls`, `okta-associated-domains`: the profile pieces Okta documents (two preference payloads, the org URL, protocol version 2.0, the nonce, token and device-sign paths, and both Okta app identifiers in Associated Domains). Okta Verify's own logs from the last three days are copied into the bundle.

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
- The Kerberos web test (`--kerberos-url`) makes a request to the URL as the logged-in user, which may request a service ticket.
- The finished zip is owned by the console user.
- **The one exception is `--debug-logging on|off`, which you request explicitly.** It asks first, changes the log setting for the `com.apple.AppSSO` subsystem only, and exits.

### Network activity

The script makes outbound connections to:

- Apple's AASA CDN (`app-site-association.cdn-apple.com` and `app-site-association.networking.apple`), and each tested host's `/.well-known/apple-app-site-association`
- the identity provider endpoints in the PSSO state (a nonce POST with no credentials, a JWKS GET, a token endpoint HEAD)
- `login.microsoftonline.com` (the sign-in probes, when the Microsoft extension is active)
- `time.apple.com` over UDP 123
- the hosts of any `--test-url` and `--kerberos-url` URLs
- for AD Kerberos realms, DNS SRV lookups (`_kerberos._tcp.<realm>`) and a TCP connection to port 88 on the first domain controller returned

The probes use `curl` and do not use the system proxy configuration.

---

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Completed; the zip was written (notes may have been printed). |
| `1` | Completed with one or more collection problems, or the zip could not be written. |
| `2` | Usage error, not root, not macOS, or an unusable `--output-dir`. |
| `3` | The terminal does not have Full Disk Access; nothing was collected. |
| `130` | Interrupted (Ctrl-C); the staging folder is cleaned up. |

`--debug-logging` exits `0` when it is cancelled or succeeds, and otherwise with the exit status of the `log config` command it ran. Note that the **result** (`REGISTERED`, `NOT-REGISTERED`, and so on) is not an exit code: a Mac that is not registered still produces a successful run.

---

## Compatibility, validation and limitations

### Compatibility and validation

- **Targets macOS 26 and 27.** Other versions are not supported.
- Developed iteratively against real captures from Macs on macOS 26.7.x and 27.2, using the Microsoft Company Portal and Omnissa Hub extensions, including a Hub with Okta federated through Omnissa Access, and Microsoft Entra Kerberos.
- The **Okta** checks are built from Okta's published profile and have had less live validation than the Microsoft and Hub checks. The **AD Kerberos** domain-controller checks and the **Kerberos web test** rely on tools and behavior (`dig`, `nc`, `curl --negotiate`) that depend on the Mac and network, so treat their results as evidence to confirm.

### Limitations

- **It cannot sign in for you.** It cannot force a PSSO login or token refresh, and it never sends credentials. The closest functional tests are the Safari navigation test and the Kerberos web test.
- **"Handed to the extension" is not "signed in".** The Safari tests show that macOS routed the request to the extension, not that the page then authenticated. They cover Safari and apps that use Apple's networking stack; browsers such as Chrome and Firefox are out of scope.
- **URL matching is an interpretation.** The static `--test-url` prediction uses the script's reading of how the payload's `URLs` entries match (scheme, host, path prefix). The live probe is the authority.
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
| `The output folder is not writable` | Choose another folder with `--output-dir`. |
| `--kerberos-url needs an http:// or https:// URL` | Give a full URL without spaces (at most 3). |
| `--debug-logging needs on or off` | Use `--debug-logging on` or `--debug-logging off`. |
| Many `FAIL` lines right after enrollment | Registration may not have completed yet; check `device-registration` first, since several checks depend on it. |
| Unsure which version produced a bundle | See the first line of `README.txt` and `collector.log` inside the bundle. |

---

## Versioning and file naming

The script's version is in two places that change together on every release:

- the **file name**: `pssodiagv` followed by the version without dots, for example version `3.0.0` is `pssodiagv300.zsh`
- the **header comment** on line 2, for example `# pssodiagv300.zsh v3.0.0`

The bundle's `README.txt` and `collector.log` also record the script version that produced them, which makes it easy to confirm which file someone actually ran.

| Version | Added |
|---|---|
| 2.0 | Full Disk Access gate; numbered, ordered files; the sysdiagnose capture record; retry while another sysdiagnose is running |
| 2.2 | Payload-versus-device checks |
| 2.5 | `--output-dir` |
| 2.6 | Per-pair Associated Domains checks |
| 2.7 | `--test-url`; handling of an unknown team ID before registration completes |
| 2.8 | Running web-filter and VPN detection with start times; Microsoft sign-in redirect probe; `--tests-only` |
| 3.0 | Plain-language `RESULT:` line and DIAGNOSIS section (result also in the zip name); AppSSO debug-logging status and `--debug-logging`; Okta checks and Okta Verify logs; payload settings listing and Setup Assistant key report; leftover-state checks; Kerberos checks and `--kerberos-url` |

---

## Reporting issues

When you open an issue, please include:

- the script version (file name and header), the macOS version, and which SSO extension is in use
- the command line you ran
- the `RESULT:` line, the **validation summary** and the specific lines that look wrong, with usernames, tenant IDs and host names removed

**Do not attach a full bundle or its sysdiagnose to a public issue**; both contain identifying data.

---
