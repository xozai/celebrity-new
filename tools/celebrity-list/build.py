"""
Build the curated celebrity recommendation list.
Combines Wikipedia pageviews / Wikidata entities and IMDb datasets.
Applies blocklist, normalises names, merges sources, and writes celebrities.csv.
Python 3 standard library only.
"""

from __future__ import annotations

import argparse
import csv
import os
import sys
import urllib.request
from pathlib import Path
from typing import Any

from merge import load_blocklist, merge, normalise
from sources_imdb import stream_imdb_celebrities
from sources_wikipedia import fetch_wikipedia_celebrities, get_default_months

IMDB_FILES = {
    "name.basics.tsv.gz": "https://datasets.imdbws.com/name.basics.tsv.gz",
    "title.basics.tsv.gz": "https://datasets.imdbws.com/title.basics.tsv.gz",
    "title.ratings.tsv.gz": "https://datasets.imdbws.com/title.ratings.tsv.gz",
}

DEFAULT_CSV_PATH = Path(__file__).resolve().parent / "celebrities.csv"
DEFAULT_BLOCKLIST_PATH = Path(__file__).resolve().parent / "blocklist.txt"
DEFAULT_DATA_DIR = Path(__file__).resolve().parent / "data"

CSV_COLUMNS = ["name", "name_norm", "description", "category", "popularity", "sources"]


def format_sources_array(sources: list[str]) -> str:
    """Format list of sources as a Postgres array literal, e.g. {imdb,wikipedia}."""
    clean = [s.strip().replace("{", "").replace("}", "").replace('"', "") for s in sources if s.strip()]
    return f"{{{','.join(clean)}}}"


def download_imdb_files(data_dir: Path, refresh: bool = False) -> dict[str, Path]:
    """
    Download IMDb dataset files to data_dir if not present or refresh=True.
    Downloads to a temporary file and atomically renames on success (Finding 14).
    """
    data_dir.mkdir(parents=True, exist_ok=True)
    paths = {}
    for filename, url in IMDB_FILES.items():
        dest = data_dir / filename
        paths[filename] = dest
        if dest.exists() and not refresh:
            continue

        print(f"Downloading {filename} from {url}...")
        tmp_dest = dest.with_suffix(dest.suffix + ".tmp")
        try:
            urllib.request.urlretrieve(url, tmp_dest)
            tmp_dest.replace(dest)
            print(f"Downloaded and verified {filename}.")
        except Exception:
            if tmp_dest.exists():
                tmp_dest.unlink()
            raise

    return paths


def build_celebrities_csv(
    wiki_candidates: list[dict[str, Any]],
    imdb_candidates: list[dict[str, Any]],
    blocklist: Any,
    output_path: str | Path,
) -> list[dict[str, Any]]:
    """Merge candidates, filter blocklist, and write output CSV."""
    merged = merge(wiki_candidates, imdb_candidates, blocklist=blocklist)

    out_file = Path(output_path)
    out_file.parent.mkdir(parents=True, exist_ok=True)

    with open(out_file, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_COLUMNS)
        writer.writeheader()
        for row in merged:
            writer.writerow(
                {
                    "name": row["name"],
                    "name_norm": row["name_norm"],
                    "description": row.get("description", ""),
                    "category": row.get("category", "other"),
                    "popularity": f"{row.get('popularity', 0.0):.4f}",
                    "sources": format_sources_array(row.get("sources", [])),
                }
            )

    return merged


def main() -> None:
    parser = argparse.ArgumentParser(description="Build celebrity recommendation list.")
    parser.add_argument(
        "--output",
        "-o",
        type=Path,
        default=DEFAULT_CSV_PATH,
        help="Path to output celebrities.csv",
    )
    parser.add_argument(
        "--data-dir",
        type=Path,
        default=DEFAULT_DATA_DIR,
        help="Directory storing downloaded IMDb datasets",
    )
    parser.add_argument(
        "--blocklist",
        type=Path,
        default=DEFAULT_BLOCKLIST_PATH,
        help="Path to blocklist.txt",
    )
    parser.add_argument(
        "--wiki-months",
        type=int,
        default=12,
        help="Number of months of Wikipedia pageviews to inspect",
    )
    parser.add_argument(
        "--imdb-top",
        type=int,
        default=3000,
        help="Number of top IMDb individuals to keep",
    )
    parser.add_argument(
        "--refresh",
        action="store_true",
        help="Force re-download of IMDb dataset files even if cached",
    )
    args = parser.parse_args()

    # 1. Blocklist
    print(f"Loading blocklist from {args.blocklist}...")
    blocklist = load_blocklist(args.blocklist)
    print(f"Loaded {len(blocklist)} blocklisted entries.")

    # 2. Wikipedia candidates (Finding 14: pass requested months)
    print(f"Fetching Wikipedia candidates for past {args.wiki_months} months...")
    months = get_default_months(args.wiki_months)
    wiki_candidates = fetch_wikipedia_celebrities(months=months)
    print(f"Fetched {len(wiki_candidates)} Wikipedia candidates.")

    # 3. IMDb candidates (Finding 14: atomic download with optional refresh)
    print(f"Ensuring IMDb datasets in {args.data_dir}...")
    imdb_paths = download_imdb_files(args.data_dir, refresh=args.refresh)
    print("Streaming IMDb candidates...")
    imdb_candidates = stream_imdb_celebrities(
        names_path=imdb_paths["name.basics.tsv.gz"],
        titles_path=imdb_paths["title.basics.tsv.gz"],
        ratings_path=imdb_paths["title.ratings.tsv.gz"],
        top_n=args.imdb_top,
    )
    print(f"Processed {len(imdb_candidates)} IMDb candidates.")

    # 4. Merge & write
    print(f"Merging and writing to {args.output}...")
    merged = build_celebrities_csv(
        wiki_candidates=wiki_candidates,
        imdb_candidates=imdb_candidates,
        blocklist=blocklist,
        output_path=args.output,
    )
    print(f"Successfully generated {len(merged)} celebrities in {args.output}.")


if __name__ == "__main__":
    main()
