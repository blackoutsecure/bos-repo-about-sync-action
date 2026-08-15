#!/usr/bin/env bash
# Repo About Box Sync composite action body.
#
# Run as a child process by action.yml (`bash run.sh`). All inputs are
# inherited from the step's `env:` block; shared helpers are sourced
# from lib.sh below (functions are NOT inherited across the `bash`
# process boundary, so this script must source lib.sh itself). Emits
# GITHUB_OUTPUT rows + GITHUB_STEP_SUMMARY markdown.
#
# Flow:
#   1. Validate inputs.
#   2. Resolve description (explicit > AI > README fallback > leave).
#   3. Resolve topics (explicit > AI > fallback > skip).
#   4. Resolve Marketplace categories and compare them with the listing.
#   5. PATCH /repos/{owner}/{repo} with description + homepage +
#      show_* flags. PUT /repos/{owner}/{repo}/topics with names.
#   6. Write outputs + summary.
#
# Dry-run short-circuits before any API write.

set -euo pipefail

: "${ERR_TITLE:=Repo About Box Sync}"
: "${PRIMARY_CATEGORY:=auto}"
: "${SECONDARY_CATEGORY:=auto}"
: "${MARKETPLACE_SLUG:=}"
: "${AI_MODEL:=auto}"
: "${DESCRIPTION_MODE:=auto}"
: "${DESCRIPTION_FALLBACK:=}"

# Shared helpers (die / require_var / validate_bool / ...). Sourced here
# rather than relying on action.yml's source line, because run.sh runs
# in a child `bash` process that does not inherit the parent shell's
# functions. lib.sh is resolved via the GHA-provided $GITHUB_ACTION_PATH.
# shellcheck source=./lib.sh
. "${GITHUB_ACTION_PATH}/lib.sh"

HELPER_PY="${GITHUB_ACTION_PATH}/helper.py"
[ -f "${HELPER_PY}" ] || die "internal: helper.py not found at ${HELPER_PY}"

# ---------- Input validation -------------------------------------------------

require_var REPO
require_var GH_TOKEN
require_var README_PATH
MODELS_TOKEN="${MODELS_TOKEN:-${GH_TOKEN}}"

case "${REPO}" in
  */*/*|/*|*/|'') die "input 'repo' must be exactly 'owner/repo' (got: '${REPO}')" ;;
  */*) ;;
  *) die "input 'repo' must be exactly 'owner/repo' (got: '${REPO}')" ;;
esac

case "${DESCRIPTION_MAX_LEN}" in
  ''|*[!0-9]*) die "input 'description_max_length' must be a positive integer (got: '${DESCRIPTION_MAX_LEN}')" ;;
esac
if [ "${DESCRIPTION_MAX_LEN}" -lt 1 ] || [ "${DESCRIPTION_MAX_LEN}" -gt 350 ]; then
  die "input 'description_max_length' must be in 1..350 (got: ${DESCRIPTION_MAX_LEN})"
fi

case "${MAX_TOPICS}" in
  ''|*[!0-9]*) die "input 'max_topics' must be a non-negative integer (got: '${MAX_TOPICS}')" ;;
esac

validate_bool GENERATE_TOPICS
validate_bool AI_ENABLED
validate_bool SHOW_RELEASES
validate_bool SHOW_DEPLOYMENTS
validate_bool SHOW_PACKAGES
validate_bool DRY_RUN

CATEGORY_SLUGS='ai-assisted api-management chat code-quality code-review continuous-integration dependency-management deployment ides learning localization mobile monitoring open-source-management project-management publishing security support testing utilities'

validate_category() {
  case "$1" in
    ''|auto) return 0 ;;
  esac
  for category in ${CATEGORY_SLUGS}; do
    [ "${category}" = "$1" ] && return 0
  done
  die "category must be empty, auto, or a current GitHub Marketplace category slug (got: '$1')"
}

validate_category "${PRIMARY_CATEGORY}"
validate_category "${SECONDARY_CATEGORY}"

case "${DESCRIPTION_MODE}" in
  auto|fallback|existing) ;;
  *) die "input 'description_mode' must be auto, fallback, or existing (got: '${DESCRIPTION_MODE}')" ;;
esac

if [ -z "${AI_MODEL}" ] || [ "${AI_MODEL}" = "auto" ]; then
  AI_MODEL="${GITHUB_MODELS_MODEL_METADATA:-${GITHUB_MODELS_MODEL:-openai/gpt-4o-mini}}"
fi

# ---------- Tool checks ------------------------------------------------------

for tool in jq curl python3; do
  command -v "${tool}" >/dev/null 2>&1 || die "required tool '${tool}' not on PATH"
done

OWNER="${REPO%%/*}"
REPO_NAME="${REPO##*/}"
case "${OWNER}" in
  ''|*[!A-Za-z0-9._-]*) die "owner segment of 'repo' is invalid: '${OWNER}'" ;;
esac
case "${REPO_NAME}" in
  ''|*[!A-Za-z0-9._-]*) die "repo segment of 'repo' is invalid: '${REPO_NAME}'" ;;
esac

# ---------- Resolve description ---------------------------------------------
#
# Precedence (first non-empty wins):
#   1. ``DESCRIPTION`` input — caller explicitly provided one.
#   2. AI rewrite of the README seed, when ``AI_ENABLED=true``.
#   3. The README seed itself (deterministic fallback).
#   4. Leave the existing description untouched (source = ``existing``).

DESC_FINAL=""
DESC_SOURCE="existing"
AI_USED="false"

if [ "${DESCRIPTION_MODE}" = "existing" ]; then
  DESC_SOURCE="existing"
elif [ -n "${DESCRIPTION}" ]; then
  DESC_FINAL=$(printf '%s' "${DESCRIPTION}" | python3 "${HELPER_PY}" clamp-description --max-len "${DESCRIPTION_MAX_LEN}")
  DESC_SOURCE="explicit"
else
  if [ ! -f "${README_PATH}" ]; then
    echo "::warning::repo-about-sync: README '${README_PATH}' not found; leaving description unchanged"
  else
    README_SEED=$(python3 "${HELPER_PY}" extract-readme "${README_PATH}" --max-len 1500 || true)
    if [ -z "${README_SEED}" ]; then
      echo "::warning::repo-about-sync: could not extract a prose summary from '${README_PATH}'; leaving description unchanged"
    else
      DESC_CANDIDATE=""
      if [ "${DESCRIPTION_MODE}" = "auto" ] && [ "${AI_ENABLED}" = "true" ]; then
        # ---- AI rewrite -------------------------------------------
        AI_OUT="${RUNNER_TEMP:-/tmp}/repo-about-sync.desc.json"
        AI_ERR="${RUNNER_TEMP:-/tmp}/repo-about-sync.desc.err"
        PROMPT=$(printf 'You are a GitHub repo description editor. Rewrite the README excerpt below as ONE punchy single-sentence summary of what this repository does, suitable for the "About" box. Hard limits: maximum %d characters, no trailing period, no markdown, no quotes, no emoji, plain prose only. Excerpt:\n\n%s' "${DESCRIPTION_MAX_LEN}" "${README_SEED}")
        PAYLOAD=$(jq -Rs --arg model "${AI_MODEL}" '{
          model: $model,
          temperature: 0.2,
          messages: [
            {"role": "system", "content": "You write concise, factual, single-sentence repository descriptions. Plain text only."},
            {"role": "user",   "content": . }
          ]
        }' <<<"${PROMPT}")
        HTTP_CODE=$(curl -sS --max-time 30 \
          -o "${AI_OUT}" -w '%{http_code}' \
          -H "Authorization: Bearer ${MODELS_TOKEN}" \
          -H "Accept: application/vnd.github+json" \
          -H "Content-Type: application/json" \
          -H "X-GitHub-Api-Version: 2022-11-28" \
          -d "${PAYLOAD}" \
          'https://models.github.ai/inference/chat/completions' \
          2>"${AI_ERR}" || true)
        if [ "${HTTP_CODE}" = "200" ]; then
          AI_CONTENT=$(jq -r '.choices[0].message.content // empty' "${AI_OUT}" 2>/dev/null || true)
          if [ -n "${AI_CONTENT}" ]; then
            DESC_CANDIDATE="${AI_CONTENT}"
            DESC_SOURCE="ai"
            AI_USED="true"
            echo "::notice::repo-about-sync: description from GitHub Models (${AI_MODEL})"
          else
            echo "::warning::repo-about-sync: AI description returned 200 but empty; falling back to README seed"
          fi
        else
          echo "::warning::repo-about-sync: AI description request failed (HTTP ${HTTP_CODE}); falling back to README seed. Most likely missing 'models: read' permission."
          head -c 500 "${AI_OUT}" >&2 || true
          cat "${AI_ERR}" >&2 || true
          echo "" >&2
        fi
      fi

      if [ -z "${DESC_CANDIDATE}" ]; then
        if [ "${DESCRIPTION_MODE}" = "fallback" ] && [ -n "${DESCRIPTION_FALLBACK}" ]; then
          DESC_CANDIDATE="${DESCRIPTION_FALLBACK}"
          DESC_SOURCE="fallback"
        else
          DESC_CANDIDATE="${README_SEED}"
          DESC_SOURCE="readme"
        fi
      fi
      DESC_FINAL=$(printf '%s' "${DESC_CANDIDATE}" | python3 "${HELPER_PY}" clamp-description --max-len "${DESCRIPTION_MAX_LEN}")
    fi
  fi
fi

# ---------- Resolve topics ---------------------------------------------------

TOPICS_FINAL=""
TOPICS_SOURCE="skipped"

if [ -n "${TOPICS}" ]; then
  TOPICS_FINAL=$(python3 "${HELPER_PY}" sanitize-topics --max-count "${MAX_TOPICS}" --value "${TOPICS}")
  TOPICS_SOURCE="explicit"
elif [ "${GENERATE_TOPICS}" = "true" ]; then
  if [ ! -f "${README_PATH}" ]; then
    echo "::warning::repo-about-sync: cannot generate topics (README '${README_PATH}' missing); using fallback"
    TOPICS_FINAL=$(python3 "${HELPER_PY}" sanitize-topics --max-count "${MAX_TOPICS}" --value "${TOPICS_FALLBACK}")
    [ -n "${TOPICS_FINAL}" ] && TOPICS_SOURCE="fallback"
  else
    TOPIC_SEED=$(python3 "${HELPER_PY}" extract-readme "${README_PATH}" --max-len 3000 || true)
    AI_TOPICS_RAW=""
    if [ "${AI_ENABLED}" = "true" ] && [ -n "${TOPIC_SEED}" ]; then
      AI_OUT="${RUNNER_TEMP:-/tmp}/repo-about-sync.topics.json"
      AI_ERR="${RUNNER_TEMP:-/tmp}/repo-about-sync.topics.err"
      PROMPT=$(printf 'You are a GitHub repository topic curator. Read the README excerpt below and output up to %d GitHub topics that best describe this repository.\n\nGitHub topic rules — output MUST satisfy ALL of these:\n- lowercase letters, digits, hyphens only\n- each topic must be at most 50 characters\n- must start with a letter or digit\n- no leading or trailing hyphens\n\nOutput format: ONE LINE, space-separated topics. No commas, no quotes, no markdown, no preamble, no closing remarks, no explanations.\n\nExcerpt:\n\n%s' "${MAX_TOPICS}" "${TOPIC_SEED}")
      PAYLOAD=$(jq -Rs --arg model "${AI_MODEL}" '{
        model: $model,
        temperature: 0.2,
        messages: [
          {"role": "system", "content": "You output a single line of space-separated GitHub topic slugs. No other text."},
          {"role": "user",   "content": . }
        ]
      }' <<<"${PROMPT}")
      HTTP_CODE=$(curl -sS --max-time 30 \
        -o "${AI_OUT}" -w '%{http_code}' \
        -H "Authorization: Bearer ${MODELS_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -d "${PAYLOAD}" \
        'https://models.github.ai/inference/chat/completions' \
        2>"${AI_ERR}" || true)
      if [ "${HTTP_CODE}" = "200" ]; then
        AI_TOPICS_RAW=$(jq -r '.choices[0].message.content // empty' "${AI_OUT}" 2>/dev/null || true)
        if [ -n "${AI_TOPICS_RAW}" ]; then
          AI_USED="true"
        fi
      else
        echo "::warning::repo-about-sync: AI topics request failed (HTTP ${HTTP_CODE}); falling back. Most likely missing 'models: read' permission."
        head -c 500 "${AI_OUT}" >&2 || true
        cat "${AI_ERR}" >&2 || true
        echo "" >&2
      fi
    fi

    if [ -n "${AI_TOPICS_RAW}" ]; then
      TOPICS_FINAL=$(python3 "${HELPER_PY}" sanitize-topics --max-count "${MAX_TOPICS}" --value "${AI_TOPICS_RAW}")
      if [ -n "${TOPICS_FINAL}" ]; then
        TOPICS_SOURCE="ai"
        echo "::notice::repo-about-sync: topics from GitHub Models (${AI_MODEL})"
      fi
    fi

    if [ -z "${TOPICS_FINAL}" ] && [ -n "${TOPICS_FALLBACK}" ]; then
      TOPICS_FINAL=$(python3 "${HELPER_PY}" sanitize-topics --max-count "${MAX_TOPICS}" --value "${TOPICS_FALLBACK}")
      [ -n "${TOPICS_FINAL}" ] && TOPICS_SOURCE="fallback"
    fi
  fi
fi

# ---------- Resolve Marketplace categories ---------------------------------
#
# GitHub exposes current categories through GraphQL, but does not expose a
# supported category-edit mutation. We therefore compare and report drift;
# category changes remain a Marketplace listing UI operation. Never claim a
# write occurred for this unsupported API surface.

CATEGORY_PRIMARY_FINAL=""
CATEGORY_SECONDARY_FINAL=""
CATEGORY_PRIMARY_CONFIDENCE=""
CATEGORY_SECONDARY_CONFIDENCE=""
CATEGORY_SOURCE="skipped"
CURRENT_PRIMARY=""
CURRENT_SECONDARY=""
CATEGORY_STATUS="skipped"

if [ -n "${PRIMARY_CATEGORY}${SECONDARY_CATEGORY}" ]; then
  CATEGORY_SOURCE="explicit"
  CATEGORY_PRIMARY_FINAL="${PRIMARY_CATEGORY}"
  CATEGORY_SECONDARY_FINAL="${SECONDARY_CATEGORY}"
  [ "${CATEGORY_PRIMARY_FINAL}" = "auto" ] && CATEGORY_PRIMARY_FINAL=""
  [ "${CATEGORY_SECONDARY_FINAL}" = "auto" ] && CATEGORY_SECONDARY_FINAL=""

  CATEGORY_SEED=""
  if [ -f "${README_PATH}" ]; then
    CATEGORY_SEED=$(python3 "${HELPER_PY}" extract-readme "${README_PATH}" --max-len 5000 || true)
  fi
  if [ "${PRIMARY_CATEGORY}" = "auto" ] || [ "${SECONDARY_CATEGORY}" = "auto" ]; then
    if [ "${AI_ENABLED}" = "true" ] && [ -n "${CATEGORY_SEED}" ]; then
      CATEGORY_AI_OUT="${RUNNER_TEMP:-/tmp}/repo-metadata.categories.json"
      CATEGORY_AI_ERR="${RUNNER_TEMP:-/tmp}/repo-metadata.categories.err"
      PROMPT=$(printf 'You classify GitHub Marketplace Actions. Read the repository excerpt and choose the best primary and secondary categories from this exact allowlist: %s. Return ONLY valid JSON with string fields primary, secondary and numeric fields primary_confidence, secondary_confidence. Confidence must be between 0 and 1. Use null for a category when no good fit exists. Do not choose the same category twice. Excerpt:\n\n%s' "${CATEGORY_SLUGS}" "${CATEGORY_SEED}")
      PAYLOAD=$(jq -Rs --arg model "${AI_MODEL}" '{model: $model, temperature: 0.1, messages: [{role: "system", content: "Return only the requested JSON object. Never invent a category outside the allowlist."}, {role: "user", content: .}]}' <<<"${PROMPT}")
      HTTP_CODE=$(curl -sS -o "${CATEGORY_AI_OUT}" -w '%{http_code}' \
        -H "Authorization: Bearer ${GH_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -d "${PAYLOAD}" 'https://models.github.ai/inference/chat/completions' \
        2>"${CATEGORY_AI_ERR}" || true)
      if [ "${HTTP_CODE}" = "200" ]; then
        CATEGORY_AI_CONTENT=$(jq -r '.choices[0].message.content // empty' "${CATEGORY_AI_OUT}" 2>/dev/null || true)
        CATEGORY_JSON=$(printf '%s' "${CATEGORY_AI_CONTENT}" | sed -n '/^{/,/^}/p' | head -n 20 || true)
        if printf '%s' "${CATEGORY_JSON}" | jq -e . >/dev/null 2>&1; then
          if [ "${PRIMARY_CATEGORY}" = "auto" ]; then
            CATEGORY_PRIMARY_FINAL=$(printf '%s' "${CATEGORY_JSON}" | jq -r '.primary // empty')
            CATEGORY_PRIMARY_CONFIDENCE=$(printf '%s' "${CATEGORY_JSON}" | jq -r '.primary_confidence // empty')
          fi
          if [ "${SECONDARY_CATEGORY}" = "auto" ]; then
            CATEGORY_SECONDARY_FINAL=$(printf '%s' "${CATEGORY_JSON}" | jq -r '.secondary // empty')
            CATEGORY_SECONDARY_CONFIDENCE=$(printf '%s' "${CATEGORY_JSON}" | jq -r '.secondary_confidence // empty')
          fi
          validate_category "${CATEGORY_PRIMARY_FINAL}"
          validate_category "${CATEGORY_SECONDARY_FINAL}"
          CATEGORY_SOURCE="ai"
          AI_USED="true"
          echo "::notice::repo-metadata: Marketplace categories from GitHub Models (${AI_MODEL})"
        else
          echo "::warning::repo-metadata: AI category response was not valid JSON; reporting categories as unresolved"
        fi
      else
        echo "::warning::repo-metadata: AI category request failed (HTTP ${HTTP_CODE}); reporting categories as unresolved"
      fi
    else
      echo "::warning::repo-metadata: category auto mode requires ai_enabled=true and a README excerpt"
    fi
  fi

  CATEGORY_SLUG="${MARKETPLACE_SLUG:-${REPO_NAME}}"
  CATEGORY_QUERY=$(jq -n --arg slug "${CATEGORY_SLUG}" '{query: "query($slug: String!) { marketplaceListing(slug: $slug) { primaryCategory { slug } secondaryCategory { slug } } }", variables: {slug: $slug}}')
  CATEGORY_CURRENT_OUT="${RUNNER_TEMP:-/tmp}/repo-metadata.categories.current.json"
  CATEGORY_CURRENT_HTTP=$(curl -sS -o "${CATEGORY_CURRENT_OUT}" -w '%{http_code}' \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -d "${CATEGORY_QUERY}" https://api.github.com/graphql 2>/dev/null || true)
  if [ "${CATEGORY_CURRENT_HTTP}" = "200" ]; then
    CURRENT_PRIMARY=$(jq -r '.data.marketplaceListing.primaryCategory.slug // empty' "${CATEGORY_CURRENT_OUT}" 2>/dev/null || true)
    CURRENT_SECONDARY=$(jq -r '.data.marketplaceListing.secondaryCategory.slug // empty' "${CATEGORY_CURRENT_OUT}" 2>/dev/null || true)
    if [ -n "${CURRENT_PRIMARY}${CURRENT_SECONDARY}" ]; then
      if { [ -z "${CATEGORY_PRIMARY_FINAL}" ] || [ "${CURRENT_PRIMARY}" = "${CATEGORY_PRIMARY_FINAL}" ]; } \
        && { [ -z "${CATEGORY_SECONDARY_FINAL}" ] || [ "${CURRENT_SECONDARY}" = "${CATEGORY_SECONDARY_FINAL}" ]; }; then
        CATEGORY_STATUS="match"
      else
        CATEGORY_STATUS="mismatch"
        echo "::warning::repo-metadata: Marketplace categories differ from the requested values; GitHub requires updating these in the listing editor"
      fi
    else
      CATEGORY_STATUS="listing-not-found"
      echo "::notice::repo-metadata: no Marketplace listing found for slug '${CATEGORY_SLUG}'; category comparison skipped"
    fi
  else
    CATEGORY_STATUS="lookup-failed"
    echo "::warning::repo-metadata: Marketplace category lookup failed (HTTP ${CATEGORY_CURRENT_HTTP}); category comparison skipped"
  fi
fi

# ---------- Resolve homepage -------------------------------------------------

HOMEPAGE_FINAL=""
HOMEPAGE_OP="skip"     # "skip" | "set" | "clear"
case "${HOMEPAGE}" in
  '')          HOMEPAGE_OP="skip"; HOMEPAGE_FINAL="" ;;
  '__unset__') HOMEPAGE_OP="clear"; HOMEPAGE_FINAL="" ;;
  http://*|https://*) HOMEPAGE_OP="set"; HOMEPAGE_FINAL="${HOMEPAGE}" ;;
  *) die "input 'homepage' must be empty, '__unset__', or an http(s) URL (got: '${HOMEPAGE}')" ;;
esac

# ---------- Build PATCH payload + topics payload -----------------------------

PATCH_PAYLOAD=$(jq -n \
  --arg desc          "${DESC_FINAL}" \
  --arg desc_source   "${DESC_SOURCE}" \
  --arg homepage      "${HOMEPAGE_FINAL}" \
  --arg homepage_op   "${HOMEPAGE_OP}" \
  --argjson show_releases    "${SHOW_RELEASES}" \
  --argjson show_deployments "${SHOW_DEPLOYMENTS}" \
  --argjson show_packages    "${SHOW_PACKAGES}" \
  '
  ( if $desc_source == "existing" then {} else { description: $desc } end )
  + ( if $homepage_op == "set"   then { homepage: $homepage }
      elif $homepage_op == "clear" then { homepage: "" }
      else {} end )
  + { show_releases: $show_releases,
      show_deployments: $show_deployments,
      show_packages: $show_packages }
  ')

TOPICS_PAYLOAD=""
if [ "${TOPICS_SOURCE}" != "skipped" ]; then
  # ``names: []`` clears all topics; we never send that here — we only
  # PUT topics when we have a non-empty list.
  if [ -n "${TOPICS_FINAL}" ]; then
    TOPICS_PAYLOAD=$(jq -n --arg t "${TOPICS_FINAL}" \
      '{ names: ($t | split(" ") | map(select(length > 0))) }')
  fi
fi

# ---------- Apply ------------------------------------------------------------

APPLIED="false"
if [ "${DRY_RUN}" = "true" ]; then
  echo "::notice::repo-about-sync: dry_run=true; skipping all API writes"
else
  # ---- PATCH /repos/{owner}/{repo} -------------------------------------
  PATCH_OUT="${RUNNER_TEMP:-/tmp}/repo-about-sync.patch.json"
  PATCH_ERR="${RUNNER_TEMP:-/tmp}/repo-about-sync.patch.err"
  PATCH_HTTP=$(curl -sS --max-time 30 \
    -o "${PATCH_OUT}" -w '%{http_code}' \
    -X PATCH \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -d "${PATCH_PAYLOAD}" \
    "https://api.github.com/repos/${OWNER}/${REPO_NAME}" \
    2>"${PATCH_ERR}" || true)
  case "${PATCH_HTTP}" in
    2*)
      APPLIED="true"
      echo "::notice::repo-about-sync: repo PATCH ok (HTTP ${PATCH_HTTP})"
      echo "::notice::repo-about-sync: 'show_releases/show_deployments/show_packages' fields are best-effort — GitHub does not document them on the public REST API; the PATCH succeeds and the documented fields (description/homepage) are applied authoritatively."
      ;;
    *)
      msg=$(jq -r '.message // empty' "${PATCH_OUT}" 2>/dev/null || true)
      head -c 500 "${PATCH_OUT}" >&2 || true
      cat "${PATCH_ERR}" >&2 || true
      echo "" >&2
      die "repo PATCH failed (HTTP ${PATCH_HTTP}): ${msg:-unknown error}. Check that 'github_token' has 'Administration: write' on this repo."
      ;;
  esac

  # ---- PUT /repos/{owner}/{repo}/topics --------------------------------
  if [ -n "${TOPICS_PAYLOAD}" ]; then
    TOPICS_OUT="${RUNNER_TEMP:-/tmp}/repo-about-sync.topics.put.json"
    TOPICS_ERR="${RUNNER_TEMP:-/tmp}/repo-about-sync.topics.put.err"
    TOPICS_HTTP=$(curl -sS --max-time 30 \
      -o "${TOPICS_OUT}" -w '%{http_code}' \
      -X PUT \
      -H "Authorization: Bearer ${GH_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "Content-Type: application/json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -d "${TOPICS_PAYLOAD}" \
      "https://api.github.com/repos/${OWNER}/${REPO_NAME}/topics" \
      2>"${TOPICS_ERR}" || true)
    case "${TOPICS_HTTP}" in
      2*)
        APPLIED="true"
        echo "::notice::repo-about-sync: topics PUT ok (HTTP ${TOPICS_HTTP})"
        ;;
      *)
        msg=$(jq -r '.message // empty' "${TOPICS_OUT}" 2>/dev/null || true)
        head -c 500 "${TOPICS_OUT}" >&2 || true
        cat "${TOPICS_ERR}" >&2 || true
        echo "" >&2
        die "topics PUT failed (HTTP ${TOPICS_HTTP}): ${msg:-unknown error}. Check that 'github_token' has 'Administration: write' on this repo."
        ;;
    esac
  fi
fi

# ---------- Outputs ----------------------------------------------------------

{
  printf 'description=%s\n'        "${DESC_FINAL}"
  printf 'description_source=%s\n' "${DESC_SOURCE}"
  printf 'homepage=%s\n'           "${HOMEPAGE_FINAL}"
  printf 'topics=%s\n'             "${TOPICS_FINAL}"
  printf 'topics_source=%s\n'      "${TOPICS_SOURCE}"
  printf 'ai_used=%s\n'            "${AI_USED}"
  printf 'applied=%s\n'            "${APPLIED}"
  printf 'primary_category=%s\n' "${CATEGORY_PRIMARY_FINAL}"
  printf 'secondary_category=%s\n' "${CATEGORY_SECONDARY_FINAL}"
  printf 'primary_category_confidence=%s\n' "${CATEGORY_PRIMARY_CONFIDENCE}"
  printf 'secondary_category_confidence=%s\n' "${CATEGORY_SECONDARY_CONFIDENCE}"
} >> "${GITHUB_OUTPUT}"

# ---------- Summary ----------------------------------------------------------

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Repo About Box Sync"
    echo ""
    echo "| Field | Value | Source |"
    echo "|---|---|---|"
    if [ -n "${DESC_FINAL}" ]; then
      desc_md=$(printf '%s' "${DESC_FINAL}" | sed -e 's/|/\\|/g')
      echo "| Description (${#DESC_FINAL}/${DESCRIPTION_MAX_LEN}) | ${desc_md} | ${DESC_SOURCE} |"
    else
      echo "| Description | _(unchanged)_ | ${DESC_SOURCE} |"
    fi
    case "${HOMEPAGE_OP}" in
      set)   echo "| Homepage | ${HOMEPAGE_FINAL} | input |" ;;
      clear) echo "| Homepage | _(cleared)_ | input |" ;;
      *)     echo "| Homepage | _(unchanged)_ | skip |" ;;
    esac
    if [ -n "${TOPICS_FINAL}" ]; then
      topic_count=$(printf '%s' "${TOPICS_FINAL}" | tr ' ' '\n' | grep -cv '^$' || true)
      echo "| Topics (${topic_count}) | \`${TOPICS_FINAL}\` | ${TOPICS_SOURCE} |"
    else
      echo "| Topics | _(unchanged)_ | ${TOPICS_SOURCE} |"
    fi
    if [ -n "${CATEGORY_PRIMARY_FINAL}${CATEGORY_SECONDARY_FINAL}" ]; then
      echo "| Marketplace primary | \`${CATEGORY_PRIMARY_FINAL:-none}\` | ${CATEGORY_SOURCE} (confidence=${CATEGORY_PRIMARY_CONFIDENCE:-n/a}) |"
      echo "| Marketplace secondary | \`${CATEGORY_SECONDARY_FINAL:-none}\` | ${CATEGORY_SOURCE} (confidence=${CATEGORY_SECONDARY_CONFIDENCE:-n/a}) |"
      echo "| Marketplace current | primary=\`${CURRENT_PRIMARY:-unknown}\`, secondary=\`${CURRENT_SECONDARY:-unknown}\` | ${CATEGORY_STATUS} |"
      if [ "${CATEGORY_STATUS}" = "mismatch" ]; then
        echo "| Marketplace action | Update categories in the listing editor; GitHub exposes no supported category-write API | manual |"
      fi
    else
      echo "| Marketplace categories | _(unchanged)_ | ${CATEGORY_SOURCE} |"
    fi
    echo "| Show Releases    | \`${SHOW_RELEASES}\`    | input (best-effort) |"
    echo "| Show Deployments | \`${SHOW_DEPLOYMENTS}\` | input (best-effort) |"
    echo "| Show Packages    | \`${SHOW_PACKAGES}\`    | input (best-effort) |"
    echo "| AI used          | \`${AI_USED}\` | ${AI_MODEL} |"
    echo "| Applied          | \`${APPLIED}\` | dry_run=${DRY_RUN} |"
  } >> "${GITHUB_STEP_SUMMARY}"
fi
