"""
Merge and normalise celebrity candidate rows from Wikipedia and IMDb sources.
Filters out blocklisted names and validates schemas.
Python 3 standard library only.
"""

from __future__ import annotations

import unicodedata
from pathlib import Path
from typing import Any, Iterable

VALID_CATEGORIES = frozenset(
    {"film_tv", "music", "sports", "public_figure", "fictional", "other"}
)


def normalise(name: str) -> str:
    """
    Normalise a celebrity name for deduplication and matching:
    lowercased, accents and combining diacritics stripped, extra whitespace collapsed.
    """
    if not name:
        return ""
    # Decompose unicode into base characters + combining diacritical marks
    nfkd = unicodedata.normalize("NFKD", name)
    stripped = "".join(c for c in nfkd if not unicodedata.combining(c))
    # Collapse multiple consecutive whitespaces and lowercase
    return " ".join(stripped.split()).lower()


def load_blocklist(filepath_or_iterable: str | Path | Iterable[str]) -> set[str]:
    """
    Load a blocklist of names to never recommend.
    - If a string or Path is provided, it is treated as a required file path.
      Raises FileNotFoundError if the file does not exist.
    - If an iterable (set, list, etc.) is provided, in-memory names are normalised.
    """
    blocked: set[str] = set()

    if isinstance(filepath_or_iterable, (str, Path)):
        path = Path(filepath_or_iterable)
        if not path.is_file():
            raise FileNotFoundError(f"Blocklist file not found: {path}")

        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    blocked.add(normalise(line))
    else:
        for item in filepath_or_iterable:
            line = str(item).strip()
            if line and not line.startswith("#"):
                blocked.add(normalise(line))

    return {b for b in blocked if b}


def merge(
    wiki_rows: list[dict[str, Any]],
    imdb_rows: list[dict[str, Any]],
    blocklist: Any = None,
) -> list[dict[str, Any]]:
    """
    Merge candidates from Wikipedia and IMDb.
    - Matches on normalise(name).
    - If overlap: records both sources, takes the higher popularity score,
      prefers Wikipedia description and specific category.
    - Filters out names in blocklist.
    - Returns list of records sorted by popularity descending.
    """
    blocked: set[str] = set()
    if blocklist is not None:
        if isinstance(blocklist, (str, Path)):
            blocked = load_blocklist(blocklist)
        elif isinstance(blocklist, Iterable):
            blocked = {normalise(item) for item in blocklist if normalise(item)}

    merged_map: dict[str, dict[str, Any]] = {}

    def process_source_row(row: dict[str, Any], default_source: str) -> None:
        raw_name = (row.get("name") or "").strip()
        norm = normalise(raw_name)
        if not norm or norm in blocked:
            return

        desc = (row.get("description") or "").strip()
        cat = row.get("category") or "other"
        if cat not in VALID_CATEGORIES:
            cat = "other"

        pop = float(row.get("popularity", 0.0))
        pop = max(0.0, min(1.0, pop))

        sources = set(row.get("sources", [default_source]))
        if not sources:
            sources = {default_source}

        if norm in merged_map:
            existing = merged_map[norm]
            # Take higher popularity
            existing["popularity"] = round(max(existing["popularity"], pop), 4)
            # Combine sources
            existing["sources"] = sorted(list(set(existing["sources"]).union(sources)))
            # If current row is from Wikipedia or has a better description, prefer it
            if default_source == "wikipedia":
                if raw_name:
                    existing["name"] = raw_name
                if desc:
                    existing["description"] = desc
                if cat != "other":
                    existing["category"] = cat
            else:
                # Coming from IMDb into existing wiki row
                if not existing.get("description") and desc:
                    existing["description"] = desc
                if existing.get("category") == "other" and cat != "other":
                    existing["category"] = cat
        else:
            merged_map[norm] = {
                "name": raw_name,
                "name_norm": norm,
                "description": desc,
                "category": cat,
                "popularity": round(pop, 4),
                "sources": sorted(list(sources)),
            }

    # Process Wikipedia rows first
    for r in wiki_rows:
        process_source_row(r, "wikipedia")

    # Process IMDb rows next
    for r in imdb_rows:
        process_source_row(r, "imdb")

    # Remove any blocklisted items that might have matched
    results = [row for norm, row in merged_map.items() if norm not in blocked]

    # Sort by popularity descending, then name ascending
    results.sort(key=lambda x: (-x["popularity"], x["name_norm"]))
    return results
