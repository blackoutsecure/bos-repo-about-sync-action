# AGENTS.md

This file provides guidance to agents when working with code in this repository.

## What this is

`bos-repo-about-sync-action` is a single composite GitHub Action that keeps a repository's public **About** box in sync
with its README. It manages exactly three writable fields — **description**, **homepage** (the "Website" field), and
**topics** — plus three best-effort sidebar widget toggles (`show_releases`, `show_deployments`, `show_packages`) that
ride along on the repository `PATCH`. Marketplace primary/secondary categories are read and compared only: GitHub
exposes them through GraphQL but offers no supported category-write mutation, so the action reports drift and never
claims a write.

Desired values come from three sources, first non-empty wins: an explicit input (`description`, `homepage`, `topics`);
a GitHub Models generation from the README (opt-in via `ai_enabled`, plus `generate_topics`); then a deterministic
fallback (`description_fallback`, the extracted README prose seed, or `topics_fallback`). Homepage is never AI-derived.
In the managed fleet those inputs come from `.github/bos-universal-config.json` under `marketplace.repo_metadata`. The
main consumer is `bos-automation-hub/.github/workflows/repo-metadata-sync.yml`, which pins this action by commit SHA,
forwards every input, and resolves an `Administration: write` token (`REPO_ADMIN_PAT`, `RELEASE_PAT`, or a GitHub App
token), skipping the sync when none is available — the default `GITHUB_TOKEN` cannot PATCH repository settings.

Stack: a `composite` action whose only step runs bash; `jq`, `curl`, and `python3` required on PATH; Python `>=3.10`
for `helper.py` (stdlib only, so consumers need no `pip install`); pytest 8+, PyYAML 6+, ruff 0.6+ as dev extras. The
split is deliberate — bash owns orchestration, HTTP, and Actions plumbing; Python owns text parsing and normalization
that is painful and unsafe in shell.

## Commands

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"

pytest -q                                   # full suite
pytest -q test/test_helper.py               # single file
pytest -q test/test_action.py::TestDryRunContract::test_dry_run_resolves_outputs_without_writes

ruff check .
bash -n run.sh lib.sh
shellcheck -x -S error --shell=bash run.sh lib.sh
python3 helper.py sanitize-topics --max-count 20 --value 'GitHub_Actions security'

# Run the action body locally in dry-run mode (no API writes)
GITHUB_ACTION_PATH="$PWD" GITHUB_OUTPUT=/tmp/about.out GITHUB_STEP_SUMMARY=/tmp/about.md \
RUNNER_TEMP=/tmp REPO=blackoutsecure/example GH_TOKEN=dry-run-token README_PATH=README.md \
DESCRIPTION='A deterministic description.' DESCRIPTION_MAX_LEN=350 HOMEPAGE='https://x.test' \
TOPICS='github-actions security' GENERATE_TOPICS=false TOPICS_FALLBACK='' MAX_TOPICS=20 \
AI_ENABLED=false AI_MODEL=auto SHOW_RELEASES=true SHOW_DEPLOYMENTS=false \
SHOW_PACKAGES=false DRY_RUN=true bash run.sh
```

## Validating changes

CI is hub-driven. `.github/workflows/bos-universal-gatekeeper-kicker.yml` is the single front door and routes
dispatches to the hub's reusable workflows (`bos-universal-security.yml`, `bos-universal-sync.yml`,
`bos-universal-action-test.yml`, `repo-metadata-sync.yml`, `bos-universal-marketplace.yml`, `release-promote.yml`). The
only locally-defined workflow is `.github/workflows/scorecard.yml`. `action_test.python_packages` in
`.github/bos-universal-config.json` installs `-e .[dev]` for the action-test matrix. Locally, work narrowest-first:
`bash -n run.sh lib.sh`, then `shellcheck -x -S error --shell=bash run.sh lib.sh` (`-x` is required because `run.sh`
sources `lib.sh`), then `pytest -q test/test_helper.py`, then `pytest -q test/test_action.py`, then `ruff check .` and
the full `pytest -q`.

This action mutates live repository settings through the GitHub API. Never validate against a production repository:
use `DRY_RUN=true` / `dry_run: 'true'`, which short-circuits before any `PATCH`, `PUT`, `POST`, or `DELETE`, or a
disposable scratch repository you own. The test suite makes no network calls — every scenario runs with `DRY_RUN=true`
and a placeholder token.

## Architecture

| Path                                   | Role                                                                                                                                                                                                                                              |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `action.yml`                           | Manifest: inputs, outputs, and one bash step that maps inputs to `env:` and calls `run.sh`.                                                                                                                                                       |
| `run.sh`                               | Action body: validation, resolution, HTTP, reporting, outputs, job summary.                                                                                                                                                                       |
| `lib.sh`                               | Sourced bash library: `die`, `validate_bool`, `require_var`.                                                                                                                                                                                      |
| `helper.py`                            | Stdlib Python: README extraction, description clamping, topic sanitization — three CLI subcommands plus importable pure functions.                                                                                                                |
| `pyproject.toml`                       | Packaging, `dev` extras, pytest (`testpaths = ["test"]`), ruff (line-length 100).                                                                                                                                                                 |
| `test/`                                | Pytest only — there is no bats suite. `conftest.py` loads root `helper.py` as `repo_about_sync_helper`; `test_helper.py` covers the pure functions; `test_action.py` covers the manifest, `bash -n`/`shellcheck` gates, and `TestDryRunContract`. |
| `.github/bos-universal-config.json`    | Repo-owned overrides: marketplace path allowlists and this repo's own `repo_metadata` values.                                                                                                                                                     |
| `bos_repo_about_sync_action.egg-info/` | setuptools build output. Do not edit; should not be committed.                                                                                                                                                                                    |

Execution flow:

1. `action.yml` maps each input to an uppercase env var (`DESCRIPTION`, `TOPICS`, `DRY_RUN`, …), resolves `REPO` as
   `inputs.repo || github.repository` in the `env:` block (composite `default:` cannot reference the `github` context),
   and runs `bash "${GITHUB_ACTION_PATH}/run.sh"`.
2. `run.sh` sources `lib.sh` itself — functions do not cross the `bash` process boundary — validates via `require_var`
   / `validate_bool` / `die`, and asserts `jq`, `curl`, `python3` are on PATH.
3. It shells out to `python3 "${HELPER_PY}" <subcommand>` for all text work: `extract-readme`, `clamp-description`,
   `sanitize-topics`. AI generation, when enabled, `POST`s to `https://models.github.ai/inference/chat/completions` and
   degrades to the deterministic fallback with a warning on any failure.
4. A snapshot (`GET /repos/{owner}/{repo}`) plus a GraphQL `marketplaceListing` query feed the field-by-field report
   (`pass`/`change`/`skip`/`warn`/`fail`). Unless `DRY_RUN=true`: `PATCH /repos/{owner}/{repo}` then
   `PUT /repos/{owner}/{repo}/topics`. Outputs go to `$GITHUB_OUTPUT` (heredoc for the multi-line `report`) and a table
   to `$GITHUB_STEP_SUMMARY`.

Contract: `github_token` is the only required input and needs `Administration: write`; `homepage` accepts empty
(unchanged), `__unset__` (clear), or an `http(s)` URL and `die`s otherwise; `description_max_length` must be `1..350`;
`description_mode` is `auto|fallback|existing`; the category inputs accept empty, `auto`, or a slug from the hard-coded
`CATEGORY_SLUGS` allowlist. Outputs: `description`, `description_source`, `homepage`, `topics`, `topics_source`,
`ai_used`, `applied`, `changed`, `primary_category`, `secondary_category`, the two `*_category_confidence` values,
`report`, and `report_json`.

## Conventions

Bash: `set -euo pipefail` at the top of `run.sh` and inside the `action.yml` step body; `lib.sh` is sourced and carries
`# shellcheck shell=bash` instead. Defaults use `: "${VAR:=default}"`, and every expansion is quoted and braced. Hard
failures go through `die`, never a bare `exit 1`; warnings go through the local `annotate` wrapper so
`report_annotations: false` can silence them. HTTP calls capture the status with `-w '%{http_code}'`, use `--max-time`,
append `|| true`, and branch on the code before trusting the body.

```bash
case "${HOMEPAGE}" in
  '')          HOMEPAGE_OP="skip" ;;
  '__unset__') HOMEPAGE_OP="clear" ;;
  http://*|https://*) HOMEPAGE_OP="set"; HOMEPAGE_FINAL="${HOMEPAGE}" ;;
  *) die "input 'homepage' must be empty, '__unset__', or an http(s) URL (got: '${HOMEPAGE}')" ;;
esac
```

Python: `from __future__ import annotations`, full type hints, module-level compiled regexes in `SCREAMING_SNAKE_CASE`,
and a strict split between pure functions and thin `_cmd_*` argparse shims. Ruff selects `E,F,W,I,UP,B,C4`, ignores
`E501`, line-length 100; nothing outside the stdlib is imported.

```python
def sanitize_topics(raw: str, max_count: int = TOPIC_MAX_COUNT) -> list[str]:
    """Parse ``raw`` into a deduplicated list of GitHub-valid topics."""
    cap = min(max(max_count, 0), TOPIC_MAX_COUNT)
```

The two languages exchange data only as plain text over a pipe: bash passes values on stdin or via `--value`, Python
writes to stdout with no trailing newline, bash captures it with `$(...)`. There is no JSON contract and no shared
state — `jq` builds every payload in bash.

## Blackout Secure conventions

These apply to every repository in the `blackoutsecure` organization.

### Branch model

- `dev` is the default branch and where all work lands.
- `main` is the promoted stable runtime that consumers reference through `@main`.
- Version tags (`vX.Y.Z` and a floating `vX`) point at promoted runtime commits.
- Promotion is driven from `bos-automation-hub` (`release-promote.yml`). Do not push
  directly to `main` and do not move tags by hand.

### Centrally managed files - do not hand-edit here

`blackoutsecure/bos-automation-hub` distributes these through
`bos-managed-file-sync-action`. Change the source under the hub's `sync-files/`, never the
copy in this repository:

- `LICENSE`, `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`, `SECURITY.md`, `SUPPORT.md`
- `.github/FUNDING.yml`, `.github/PULL_REQUEST_TEMPLATE.md`, `.github/ISSUE_TEMPLATE/`
- `.github/workflows/bos-universal-gatekeeper-kicker.yml`
- the `# >>> managed-file-sync:<service> >>> ... # <<< managed-file-sync:<service> <<<`
  delimited blocks inside `.editorconfig`, `.markdownlint.yaml`, `.shellcheckrc`,
  `.yamllint.yml`, `.gitignore`, and `README.md`

`.github/bos-universal-config.json` is repo-owned. It holds this repository's overrides on
top of the hub's global config and is the right place to change gate behaviour.

### CI gate

Pushes and pull requests run the hub's reusable `bos-universal-security.yml`, reported as a
single required check. It runs markdownlint, yamllint, shellcheck, and actionlint; ESLint,
Prettier, Ruff, pytest, and Bats where the repository has them; `bos-code-scanning-kit`
(secret scan, SAST, GHAS posture) and CodeQL; dependency review; and compliance checks for
the canonical README header and a conventional-commit PR title
(`feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert: subject`).

Every `uses:` reference in a workflow must be a commit SHA with a trailing version comment,
for example `actions/checkout@<sha> # v4.2.2`.

## Boundaries

### Always

- Read `action.yml`, `run.sh`, `lib.sh`, and `helper.py` together; an input rename touches all four plus `test/test_action.py`.
- Wire every new input end to end (`inputs:` -> step `env:` -> validation -> resolution -> report row -> output) and document it in `README.md`.
- Run `bash -n`, `shellcheck -x -S error`, `ruff check .`, and `pytest -q` before finishing.
- Keep AI opt-in and every AI path degrading to a deterministic fallback.
- Treat inputs, README content, and AI/API responses as untrusted; sanitize through `helper.py` before anything reaches the GitHub API.

### Ask first

- Changing input names, defaults, or output names — the hub's `repo-metadata-sync.yml` passes every input by name and pins this action by SHA.
- Adding a runtime dependency to `helper.py`; consumers get it via `uses:` with no install.
- Widening the `CATEGORY_SLUGS` allowlist or claiming any Marketplace category write.
- Adding a new API endpoint, a new write, or a new locally-defined workflow.
- Editing `README.md` outside the managed-file-sync markers, or anything centrally managed.

### Never

- Run the action against a real repository during validation without explicit approval.
- Remove or bypass the `dry_run` short-circuit, or write before the snapshot and report rows are produced.
- Commit `bos_repo_about_sync_action.egg-info/` or any other build output.
- Commit tokens or PATs; tokens are read from env vars and must never be logged or interpolated unquoted into a shell command.
- Push directly to `main`, move version tags by hand, or add a bespoke CI workflow that duplicates a hub-managed one.
- Claim a write succeeded for Marketplace categories or the `show_*` widget fields.
