"""Structural, shell-sanity, and dry-run contract tests for the
Repo About Box Sync composite action (action.yml + run.sh + lib.sh).
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
ACTION_YML = REPO_ROOT / "action.yml"
RUN_SH = REPO_ROOT / "run.sh"
LIB_SH = REPO_ROOT / "lib.sh"


def _manifest() -> dict:
    return yaml.safe_load(ACTION_YML.read_text(encoding="utf-8"))


def test_action_yaml_parses() -> None:
    assert isinstance(_manifest(), dict)


def test_action_has_required_top_level_keys() -> None:
    d = _manifest()
    for k in ("name", "description", "runs"):
        assert k in d, f"action.yml missing top-level key {k!r}"


def test_action_has_author_and_branding() -> None:
    d = _manifest()
    assert d.get("author"), "action.yml should declare an author for Marketplace"
    branding = d.get("branding") or {}
    assert branding.get("icon"), "action.yml branding.icon is required for Marketplace"
    assert branding.get("color"), "action.yml branding.color is required for Marketplace"


def test_marketplace_description_length() -> None:
    # GitHub Marketplace truncates the card-view description past 125 chars.
    desc = _manifest()["description"]
    assert len(desc) <= 125, f"description is {len(desc)} chars (>125)"


def test_action_runs_is_composite() -> None:
    assert _manifest()["runs"].get("using") == "composite"


def test_every_input_has_description() -> None:
    inputs = _manifest().get("inputs") or {}
    assert inputs, "expected at least one input"
    for name, spec in inputs.items():
        assert isinstance(spec, dict), f"input {name!r} is not a mapping"
        desc = spec.get("description")
        assert desc and str(desc).strip(), f"input {name!r} has no description"


def test_every_output_has_description() -> None:
    outputs = _manifest().get("outputs") or {}
    assert outputs, "expected at least one output"
    for name, spec in outputs.items():
        assert isinstance(spec, dict), f"output {name!r} is not a mapping"
        desc = spec.get("description")
        assert desc and str(desc).strip(), f"output {name!r} has no description"


def test_ai_disabled_by_default() -> None:
    # Least-privilege default: AI calls require an explicit opt-in.
    assert _manifest()["inputs"]["ai_enabled"]["default"] == "false"


def test_bash_step_parses_via_bash_n() -> None:
    step = _manifest()["runs"]["steps"][0]
    assert step["shell"] == "bash"
    body = step["run"]
    with tempfile.NamedTemporaryFile(mode="w", suffix=".sh", delete=False) as tmp:
        tmp.write("#!/usr/bin/env bash\nset -euo pipefail\n")
        tmp.write(body)
        tmp_path = tmp.name
    try:
        result = subprocess.run(["bash", "-n", tmp_path], capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
    finally:
        Path(tmp_path).unlink(missing_ok=True)


@pytest.mark.parametrize("sh_path", [RUN_SH, LIB_SH], ids=["run.sh", "lib.sh"])
def test_external_scripts_parse_via_bash_n(sh_path: Path) -> None:
    result = subprocess.run(["bash", "-n", str(sh_path)], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr


@pytest.mark.skipif(shutil.which("shellcheck") is None, reason="shellcheck not installed")
@pytest.mark.parametrize("sh_path", [RUN_SH, LIB_SH], ids=["run.sh", "lib.sh"])
def test_external_scripts_clean_under_shellcheck(sh_path: Path) -> None:
    result = subprocess.run(
        ["shellcheck", "-x", "-S", "error", "--shell=bash", str(sh_path)],
        capture_output=True, text=True,
    )
    assert result.returncode == 0, result.stdout


# ---------------------------------------------------------------------------
# Dry-run contract (no network calls; exercises run.sh end to end)
# ---------------------------------------------------------------------------


class TestDryRunContract:
    def run_action(self, temp_dir: Path, **overrides: str) -> subprocess.CompletedProcess[str]:
        output_path = temp_dir / "output"
        summary_path = temp_dir / "summary"
        env = os.environ | {
            "GITHUB_ACTION_PATH": str(REPO_ROOT),
            "GITHUB_OUTPUT": str(output_path),
            "GITHUB_STEP_SUMMARY": str(summary_path),
            "RUNNER_TEMP": str(temp_dir),
            "REPO": "blackoutsecure/example",
            "GH_TOKEN": "dry-run-token",
            "README_PATH": "README.md",
            "DESCRIPTION": "A deterministic repository description.",
            "DESCRIPTION_MAX_LEN": "350",
            "HOMEPAGE": "https://example.com/project",
            "TOPICS": "GitHub_Actions security github_actions",
            "GENERATE_TOPICS": "false",
            "TOPICS_FALLBACK": "",
            "MAX_TOPICS": "20",
            "AI_ENABLED": "false",
            "AI_MODEL": "openai/gpt-4o-mini",
            "SHOW_RELEASES": "true",
            "SHOW_DEPLOYMENTS": "false",
            "SHOW_PACKAGES": "false",
            "DRY_RUN": "true",
            **overrides,
        }
        return subprocess.run(
            ["bash", str(RUN_SH)],
            cwd=REPO_ROOT,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_dry_run_resolves_outputs_without_writes(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp_dir:
            temp_dir = Path(raw_temp_dir)
            result = self.run_action(temp_dir)
            assert result.returncode == 0, result.stderr
            outputs = dict(
                line.split("=", 1)
                for line in (temp_dir / "output").read_text().splitlines()
            )
            assert outputs["description_source"] == "explicit"
            assert outputs["topics"] == "github-actions security"
            assert outputs["topics_source"] == "explicit"
            assert outputs["ai_used"] == "false"
            assert outputs["applied"] == "false"
            assert "dry_run=true" in (temp_dir / "summary").read_text()

    def test_repo_must_have_exactly_two_segments(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp_dir:
            result = self.run_action(
                Path(raw_temp_dir), REPO="owner/intermediate/repo"
            )
            assert result.returncode != 0
            assert "exactly 'owner/repo'" in result.stderr

    def test_invalid_homepage_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp_dir:
            result = self.run_action(Path(raw_temp_dir), HOMEPAGE="not-a-url")
            assert result.returncode != 0
            assert "must be empty, '__unset__', or an http(s) URL" in result.stderr

    def test_description_max_len_out_of_range_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp_dir:
            result = self.run_action(Path(raw_temp_dir), DESCRIPTION_MAX_LEN="500")
            assert result.returncode != 0
            assert "description_max_length" in result.stderr

    def test_invalid_bool_input_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp_dir:
            result = self.run_action(Path(raw_temp_dir), DRY_RUN="yes")
            assert result.returncode != 0
            assert "must be 'true' or 'false'" in result.stderr
