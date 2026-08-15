"""Shared pytest fixtures for the Repo About Box Sync test suite.

Loads ``helper.py`` (which lives at the repository root, alongside
``action.yml``, so consumers of the action get it without a package
install) under the stable import name ``repo_about_sync_helper``.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from types import ModuleType

REPO_ROOT = Path(__file__).resolve().parent.parent


def _load_helper() -> ModuleType:
    path = REPO_ROOT / "helper.py"
    spec = importlib.util.spec_from_file_location("repo_about_sync_helper", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load module spec from {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


sys.modules.setdefault("repo_about_sync_helper", _load_helper())
