# Contributing to Allora Network repositories

This document captures the dev-workstation security baseline for everyone
contributing to Allora Network projects. It applies to every active repo
under the `allora-network` org (TypeScript/JS, Python, Go, Rust, Solidity —
the package-manager parts are language-specific; the credential and laptop
hygiene parts apply to everyone).

If you're triaging a real or suspected compromise on your machine, **stop
reading this file** and follow
[`SECURITY-RUNBOOK.md`](./SECURITY-RUNBOOK.md) → Scenario A.

> **Cross-doc link status.** This document links to
> `SECURITY-RUNBOOK.md` (DEVOP-571) and the IOC seed files under
> `.github/security/` (DEVOP-561). Those land in sibling PRs and may
> 404 on `main` until the related PRs merge. If a link is broken at
> the time you're reading this, check the open PRs on
> [`allora-network/.github`](https://github.com/allora-network/.github/pulls)
> or grep the repo (`git grep -l SECURITY-RUNBOOK`).

---

## TL;DR (new-joiner setup checklist)

Do these once on every machine you'll use for Allora work, before you
clone your first repo:

- [ ] Drop the user-level `~/.npmrc` template (see [§1](#1-npm--pnpm--corepack)).
- [ ] Enable Corepack: `corepack enable`.
- [ ] Install Socket CLI: `npm install -g socket` and add the shell alias from [§2](#2-socket-cli-wrapper).
- [ ] Install `uv`: `curl -LsSf https://astral.sh/uv/install.sh | sh`, then add the alias from [§3](#3-python-uv-pip-instead-of-raw-pip).
- [ ] Move every long-lived `NPM_TOKEN` / `PYPI_API_TOKEN` out of your
  shell rc — see [§4](#4-publishing-credentials-do-not-keep-locally).
- [ ] Migrate any GitHub PATs in 1Password to fine-grained ([§5](#5-github-tokens)).
- [ ] Bookmark the `SECURITY-RUNBOOK.md` link above.

The rest of this document explains why and provides the configuration
templates.

---

## 1. npm / pnpm / Corepack

The PyPI variant of Shai-Hulud abused `setup.py`; the npm variants abuse
`postinstall`, `preinstall`, and other lifecycle scripts. Disabling
lifecycle scripts on local installs is the single highest-impact
mitigation a dev can apply.

### `~/.npmrc` template

Put this in **`~/.npmrc`** (your user-level config, not in any repo):

```ini
# Allora Network dev-workstation security baseline (CONTRIBUTING.md §1).
#
# ignore-scripts=true: prevents postinstall/preinstall/install lifecycle
# scripts from running on `npm install` / `pnpm install` / `yarn install`.
# This is the Shai-Hulud npm-side mitigation. Some legitimate packages
# need a postinstall (esbuild, sharp, native modules) — for those, run
# the per-repo install with `npm install --ignore-scripts=false` after
# verifying the package is on the org's allowlist.
ignore-scripts=true

# fund=false: silence "consider funding" output. Cosmetic, but the
# install transcripts are noisy enough as it is.
fund=false

# audit-level=high: when you do run `npm audit`, only show high+critical.
# The low/moderate noise crowds out the signal.
audit-level=high

# save-exact=true: when you `npm install <pkg>`, pin the exact version
# in package.json rather than the default caret range. Reduces the
# blast radius of a published-but-not-yet-yanked compromised version.
save-exact=true
```

If a per-repo install genuinely needs lifecycle scripts (native modules,
build steps that aren't replicable in CI):

```bash
# Audit what the postinstall actually does:
npm pack <pkg>
tar -xzf <pkg>-<version>.tgz
cat package/package.json | jq '.scripts'
# Or for a transitive: pnpm why <pkg>; pnpm install --frozen-lockfile --ignore-scripts=false --include=optional <pkg>

# Then run the targeted install with scripts re-enabled for ONE command:
npm install --ignore-scripts=false
```

Do **not** flip `ignore-scripts` back to false in `~/.npmrc` as a default.

### Corepack (pin pnpm/yarn version per repo)

Corepack pins the package manager version to whatever `packageManager`
field is set in the repo's `package.json`. This eliminates "works on my
machine" issues *and* prevents drift onto a compromised package-manager
release.

Once, on every machine:

```bash
corepack enable
```

The first time you `cd` into a repo with `"packageManager":
"pnpm@9.15.0"` in its `package.json`, Corepack will fetch that exact
version on demand, verify the embedded signature, and use it.
Subsequent invocations are cached.

If you maintain a repo and `packageManager` isn't pinned in
`package.json`, fix that in a follow-up PR — see DEVOP-554.

---

## 2. Socket CLI wrapper

[Socket](https://socket.dev) maintains a real-time supply-chain risk
feed for npm and PyPI. Their free CLI wraps `npm install` (and `pnpm`,
`yarn`, `pip`) and refuses to install a package that matches a known
malware indicator. It's not a substitute for `ignore-scripts=true` —
it's a complement: Socket catches packages that haven't been pulled
from npm yet but have been flagged in their feed.

Install:

```bash
npm install -g socket
```

Add to your shell rc (`~/.zshrc` / `~/.bashrc`):

```bash
# Allora Network dev-workstation security baseline (CONTRIBUTING.md §2).
# Wrap interactive npm installs through Socket. This blocks installs of
# packages on Socket's risk feed before the malicious postinstall ever
# runs. The wrapper aliases only the interactive cases; CI installs are
# unaffected (CI uses --ignore-scripts and hashed lockfiles already).
alias npm-i='socket npm install'
alias pnpm-i='socket pnpm install'
```

When adding a new dependency to a repo:

```bash
npm-i <package>          # instead of: npm install <package>
pnpm-i <package>         # instead of: pnpm install <package>
```

Socket exits non-zero if the package or any transitive is flagged. If
you hit a flag, do **not** override; bring the alert to
`#security-alerts` first.

---

## 3. Python: uv pip instead of raw pip

`uv` is a drop-in replacement for `pip` and `pip-tools` written in Rust.
Two relevant properties for our threat model:

1. It refuses to install from an sdist by default in `--only-binary`
   mode — same defense as the Dockerfile install in
   `robonet-backend` (DEVOP-556).
2. It's much faster, so the "I'll just `pip install` real quick"
   muscle-memory becomes "I'll just `uv pip install` real quick" without
   the slowdown excuse.

Install:

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

Add to your shell rc:

```bash
# Allora Network dev-workstation security baseline (CONTRIBUTING.md §3).
# Prefer uv pip with hash-pinned + binary-only as the default for any
# local Python install. Mirrors the Docker production install hardening
# (DEVOP-556). For one-off "throwaway" venvs you can drop the
# --require-hashes flag; never drop --only-binary=:all:.
alias pip-i='uv pip install --require-hashes --only-binary=:all:'

# For repos that haven't migrated to hashed requirements.txt yet, this
# fallback gives you the binary-only protection without the hash check:
alias pip-i-binary='uv pip install --only-binary=:all:'
```

When working on a repo with a hashed `requirements.txt` (e.g.
`robonet-backend` post-DEVOP-556):

```bash
pip-i -r requirements.txt
```

For an exception (e.g. `jsonrpc-base` that only ships sdist on PyPI),
add `--no-binary=<pkg>` for that one package and document it in the
repo's `requirements.in`.

---

## 4. Publishing credentials: DO NOT keep locally

**Do not** put `NPM_TOKEN`, `PYPI_API_TOKEN`, or any registry-publish
credential in:

- Your shell rc (`~/.zshrc`, `~/.bashrc`).
- A user-level `~/.npmrc` or `~/.pypirc`.
- A `.env` file in any repo.
- Any 1Password entry that isn't in the "Break-glass" vault (which
  requires founder approval to access).

Publishing happens from CI, period. The CI workflows are configured per
DEVOP-545 (token written to `.npmrc` **after** install, with
`--ignore-scripts`, and deleted in the same step). The longer-term plan
is to migrate publish flows to OIDC Trusted Publishers (npm + PyPI both
support this) — see DEVOP-578. Once that lands, the only way to publish
to our packages will be via CI on `main`; even an admin can't override
from their laptop.

If you absolutely need to publish from a local machine for an emergency
release:

1. Coordinate in `#security-alerts` first (the same channel that runs
   incident response — this is deliberate; emergency publishes are
   incident-adjacent).
2. Use the runbook's [Scenario C](./SECURITY-RUNBOOK.md#5-scenario-c--compromised-package-published-from-our-org)
   step 4 procedure (clean environment, token kept out of disk, deleted
   immediately after publish).
3. Rotate the token immediately after publish.

---

## 5. GitHub tokens

### Fine-grained only

- **Do not create classic PATs.** GitHub still allows it; we don't. The
  audit log shows "classic PAT used by user X" as a distinct event, and
  the on-call should flag any new classic PAT issuance in the weekly
  security review.
- Use **fine-grained personal access tokens** for anything you actually
  need (most workflows can be done with a logged-in `gh auth login`
  session and don't need a token at all).
- When you create a fine-grained token, pin:
  - **Expiration**: 90 days max. No "no expiration" tokens.
  - **Resource owner**: the specific org or your user, never both.
  - **Repository access**: list each repo explicitly; do not select "all
    repositories" unless the use case actually requires it.
  - **Permissions**: minimum viable. The default offered scope is
    almost always wider than what the use case needs.

### Quarterly rotation

The DevOps on-call walks the credential rotation calendar
([SECURITY-RUNBOOK.md §7](./SECURITY-RUNBOOK.md#7-token-rotation-cadence))
on the 1st of every quarter. If you have a fine-grained token issued
more than 90 days ago, you'll get a Slack DM. Rotate within the week.

### SSH keys

- ed25519 keys only (`ssh-keygen -t ed25519`). RSA <3072 is rejected;
  3072+ works but is legacy.
- Hardware-backed if possible (SE on macOS via `ssh-keychain`, or
  YubiKey via `gpg-agent` / `ssh-keygen -t ed25519-sk`). Hardware
  backing turns a stolen laptop into a stolen-key-stays-on-the-device
  scenario.

---

## 6. Lockfiles

- **Commit your lockfile.** `package-lock.json`, `pnpm-lock.yaml`,
  `yarn.lock`, `bun.lock`, `requirements.txt` (hashed), `Cargo.lock`,
  `Pipfile.lock`, `uv.lock` — all in version control.
- **Never edit a lockfile by hand.** Re-run the package manager.
- **Never delete a lockfile to "fix" an install error.** The lockfile
  is the source of truth for which exact version got installed. If
  you delete it, regenerate it from a clean state and review the diff
  carefully before committing.
- In CI we run with `--frozen-lockfile` (npm/pnpm/yarn) or
  `--require-hashes` (pip) — failing the build rather than auto-
  updating the lockfile means a malicious mid-PR lockfile change can't
  slip through.

---

## 7. If you suspect your machine is infected

**STOP. Do not finish this PR. Do not commit.**

Open [`SECURITY-RUNBOOK.md`](./SECURITY-RUNBOOK.md) on a different
device and follow **Scenario A — Developer workstation suspected
infected**, which starts with disconnecting the machine from the
network.

Symptoms that warrant Scenario A:

- An unexpected `postinstall` log line during `npm install`.
- An unfamiliar process accessing `~/.npmrc`, `~/.aws/`, `~/.ssh/`, or
  `~/.gnupg/` (check Console.app → "Privacy & Security" log on macOS).
- Outbound network connections from your shell to a non-allowlisted
  host immediately after a package install (use Little Snitch or
  `lsof -i` to verify).
- Pre-commit hooks in `.git/hooks/` that you didn't write.
- A package install that "hung" and then "succeeded" with no visible
  output.

Erring toward Scenario A is free. We will not retroactively second-
guess anyone who triggered the runbook on a suspicion that turned out
to be a false alarm.

---

## 8. Code review expectations

- **Every PR that adds a new dependency must be reviewed by a second
  engineer.** The reviewer is responsible for cross-referencing the
  package against Socket (`socket package score <name>`) and the
  GitHub Advisory Database before approving. Yes, even for one-line
  PRs.
- PRs that modify any `package.json`, `pnpm-lock.yaml`, `requirements.in`,
  `requirements.txt`, `Cargo.toml`, `Cargo.lock`, `Pipfile`,
  `Pipfile.lock`, or `uv.lock` get an automatic `dependencies` label
  via the org's labeler workflow. Treat that label as a hint to spend
  the extra 5 minutes.
- Lockfile-only changes in a PR that doesn't claim to be a dependency
  bump are **suspicious by default** (this was the original Shai-Hulud
  worm propagation pattern). Reject and request a clean PR.

---

## 9. Links

- [SECURITY-RUNBOOK.md](./SECURITY-RUNBOOK.md) — incident response
  (Shai-Hulud-class supply-chain compromise).
- [`.github/security/ioc-packages.txt`](./.github/security/ioc-packages.txt) —
  current known-bad package@version pairs.
- [`.github/security/ioc-hashes.txt`](./.github/security/ioc-hashes.txt) —
  current known-bad SHA-256 hashes.
- [Socket free advisory feed](https://socket.dev/threat-feed) — refresh
  source for the IOC lists.
- [GitHub Advisory Database](https://github.com/advisories) — search
  by package name before approving a new dependency PR.

---

**Last updated:** 2026-05-13 (initial publication, DEVOP-572). For
runbook-level changes, edit `SECURITY-RUNBOOK.md` directly; this file
should stay focused on dev-workstation guidance.
