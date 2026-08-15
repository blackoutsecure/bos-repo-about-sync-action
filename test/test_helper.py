"""Unit tests for the repo-about-sync composite helper module."""

from __future__ import annotations

import pytest
import repo_about_sync_helper as rm  # type: ignore[import-not-found]

# ---------------------------------------------------------------------------
# extract_readme_summary
# ---------------------------------------------------------------------------


class TestExtractReadmeSummary:
    def test_empty_returns_empty(self) -> None:
        assert rm.extract_readme_summary("") == ""
        assert rm.extract_readme_summary("\n\n\n") == ""

    def test_skips_h1_and_returns_first_prose(self) -> None:
        text = "# My Repo\n\nA tiny tool that does one thing well.\n"
        assert (
            rm.extract_readme_summary(text)
            == "A tiny tool that does one thing well."
        )

    def test_prefers_blockquote_tagline_over_prose(self) -> None:
        text = (
            "# My Repo\n"
            "\n"
            "> The friendly README tagline.\n"
            "\n"
            "Some longer paragraph that follows the tagline.\n"
        )
        assert (
            rm.extract_readme_summary(text)
            == "The friendly README tagline."
        )

    def test_multi_line_blockquote_joined(self) -> None:
        text = (
            "# Repo\n"
            "\n"
            "> Line one of the tagline\n"
            "> continued on line two.\n"
            "\n"
            "Prose paragraph.\n"
        )
        assert (
            rm.extract_readme_summary(text)
            == "Line one of the tagline continued on line two."
        )

    def test_skips_badge_paragraph(self) -> None:
        text = (
            "# My Repo\n"
            "\n"
            "[![CI](https://img.shields.io/badge/ci-passing-green)](https://example.com)\n"
            "[![License](https://img.shields.io/badge/license-mit-blue)](LICENSE)\n"
            "\n"
            "Real prose summary that should win.\n"
        )
        assert (
            rm.extract_readme_summary(text)
            == "Real prose summary that should win."
        )

    def test_skips_image_paragraph(self) -> None:
        text = (
            "# Repo\n"
            "\n"
            "![logo](logo.png)\n"
            "\n"
            "The actual description paragraph.\n"
        )
        assert (
            rm.extract_readme_summary(text)
            == "The actual description paragraph."
        )

    def test_skips_html_block_paragraph(self) -> None:
        text = (
            "# Repo\n"
            "\n"
            "<p align=\"center\">\n"
            "  <img src=\"logo.png\" />\n"
            "</p>\n"
            "\n"
            "Prose comes after the HTML banner.\n"
        )
        assert (
            rm.extract_readme_summary(text)
            == "Prose comes after the HTML banner."
        )

    def test_skips_fenced_code_block(self) -> None:
        text = (
            "# Repo\n"
            "\n"
            "```bash\n"
            "echo hi\n"
            "```\n"
            "\n"
            "After the code block, the prose.\n"
        )
        assert (
            rm.extract_readme_summary(text)
            == "After the code block, the prose."
        )

    def test_skips_list_paragraph(self) -> None:
        text = (
            "# Repo\n"
            "\n"
            "- one\n"
            "- two\n"
            "\n"
            "After the list, prose.\n"
        )
        assert (
            rm.extract_readme_summary(text)
            == "After the list, prose."
        )

    def test_skips_table_paragraph(self) -> None:
        text = (
            "# Repo\n"
            "\n"
            "| col | col |\n"
            "|---|---|\n"
            "| a | b |\n"
            "\n"
            "Prose after table.\n"
        )
        assert rm.extract_readme_summary(text) == "Prose after table."

    def test_clips_at_word_boundary_no_ellipsis(self) -> None:
        long_para = "word " * 200
        text = f"# Repo\n\n{long_para.strip()}\n"
        out = rm.extract_readme_summary(text, max_len=120)
        assert len(out) <= 120
        assert not out.endswith("…")
        assert not out.endswith("...")
        assert out.endswith("word")

    def test_normalizes_internal_whitespace(self) -> None:
        text = "# R\n\nOne line\nsplit  across two\n"
        assert rm.extract_readme_summary(text) == "One line split across two"


# ---------------------------------------------------------------------------
# clamp_description
# ---------------------------------------------------------------------------


class TestClampDescription:
    def test_returns_short_text_unchanged(self) -> None:
        assert rm.clamp_description("hello world", max_len=350) == "hello world"

    def test_normalizes_whitespace(self) -> None:
        assert (
            rm.clamp_description("hello\n  world\t\tfriend", max_len=50)
            == "hello world friend"
        )

    def test_clamps_with_ellipsis_at_word_boundary(self) -> None:
        text = "one two three four five six seven eight nine ten"
        out = rm.clamp_description(text, max_len=20)
        assert len(out) <= 20
        assert out.endswith("…")
        body = out.rstrip("…")
        assert not body.endswith(" ")

    def test_strips_trailing_punctuation_before_ellipsis(self) -> None:
        text = "one two three, four five six seven"
        out = rm.clamp_description(text, max_len=15)
        assert out.endswith("…")
        assert "," not in out[-2:]

    def test_zero_max_len_raises(self) -> None:
        with pytest.raises(ValueError):
            rm.clamp_description("anything", max_len=0)

    def test_total_length_includes_ellipsis(self) -> None:
        text = "a" * 500
        out = rm.clamp_description(text, max_len=50)
        assert len(out) <= 50

    def test_exact_fit_no_ellipsis(self) -> None:
        text = "abcdefghij"
        assert rm.clamp_description(text, max_len=10) == "abcdefghij"


# ---------------------------------------------------------------------------
# sanitize_topics
# ---------------------------------------------------------------------------


class TestSanitizeTopics:
    def test_empty_returns_empty_list(self) -> None:
        assert rm.sanitize_topics("") == []
        assert rm.sanitize_topics("   \n  ,, ") == []

    def test_space_separated(self) -> None:
        assert rm.sanitize_topics("github actions ci") == [
            "github", "actions", "ci",
        ]

    def test_comma_separated(self) -> None:
        assert rm.sanitize_topics("github, actions, ci") == [
            "github", "actions", "ci",
        ]

    def test_mixed_separators(self) -> None:
        assert rm.sanitize_topics("one, two\nthree four,,five") == [
            "one", "two", "three", "four", "five",
        ]

    def test_lowercases(self) -> None:
        assert rm.sanitize_topics("GitHub Actions CI") == [
            "github", "actions", "ci",
        ]

    def test_replaces_invalid_chars_with_hyphen(self) -> None:
        assert rm.sanitize_topics("hello_world foo.bar baz/qux") == [
            "hello-world", "foo-bar", "baz-qux",
        ]

    def test_collapses_runs_of_hyphens(self) -> None:
        assert rm.sanitize_topics("hello___world") == ["hello-world"]

    def test_strips_leading_and_trailing_hyphens(self) -> None:
        assert rm.sanitize_topics("__github__ _ci_") == ["github", "ci"]

    def test_dedupes_preserving_order(self) -> None:
        assert rm.sanitize_topics("ci docker ci k8s docker") == [
            "ci", "docker", "k8s",
        ]

    def test_drops_topics_that_become_empty(self) -> None:
        assert rm.sanitize_topics("___ ___ foo") == ["foo"]

    def test_clips_topic_to_50_chars(self) -> None:
        long_word = "a" * 80
        out = rm.sanitize_topics(long_word)
        assert len(out) == 1
        assert len(out[0]) <= 50

    def test_caps_at_max_count(self) -> None:
        text = " ".join(f"t{i}" for i in range(50))
        out = rm.sanitize_topics(text, max_count=5)
        assert len(out) == 5
        assert out == ["t0", "t1", "t2", "t3", "t4"]

    def test_caps_at_github_ceiling_even_when_max_count_higher(self) -> None:
        text = " ".join(f"t{i}" for i in range(50))
        out = rm.sanitize_topics(text, max_count=100)
        assert len(out) == 20

    def test_negative_max_count_clamps_to_zero(self) -> None:
        assert rm.sanitize_topics("a b c", max_count=-5) == []

    def test_accepts_unicode_by_dropping_non_ascii(self) -> None:
        assert rm.sanitize_topics("café naïve") == ["caf", "na-ve"]
