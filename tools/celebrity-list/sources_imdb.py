"""
IMDb source pipeline for celebrity recommendations.
Streams name.basics.tsv.gz, title.basics.tsv.gz, and title.ratings.tsv.gz datasets.
Scores each person by the summed vote counts of their known-for titles,
drops people whose known-for titles are all flagged adult, and returns top N candidates.
Python 3 standard library only.
"""

from __future__ import annotations

import csv
import gzip
import heapq
import itertools
from pathlib import Path
from typing import Any, Iterator, TextIO

from merge import normalise


def open_tsv(filepath: str | Path) -> TextIO:
    """Open a TSV file, automatically handling gzip decompression if ending in .gz."""
    path_str = str(filepath)
    if path_str.endswith(".gz"):
        return gzip.open(filepath, "rt", encoding="utf-8", errors="replace")
    return open(filepath, "rt", encoding="utf-8", errors="replace")


def load_title_ratings(ratings_path: str | Path) -> dict[str, int]:
    """
    Stream title.ratings.tsv.gz and return a mapping of tconst to numVotes.
    Header: tconst, averageRating, numVotes
    """
    ratings: dict[str, int] = {}
    with open_tsv(ratings_path) as f:
        reader = csv.reader(f, delimiter="\t")
        header = next(reader, None)
        if not header:
            return ratings

        # Find column indices
        try:
            tconst_idx = header.index("tconst")
            votes_idx = header.index("numVotes")
        except ValueError:
            tconst_idx, votes_idx = 0, 2

        for row in reader:
            if len(row) <= max(tconst_idx, votes_idx):
                continue
            try:
                tconst = row[tconst_idx]
                votes = int(row[votes_idx])
                ratings[tconst] = votes
            except (ValueError, IndexError):
                continue

    return ratings


def load_adult_titles(basics_path: str | Path) -> set[str]:
    """
    Stream title.basics.tsv.gz and collect tconst of titles flagged as adult (isAdult == '1').
    Header: tconst, titleType, primaryTitle, originalTitle, isAdult, ...
    """
    adult_titles: set[str] = set()
    with open_tsv(basics_path) as f:
        reader = csv.reader(f, delimiter="\t")
        header = next(reader, None)
        if not header:
            return adult_titles

        try:
            tconst_idx = header.index("tconst")
            adult_idx = header.index("isAdult")
        except ValueError:
            tconst_idx, adult_idx = 0, 4

        for row in reader:
            if len(row) <= max(tconst_idx, adult_idx):
                continue
            if row[adult_idx] == "1":
                adult_titles.add(row[tconst_idx])

    return adult_titles


def format_profession(profession_str: str) -> str:
    """Format comma-separated professions into a readable short description."""
    if not profession_str or profession_str == "\\N":
        return "Actor"

    parts = [p.strip().replace("_", " ").title() for p in profession_str.split(",") if p.strip()]
    if not parts:
        return "Actor"
    return ", ".join(parts[:2])


def stream_imdb_celebrities(
    names_path: str | Path,
    titles_path: str | Path,
    ratings_path: str | Path,
    top_n: int = 3000,
) -> list[dict[str, Any]]:
    """
    Stream IMDb dataset files, score individuals by summed vote counts of their
    known-for titles, filter adult-only figures, and return the top N.
    """
    # 1. Load ratings into memory
    ratings = load_title_ratings(ratings_path)
    if not ratings:
        return []

    # 2. Load set of adult titles
    adult_titles = load_adult_titles(titles_path)

    # 3. Stream name.basics.tsv.gz maintaining a min-heap of size top_n
    heap: list[tuple[int, int, dict[str, Any]]] = []
    counter = itertools.count()

    with open_tsv(names_path) as f:
        reader = csv.reader(f, delimiter="\t")
        header = next(reader, None)
        if not header:
            return []

        try:
            name_idx = header.index("primaryName")
            prof_idx = header.index("primaryProfession")
            known_idx = header.index("knownForTitles")
        except ValueError:
            name_idx, prof_idx, known_idx = 1, 4, 5

        for row in reader:
            if len(row) <= max(name_idx, prof_idx, known_idx):
                continue

            name = row[name_idx].strip()
            if not name or name == "\\N":
                continue

            known_str = row[known_idx].strip()
            if not known_str or known_str == "\\N":
                continue

            known_for = [t.strip() for t in known_str.split(",") if t.strip() and t != "\\N"]
            if not known_for:
                continue

            # Check if ALL known-for titles are adult
            if all(t in adult_titles for t in known_for):
                continue

            # Sum votes across known-for titles
            score = sum(ratings.get(t, 0) for t in known_for)
            if score <= 0:
                continue

            prof = format_profession(row[prof_idx])
            norm = normalise(name)
            if not norm:
                continue

            candidate = {
                "name": name,
                "name_norm": norm,
                "description": prof,
                "category": "film_tv",
                "score": score,
                "sources": ["imdb"],
            }

            count = next(counter)
            if len(heap) < top_n:
                heapq.heappush(heap, (score, count, candidate))
            elif score > heap[0][0]:
                heapq.heapreplace(heap, (score, count, candidate))

    if not heap:
        return []

    # Extract all candidates and sort descending by score
    sorted_candidates = [
        item[2] for item in sorted(heap, key=lambda x: x[0], reverse=True)
    ]

    # Assign rank-normalised popularity
    total = len(sorted_candidates)
    results = []
    for rank, cand in enumerate(sorted_candidates, start=1):
        pop = round(max(0.0, min(1.0, (total - rank + 1) / total)), 4)
        results.append(
            {
                "name": cand["name"],
                "name_norm": cand["name_norm"],
                "description": cand["description"],
                "category": cand["category"],
                "popularity": pop,
                "sources": ["imdb"],
            }
        )

    return results
