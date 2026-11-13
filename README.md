<!-- Draft only. Review required by Legal, Compliance, or relevant Omnissa control owner. -->

# pssodiag: a Platform SSO diagnostic collector for macOS

`pssodiagv280.zsh` is a single-file zsh script that answers one question on a Mac:

> **Did Apple Platform SSO (PSSO) registration succeed, and does it work the way it was designed to?**

It collects the evidence an engineer or Apple/IdP support would ask for, runs a set of automated checks against that evidence and against the live network path, and packages everything into **one zip file** with a plain-text summary at the front.

The registration timeline, state, associated-domain, TLS and network checks are IdP-agnostic and also give useful results for other Redirect-type extensions (for example Okta Verify). A few checks are specific to the Microsoft and Hub extensions; those are marked below.

The current version is **3.0.0**. The version is in the script's file name and in the first comment line of the script.

---

## Contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Options](#options)
- [What happens when you run it](#what-happens-when-you-run-it)
- [The output bundle](#the-output-bundle)
- [Reading the results](#reading-the-results)
- [Checks it runs](#checks-it-runs)
- [Privacy, security and what it changes](#privacy-security-and-what-it-changes)
- [Exit codes](#exit-codes)
- [Compatibility and limitations](#compatibility-and-limitations)
- [Troubleshooting](#troubleshooting)
- [Versioning and file naming](#versioning-and-file-naming)
- [Reporting issues](#reporting-issues)
- [License and disclaimer](#license-and-disclaimer)

---

## What it does

1. **Collects evidence**
   - PSSO state from `app-sso platform -s`, extension registration from `pluginkit`, and the local account list.
   - The configuration profiles MDM delivered, including the Extensible SSO and Associated Domains payloads, plus install, update and removal events.
   - Unified-log slices for PSSO registration attempts, with every timestamp converted to UTC. macOS prints each log line in the time zone in effect when it was written, which is misleading on a Mac that changes zone during Setup Assistant.
   - The IdP extension's own log files (for example the Company Portal `SSOExtension` logs), when present.
   - Workspace ONE Intelligent Hub logs (`hubcli` archive and unified log), when Hub is installed.
   - A `sysdiagnose` archive, plus a record of exactly how it was captured so it can be handed to Apple Support.
2. **Runs automated validation checks**: registration state, Associated Domains approval, TLS inspection of Apple's AASA CDN, IdP endpoint reachability, clock skew, running web filters and VPNs, a Microsoft sign-in redirect probe, and a live Safari test. See [Checks it runs](#checks-it-runs).
3. **Summarizes** everything in one text file, `Apple_PSSO_Configuration.txt`, which opens with a `PASS / WARN / FAIL / INFO / SKIP` summary.
4. **Packages** the result as `PSSO-Diag-<hostname>-<timestamp>.zip`.

The findings are automated checks and greps. They are a starting point, **not a verdict**. Confirm anything important in the raw files, which are all included.

---

## Requirements

| Requirement | Detail |
|---|---|
| macOS | 26 or 27 (the script prints a warning on other versions). Developed against real captures from macOS 26.7.x and 27.2. |
| Shell | `zsh` (ships with macOS). No third-party dependencies; it only uses tools built into macOS. |
| Privileges | **Run as root** (`sudo`), because `sysdiagnose` requires it. Even `--dry-run` needs `sudo`. |
| Full Disk Access | The **terminal app** you run it from must have Full Disk Access. If it does not, the script stops with instructions before collecting anything. |
| A logged-in user | A user at the desktop (the "console user") is needed for the user-context checks and the Safari test. Without one, those checks are skipped. |
| MDM-managed Mac | PSSO is delivered by MDM, so the Mac is expected to be enrolled. |
| Network | Outbound HTTPS to Apple's AASA CDN, the IdP endpoints and any URLs you test; UDP 123 to `time.apple.com` for the clock check. |
| Optional | Workspace ONE Intelligent Hub (`/usr/local/bin/hubcli`) for Hub log collection. |

### Granting Full Disk Access

1. Open **System Settings > Privacy & Security > Full Disk Access**. (`sudo ./pssodiagv280.zsh --open-fda-settings` opens the pane for you.)
2. Turn on the terminal app you use (Terminal, iTerm, and so on), adding it with **+** if needed.
3. Quit the terminal app completely (Command-Q) and reopen it. macOS applies the permission only to terminals started afterwards.

---

## Quick start

```bash
# 1. Make the script executable
chmod +x ./pssodiagv280.zsh

# 2. Optional: syntax check
zsh -n ./pssodiagv280.zsh && echo OK

# 3. Optional: show the plan without collecting anything
sudo ./pssodiagv280.zsh --dry-run

# 4. Run it (prompts "Proceed? [y/N]" unless you pass --yes)
sudo ./pssodiagv280.zsh
```

When it finishes it prints the path of the zip, which is written to **the folder the script is in** unless you pass `--output-dir`. Any informational notes and any collection problems are listed underneath.

### Common recipes

```bash
# Fast run right after a failed registration attempt (no sysdiagnose, no hubcli archive, 3 h log window)
sudo ./pssodiagv280.zsh --tests-only

# Also test whether specific sites are handed to the SSO extension
sudo ./pssodiagv280.zsh --tests-only \
  --test-url https://login.microsoftonline.com/ \
  --test-url https://example-tenant.example.com/

# Write the zip somewhere else
sudo ./pssodiagv280.zsh --output-dir /Users/Shared/diag

# Unattended, with a longer log window
sudo ./pssodiagv280.zsh --yes --log-window 3d
```

---

## Options

| Option | Meaning |
|---|---|
| `-y`, `--yes` | Skip the confirmation prompt. |
| `-n`, `--dry-run` | Print the plan and exit; collect nothing. |
| `--log-window <N>` | Unified-log lookback, for example `90m`, `6h`, `1d` (default `1d`). Format: a number followed by `s`, `m`, `h` or `d`. |
| `--hub-duration <N>` | `hubcli` log duration, for example `1h`, `1d` (default `1d`). |
| `--skip-sysdiagnose` | Skip the (slow) sysdiagnose step. |
| `--tests-only` | Fast mode: no sysdiagnose, no `hubcli` archive, and a 3 hour log window unless `--log-window` is given. Use it right after a failed attempt so the evidence is fresh. |
| `--no-browser-test` | Skip the background Safari navigation tests (the static checks still run). |
| `--output-dir <path>` | Folder for the finished zip. Default: the folder the script is in. The folder is created if needed and checked for write access before anything is collected. |
| `--test-url <url>` | Also test whether this URL is handed to the SSO extension. Repeatable, at most 10; each must be an `http://` or `https://` URL without spaces. |
| `--open-fda-settings` | Open the Full Disk Access pane, print the steps, and exit. |
| `-h`, `--help` | Show the version and options. |

---

## What happens when you run it

A full run takes about five minutes on the machines it was developed on. `sysdiagnose` is the slowest step at roughly two to three minutes.

| Step | What it does |
|---|---|
| Start-up gate | Checks it is on macOS, running as root, and that the terminal has Full Disk Access. Prints the plan and asks to proceed. |
| 00 System context | OS version, hardware, time zone, installed SSO-related packages. |
| 01 sysdiagnose | Runs `sysdiagnose` with `-u -b` only when this macOS lists those flags. If another sysdiagnose is already running it waits and retries (up to 21 times, 15 seconds apart). |
| 02 PSSO state | `app-sso` state, `pluginkit` listings, local accounts, run as the console user where needed. |
| 03 MDM evidence | Installed profiles (secrets redacted), the SSO payload extract, and profile install, update and removal events. |
| 04 Registration logs | Unified-log slices for registration attempts, the PSSO configuration as AppSSO logged it, username traces, and the IdP extension's own log files. |
| 05 Hub logs | `hubcli` archive and Hub unified-log slices (`--tests-only` skips the archive). |
| 06 Validation | The automated checks, including network probes and the Safari test. |
| Findings and packaging | Builds the summary, numbers the files in reading order, and zips everything. |

The script works in a temporary staging folder under `/private/var/tmp` and removes it when it exits, including on Ctrl-C.

---

## The output bundle

The zip is named `PSSO-Diag-<hostname>-<YYYYMMDD-HHMMSS>.zip` and contains one folder with this layout:

```text
PSSO-Diag-<host>-<timestamp>/
  README.txt                       reading order, script version, run mode
  Apple_PSSO_Configuration.txt     START HERE: validation summary, then quick findings
  collector.log                    every command the script ran, with exit codes
  MANIFEST.txt                     every file with its size
  01-sysdiagnose/                  Apple's archive (unmodified) + how-it-was-captured record
  02-psso-state/                   app-sso state, pluginkit, local accounts
  03-mdm-payload/                  installed profiles, SSO payload, install/update/removal log
  04-psso-registration-logs/       registration timeline, AppSSO config, user-name trace, extension logs
  05-hub-logs/                     Intelligent Hub logs and health-check slice
  06-validation/                   evidence behind the automated checks
```

Inside each numbered folder the files are numbered (`01-`, `02-`, ...) in the order to read them.

### The sysdiagnose record

`01-sysdiagnose/00-how-this-sysdiagnose-was-captured.txt` states the exact command line, start and finish times, exit code, attempt count, macOS version and model, the archive's size and **SHA-256**, and the command's own output and usage text. Give it to Apple Support together with the `.tar.gz` so they know exactly how it was produced. The archive itself is never modified.

---

## Reading the results

Open `Apple_PSSO_Configuration.txt`. The first block looks like this (generic example):

```text
[PSSO validation summary] PASS=21  WARN=1  FAIL=2  INFO=9  SKIP=2
    FAIL  device-registration - registrationCompleted = false - Platform SSO is not registered on this Mac
    FAIL  user-registration - no user configuration in the state - no user is registered
    WARN  hub-allow-list - Microsoft's extension turned Hub away 1 time(s) ...
```

| Status | Meaning |
|---|---|
| `PASS` | The check succeeded. |
| `FAIL` | A real problem, or evidence of one. |
| `WARN` | Worth attention, but not necessarily wrong (for example an unused Associated Domains entry that macOS denied). |
| `INFO` | Context only: what is configured, what is running, a prediction. |
| `SKIP` | Not applicable or not possible here (for example a user check on a Mac with no registered user). |

Two other terms appear at the end of a run:

- **Notes** are informational (for example "no Hub health evaluation was logged in the window"). They never affect the exit status.
- **Problems** mean a collection step itself failed (for example `hubcli` not found). They make the script exit with status 1.

Everything printed at the end of the run is also in the bundle: notes and problems are in `Apple_PSSO_Configuration.txt` and `collector.log`. Only the closing "DONE" line with the zip path is not, because the zip is closed before it prints.

---

## Checks it runs

All checks appear in the validation list with a stable name (shown in `code` below), and the raw evidence is in `06-validation/`.

**Registration state**
- `device-registration`, `user-registration`, `device-keys`, `user-secure-enclave-key`, `sso-token`: registration completed, user state, key presence and token validity. When nothing is registered yet, dependent checks are skipped instead of repeating the failure.
- `extension-installed`, `extension-team`: the extension is registered with `pluginkit`; when macOS reports no team ID (normal before registration completes) the team is taken from the SSO payload.
- A registration timeline in UTC: prompts shown and answered, device configuration created, registration finished with `success=0/1`.

**Configuration delivered by MDM**
- `payload-extension-identity`, `payload-auth-method`, `payload-urls-unique`: the payload names the extension macOS actually loaded, matches the registered login type, and lists each URL once.
- `payload-nonplatform-account:*`, `payload-accounts-not-exempt`: accounts exempted from PSSO exist locally; the logged-in user is not exempted.
- `payload-account-name`: reports the token-to-user mapping that is defined, without judging it.
- `payload-app-identifier:*`: Associated Domains application IDs match the extension's host app.

**Associated domains**
- `domain-association:*`: for each host, what `swcutil` decided for the extension (approved or denied). A missing payload entry is only a problem when macOS has no approval either, because some apps (for example Company Portal) carry their domains inside the app.
- `aasa-origin:*`, `aasa-cdn:*`: the domain's `apple-app-site-association` file, at its origin and as Apple's CDN serves it, lists the extension.
- `pair:APP@DOMAIN`: every app and domain pair in the Associated Domains payload judged individually (`swcutil` verdict plus whether the domain's AASA lists that app).

**Network path**
- `apple-cdn-tls:*`: flags TLS inspection of Apple's two AASA hosts, which Microsoft documents as unsupported.
- `idp-jwks`, `idp-nonce`, `idp-token`: the IdP endpoints named in the PSSO state respond. The nonce request is Apple's documented server-nonce request and sends **no credentials**.
- `clock-skew`: offset against `time.apple.com`.
- `network-agent:*`, `network-filter-profiles`: which web-filter, VPN and proxy agents are running (Netskope, Zscaler, GlobalProtect, CrowdStrike, Microsoft Defender, Cisco, Forcepoint, Cloudflare WARP, iboss), when their processes started relative to the last registration attempt, and which installed profiles carry content-filter, VPN, DNS-proxy, relay or global-proxy payloads.
- `signin-openid`, `signin-authorize` *(Microsoft extension only)*: whether Microsoft's sign-in endpoint is served over https from the real certificate chain, and whether anything redirects it to a non-https URL, the symptom behind MSAL error `-51116`.

**Functional**
- `safari-navigation:*`: opens the payload URLs in Safari in the background and checks whether AppSSO handed each one to the extension, naming the extension that received it.
- `test-url:*` (`--test-url`): for any URL you name, checks whether the payload covers it (scheme, host and path prefix), what `swcutil` and the AASA say, and whether Safari actually hands it to the extension. With `--no-browser-test` you get a static prediction only.

**Hub and Microsoft coexistence**
- `hub-allow-list` *(Microsoft extension only)*: Microsoft's extension turned the Hub app away because it is not on its allow list.
- `hub-authorization`: whether Hub's own SSO requests ended in an error, and via which extension.

**Other**
- `kerberos-tgt` (only when the PSSO state maps a Kerberos principal), `sso-crash-reports`, `system-proxy`.

---

## Privacy, security and what it changes

### What is collected

The bundle contains data that identifies the Mac and its user. Treat it as sensitive:

- usernames, UPNs and local account names (macOS masks some, for example `b***n@domain`, and logs others as `<private>`)
- host name, hardware model and macOS version, device identifiers
- the names and contents of installed configuration profiles and the SSO and Associated Domains payload settings
- IdP and tenant URLs, running security products, and log excerpts
- a full `sysdiagnose` and, when Hub is installed, a `hubcli` log archive

### Redaction (best effort)

- Key and certificate material in `app-sso` state and `profiles` output is redacted.
- OAuth `code=`, `activation_code=` and token URL parameters in the log slices are redacted.
- JWT-shaped strings in the saved PSSO sample messages and the server nonce in the saved nonce response are redacted.
- **Not redacted:** the `sysdiagnose` archive and the `hubcli` log archive.

Review the bundle before sharing it, share it only through channels your organization permits, and do not attach it to public issues.

### What it changes on the Mac

It is **read-only apart from `sysdiagnose` and the `hubcli` archive**. It does not change profiles, settings, the keychain or the PSSO configuration, and it does not run any reset commands.

- It writes a temporary staging folder under `/private/var/tmp`, removed on exit.
- `sysdiagnose` writes its archive into that staging folder.
- The Safari tests open URLs in Safari in the background (about 15 seconds each). The script quits Safari afterwards only if the script started it. If the extension completes a sign-in for a URL you test, the identity provider may log a sign-in for that user, so prefer identity-provider login URLs.
- The finished zip is owned by the console user.

### Network activity

The script makes outbound connections to:

- Apple's AASA CDN (`app-site-association.cdn-apple.com` and `app-site-association.networking.apple`), and each tested host's `/.well-known/apple-app-site-association`
- the IdP endpoints in the PSSO state (nonce POST with no credentials, JWKS GET, token endpoint HEAD)
- `login.microsoftonline.com` (the sign-in probes, when the Microsoft extension is active)
- `time.apple.com` over UDP 123
- the hosts of any `--test-url` URLs

These probes use `curl` and do not use the system proxy configuration.

---

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Completed; the zip was written (notes may have been printed). |
| `1` | Completed with one or more collection problems, or the zip could not be written. |
| `2` | Usage error, not root, not macOS, or an unusable `--output-dir`. |
| `3` | The terminal does not have Full Disk Access; nothing was collected. |
| `130` | Interrupted (Ctrl-C); the staging folder is cleaned up. |

---

## Compatibility and limitations

- **Targets macOS 26 and 27.** Other versions are not supported.
- **It cannot sign in for you.** It cannot force a PSSO login or token refresh, and it never sends credentials. The closest functional test is the Safari navigation test.
- **"Handed to the extension" is not "signed in".** The Safari tests show that macOS routed the request to the extension, not that the page then authenticated. They cover Safari and apps that use Apple's networking stack; browsers such as Chrome and Firefox are out of scope.
- **URL matching is an interpretation.** The static `--test-url` prediction uses the script's reading of how the payload's `URLs` entries match (scheme, host, path prefix). The live probe is the authority.
- **Log availability varies.** Results depend on what macOS has retained for the log window, and some messages are logged as `<private>`.
- **Agent detection is heuristic.** A running web-filter or VPN process does not prove it is steering traffic; the TLS lines show whether interception is happening.
- **Some checks are extension-specific** (marked above), and the agent list is a fixed set of common products.
- **Associated-domain results can lag.** macOS evaluates associations on its own schedule; a freshly added pair may not have a `swcutil` entry yet.

---

## Troubleshooting

| Symptom | What to do |
|---|---|
| `This script must run as root` | Re-run with `sudo`. |
| `FULL DISK ACCESS IS REQUIRED` | Follow [Granting Full Disk Access](#granting-full-disk-access), then fully quit and reopen the terminal. |
| `sysdiagnose already in flight` | The script waits and retries automatically. If it still fails, wait for the other sysdiagnose to finish and re-run, or use `--skip-sysdiagnose`. |
| `Bad --log-window` | Use a number plus `s`, `m`, `h` or `d`, for example `90m` or `6h`. |
| `The output folder is not writable` | Choose another folder with `--output-dir`. |
| Many `FAIL` lines right after enrollment | Registration may not have completed yet; check `device-registration` first, since several checks depend on it. |
| Unsure which version produced a bundle | See the first line of `README.txt` and `collector.log` inside the bundle. |

---

## Versioning and file naming

The script's version is in two places that change together on every release:

- the **file name**: `pssodiagv` followed by the version without dots, for example version `2.8.0` is `pssodiagv280.zsh`
- the **header comment** on line 2, for example `# pssodiagv280.zsh v2.8.0`

The bundle's `README.txt` and `collector.log` also record the script version that produced them, which makes it easy to confirm which file a customer actually ran.

Highlights of the 2.x line:

| Version | Added |
|---|---|
| 2.0 | Full Disk Access gate; numbered, ordered files; the sysdiagnose capture record; retry while another sysdiagnose is running |
| 2.2 | Payload-versus-device checks |
| 2.5 | `--output-dir` |
| 2.6 | Per-pair Associated Domains checks |
| 2.7 | `--test-url`; handling of an unknown team ID before registration completes |
| 2.8 | Running web-filter and VPN detection with start times; Microsoft sign-in redirect probe; `--tests-only` |

---

## Reporting issues

When you open an issue, please include:

- the script version (file name and header), the macOS version, and which SSO extension is in use
- the command line you ran
- the **validation summary** and the specific lines that look wrong, with usernames, tenant IDs and host names removed

**Do not attach a full bundle or its sysdiagnose to a public issue**; both contain identifying data.

---


This script is provided as is, without warranty. It is a diagnostic aid; its findings are automated checks and must be confirmed against the raw evidence. Run it on systems you are authorized to inspect, and handle the output according to your organization's data-handling policy.
