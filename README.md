# Repo About Box Sync

> Keep a repository's public **About** box — description, homepage, and
> topics — in sync with its README, without hand-editing GitHub settings
> on every release.

[![CI](https://github.com/blackoutsecure/bos-repo-about-sync-action/actions/workflows/ci.yml/badge.svg)](https://github.com/blackoutsecure/bos-repo-about-sync-action/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

A single composite GitHub Action. Point it at a repo (defaults to the
one the workflow runs in), and it resolves and applies:

- **Description** — from an explicit input, an AI rewrite of the
  README's lead paragraph (opt-in), or the raw README paragraph as a
  deterministic fallback.
- **Homepage** — from an explicit input only; never AI-derived.
- **Topics** — from an explicit input, AI-derived from the README
  (opt-in), or a configured fallback list.
- **Sidebar widget toggles** — Releases / Deployments / Packages
  (best-effort; GitHub does not document these fields on the public
  REST API, but the request still succeeds).

## Why

Repo "About" boxes go stale: descriptions get written once at repo
creation and never updated as the project evolves, topics are often
skipped entirely, and the homepage link rots. This action runs on
release (or on any trigger you choose) and keeps that box honest.

## Precedence

For every field, the **first non-empty source wins**:

1. **Explicit input** (`description:` / `homepage:` / `topics:`) —
   always wins. AI is never consulted when an explicit value is given.
2. **AI-generated content** (only when `ai_enabled: true`).
3. **Deterministic fallback** — the raw README paragraph for
   description, `topics_fallback` for topics. Homepage has no
   fallback; it's either set explicitly or left alone.

You can mix and match — e.g. set `description` explicitly, let AI pick
`topics`, and leave `homepage` untouched.

## Usage

### Fully explicit (no AI, no `models: read` needed)

```yaml
jobs:
  sync-about-box:
    runs-on: ubuntu-latest
    needs: release
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v5
      - uses: blackoutsecure/bos-repo-about-sync-action@v1
        with:
          # Default GITHUB_TOKEN cannot PATCH repo metadata — pass an
          # admin-capable PAT or installation token.
          github_token: ${{ secrets.REPO_ADMIN_PAT }}
          description: 'Lint, gate, and publish GitHub Marketplace Actions — without the boilerplate.'
          homepage:    'https://github.com/blackoutsecure/bos-repo-about-sync-action'
          topics:      'github-actions marketplace repository-metadata readme automation'
```

### AI-assisted

```yaml
jobs:
  sync-about-box:
    runs-on: ubuntu-latest
    needs: release
    permissions:
      contents: read
      models: read           # required for AI rewriting; fallback still works without it
    steps:
      - uses: actions/checkout@v5
      - uses: blackoutsecure/bos-repo-about-sync-action@v1
        with:
          github_token: ${{ secrets.REPO_ADMIN_PAT }}
          homepage: 'https://github.com/blackoutsecure/bos-repo-about-sync-action'
          ai_enabled: 'true'
          generate_topics: 'true'
          topics_fallback: 'github-actions devops marketplace'
          show_packages: 'true'   # opt in if your repo publishes packages
```

### Dry run

Set `dry_run: 'true'` to compute and log the proposed description /
homepage / topics to the job summary without calling the GitHub API.

## Inputs

| Input | Default | Description |
|---|---|---|
| `repo` | _(current repo)_ | Target repo in `owner/repo` form. |
| `github_token` | _(required)_ | Token with `Administration: write`. The default `GITHUB_TOKEN` is not sufficient. |
| `readme_path` | `README.md` | README used as source material. |
| `description` | `''` | Explicit description; wins over AI/README when set. |
| `description_max_length` | `350` | Hard clamp on the final description (GitHub's limit). |
| `homepage` | `''` | Explicit homepage URL. Pass `__unset__` to clear it. |
| `topics` | `''` | Explicit space/comma-separated topics; wins over AI/fallback. |
| `generate_topics` | `false` | Ask AI to derive topics from the README when `topics` is empty. |
| `topics_fallback` | `''` | Topics used if AI generation fails. |
| `max_topics` | `20` | Hard cap on topics applied (GitHub's ceiling is 20). |
| `ai_enabled` | `false` | Enable GitHub Models for description/topic generation. |
| `ai_model` | `openai/gpt-4o-mini` | GitHub Models model identifier. |
| `show_releases` | `true` | Releases sidebar widget (best-effort). |
| `show_deployments` | `false` | Deployments sidebar widget (best-effort). |
| `show_packages` | `false` | Packages sidebar widget (best-effort). |
| `dry_run` | `false` | Compute and log outputs without calling the API. |

## Outputs

| Output | Description |
|---|---|
| `description` | Final description applied (or computed under `dry_run`). |
| `description_source` | `explicit` \| `ai` \| `readme` \| `existing`. |
| `homepage` | Final homepage applied (empty if unchanged). |
| `topics` | Final topics applied, space-separated. |
| `topics_source` | `explicit` \| `ai` \| `fallback` \| `skipped`. |
| `ai_used` | `true` when GitHub Models produced the description or topics. |
| `applied` | `true` when at least one write succeeded; `false` under `dry_run`. |

## Permissions and tokens

- **Writing metadata** requires `Administration: write` on the target
  repo — the default `GITHUB_TOKEN` cannot PATCH repo settings or PUT
  topics. Pass a fine-grained PAT or GitHub App installation token via
  `github_token`.
- **AI generation** (`ai_enabled: true`) requires the calling job to
  grant `permissions: { models: read }`. Without it, the action logs a
  warning and falls back to the deterministic README seed / configured
  fallback topics.

## Security notes

- All inputs, README content, and AI/API responses are treated as
  untrusted; values are sanitized before being sent to the GitHub API.
- `dry_run: 'true'` never issues a PATCH, PUT, POST, or DELETE request.
- Tokens are read from environment variables, never logged, and never
  interpolated directly into shell commands without quoting.
- HTTP calls use an explicit timeout and validate the response status
  code before trusting the body.

## Local development

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"

ruff check .
bash -n run.sh lib.sh
shellcheck -x -S error --shell=bash run.sh lib.sh   # if installed
pytest -q
```

`test/test_action.py` exercises `run.sh` end to end in `dry_run` mode
(no network calls); `test/test_helper.py` covers the pure Python
helpers (README extraction, description clamping, topic sanitization).

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
