# Copyright (c) Tile-AI Corporation.
# Licensed under the MIT License.
"""Filesystem helpers for publishing compiled artifacts."""

from __future__ import annotations

import os
import shutil
import tempfile
from contextlib import suppress


def is_file_missing(path: str | os.PathLike) -> bool:
    """Return whether ``path`` positively does not exist on the filesystem.

    A cached ``kernel_lib.so`` may be deleted by a concurrent ``clear_cache``
    between the metadata read and the shared-library load. ``os.path.exists``
    cannot be used for that classification: it also returns ``False`` for
    permission errors and broken symlinks because it swallows ``OSError``, so a
    failing load plus ``os.path.exists(path) is False`` does not prove the file
    was deleted.

    ``os.stat`` distinguishes the cases. ``FileNotFoundError`` means the entry
    is gone and the caller may safely fall back to a cache miss. Any other
    ``OSError`` (permission, not-a-directory, ...) means the path is present but
    unusable, so the original error must be preserved.
    """
    try:
        os.stat(path)
    except FileNotFoundError:
        return True
    except OSError:
        return False
    return False


def error_reports_missing_path(error: OSError, path: str | os.PathLike) -> bool:
    """Return whether ``error`` names ``path`` itself as the missing object.

    ``ctypes.CDLL(path)`` raises :class:`OSError` whose message is
    ``"<name>: cannot open shared object file: ..."`` where ``<name>`` is the
    object the dynamic loader failed to load. For a missing target this is
    ``path`` itself; for a missing dependency it is the dependency's name.
    ``OSError.errno`` is ``None`` for both, so the message is the only way to
    tell them apart. Only the target's basename is matched, so this stays a
    narrow classification rather than a general error-text parser.
    """
    return os.path.basename(os.fspath(path)) in str(error)


def atomic_copy(src: str | os.PathLike, dst: str | os.PathLike) -> None:
    """Publish a complete file without modifying an existing destination inode.

    Cached shared libraries may already be mapped into another process. Copying
    directly onto them truncates that process's backing file. A temporary file
    in the destination directory followed by replace preserves existing mappings
    and ensures readers see either the old or the new complete library.

    This does not make a multi-file cache entry transactional or synchronize
    publication with concurrent cache deletion.
    """
    dst = os.fspath(dst)
    fd, temporary_path = tempfile.mkstemp(prefix=f".{os.path.basename(dst)}.", suffix=".tmp", dir=os.path.dirname(dst) or ".")
    try:
        os.close(fd)
        shutil.copy(src, temporary_path)
        os.replace(temporary_path, dst)
    finally:
        with suppress(FileNotFoundError):
            os.unlink(temporary_path)
