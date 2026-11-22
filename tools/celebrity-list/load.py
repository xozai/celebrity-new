"""
Load celebrity recommendations CSV into PostgreSQL / Supabase database.
Upserts records by name_norm, and deletes rows no longer present in the list.
Uses PostgreSQL COPY FROM STDIN with separate CSV data stream (no SQL value interpolation).
Passes database credentials via PG* environment variables without exposing URLs in argv.
Python 3 standard library only.
"""

from __future__ import annotations

import argparse
import csv
import io
import os
import re
import shutil
import subprocess
import sys
import urllib.parse
from pathlib import Path
from typing import Any, Callable

DEFAULT_CSV_PATH = Path(__file__).resolve().parent / "celebrities.csv"
MIN_ROWS_DEFAULT = 2000


def parse_sources_column(val: str) -> list[str]:
    """Parse Postgres text array string, e.g. '{imdb,wikipedia}' or 'imdb,wikipedia'."""
    val = val.strip()
    if val.startswith("{") and val.endswith("}"):
        val = val[1:-1]
    items = [s.strip().replace('"', "") for s in val.split(",") if s.strip()]
    return items


def parse_celebrities_csv(csv_path: str | Path) -> list[dict[str, Any]]:
    """Parse celebrities.csv into validated dictionaries."""
    rows: list[dict[str, Any]] = []
    with open(csv_path, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for r in reader:
            name = (r.get("name") or "").strip()
            name_norm = (r.get("name_norm") or "").strip()
            if not name or not name_norm:
                continue
            desc = (r.get("description") or "").strip()
            category = (r.get("category") or "other").strip()
            pop = float(r.get("popularity", 0.0))
            sources = parse_sources_column(r.get("sources", ""))
            rows.append(
                {
                    "name": name,
                    "name_norm": name_norm,
                    "description": desc,
                    "category": category,
                    "popularity": pop,
                    "sources": sources,
                }
            )
    return rows


def generate_load_script(rows: list[dict[str, Any]]) -> str:
    """
    Generate static SQL script and separate CSV data stream via COPY FROM STDIN.
    Eliminates SQL injection and value interpolation risks (Finding 1).
    """
    header = (
        "-- Celebrity recommendation list update via COPY\n"
        "BEGIN;\n\n"
        "CREATE TEMP TABLE staging_celebrities (\n"
        "  name text NOT NULL,\n"
        "  name_norm text NOT NULL,\n"
        "  description text NOT NULL,\n"
        "  category text NOT NULL,\n"
        "  popularity double precision NOT NULL,\n"
        "  sources text[] NOT NULL\n"
        ") ON COMMIT DROP;\n\n"
        "COPY staging_celebrities (name, name_norm, description, category, popularity, sources) "
        "FROM STDIN WITH (FORMAT csv, HEADER false, FORCE_NOT_NULL (description));\n"
    )

    csv_buf = io.StringIO()
    writer = csv.writer(csv_buf, lineterminator="\n")
    for r in rows:
        src_array = "{" + ",".join(r.get("sources", [])) + "}"
        writer.writerow(
            [
                r["name"],
                r["name_norm"],
                r.get("description", ""),
                r.get("category", "other"),
                f"{float(r.get('popularity', 0.0)):.4f}",
                src_array,
            ]
        )

    copy_data = csv_buf.getvalue()

    footer = (
        "\\.\n\n"
        "-- Upsert from staging into target table\n"
        "INSERT INTO public.celebrities (name, name_norm, description, category, popularity, sources)\n"
        "SELECT name, name_norm, description, category, popularity, sources\n"
        "FROM staging_celebrities\n"
        "ON CONFLICT (name_norm) DO UPDATE SET\n"
        "  name = EXCLUDED.name,\n"
        "  description = EXCLUDED.description,\n"
        "  category = EXCLUDED.category,\n"
        "  popularity = EXCLUDED.popularity,\n"
        "  sources = EXCLUDED.sources;\n\n"
        "-- Delete absent rows\n"
        "DELETE FROM public.celebrities\n"
        "WHERE name_norm NOT IN (SELECT name_norm FROM staging_celebrities);\n\n"
        "COMMIT;\n"
    )

    return header + copy_data + footer


def parse_database_url(url: str) -> dict[str, str]:
    """
    Parse PostgreSQL URL into libpq environment variables (Finding 2).
    Never exposes passwords or connection strings in command line arguments.
    """
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ("postgres", "postgresql"):
        raise ValueError(f"Invalid database URL scheme: {parsed.scheme}")

    pg_env: dict[str, str] = {}
    if parsed.hostname:
        pg_env["PGHOST"] = urllib.parse.unquote(parsed.hostname)
    if parsed.port:
        pg_env["PGPORT"] = str(parsed.port)
    if parsed.username:
        pg_env["PGUSER"] = urllib.parse.unquote(parsed.username)
    if parsed.password:
        pg_env["PGPASSWORD"] = urllib.parse.unquote(parsed.password)
    db_name = parsed.path.lstrip("/")
    if db_name:
        pg_env["PGDATABASE"] = urllib.parse.unquote(db_name)

    query_params = urllib.parse.parse_qs(parsed.query)
    if "sslmode" in query_params:
        pg_env["PGSSLMODE"] = query_params["sslmode"][0]

    return pg_env


def sanitize_error_message(msg: str, sensitive_strings: list[str]) -> str:
    """Sanitize passwords and URLs from error text (Finding 2)."""
    sanitized = msg
    for s in sensitive_strings:
        if s:
            sanitized = sanitized.replace(s, "[REDACTED]")

    # Redact any remaining postgres:// URI patterns
    sanitized = re.sub(
        r"postgres(?:ql)?://([^:]+):([^@]+)@",
        r"postgresql://\1:[REDACTED]@",
        sanitized,
    )
    return sanitized


def execute_load(
    database_url: str | None = None,
    rows: list[dict[str, Any]] | None = None,
    csv_path: str | Path | None = None,
    min_rows: int = MIN_ROWS_DEFAULT,
    executor: Callable[[str, dict[str, str]], None] | None = None,
) -> None:
    """Execute SQL/COPY loading against database."""
    if rows is None:
        if csv_path is None:
            csv_path = DEFAULT_CSV_PATH
        rows = parse_celebrities_csv(csv_path)

    if len(rows) < min_rows:
        raise ValueError(
            f"Row count {len(rows)} is below safety threshold of {min_rows}. "
            "Aborting database load."
        )

    if not database_url and executor is None:
        raise ValueError("DATABASE_URL must be provided to load into database.")

    pg_env: dict[str, str] = {}
    if database_url:
        pg_env = parse_database_url(database_url)

    script = generate_load_script(rows)

    if executor is not None:
        executor(script, pg_env)
        return

    psql_bin = shutil.which("psql")
    if not psql_bin:
        raise RuntimeError(
            "psql command line tool not found on PATH. "
            "Please install postgresql client tools to execute against DATABASE_URL."
        )

    # Invoke psql with -X and NO URL or credentials in process arguments (Finding 2)
    env = {**os.environ, **pg_env}
    try:
        proc = subprocess.run(
            [psql_bin, "-X", "-v", "ON_ERROR_STOP=1"],
            input=script.encode("utf-8"),
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        print("Database load completed successfully.")
    except subprocess.CalledProcessError as e:
        sensitive = [pg_env.get("PGPASSWORD", ""), database_url or ""]
        sanitized_stderr = sanitize_error_message(
            e.stderr.decode("utf-8", errors="replace"), sensitive
        )
        raise RuntimeError(f"psql execution failed: {sanitized_stderr}") from None


def main() -> None:
    parser = argparse.ArgumentParser(description="Load celebrities.csv into database.")
    parser.add_argument(
        "csv_file",
        nargs="?",
        type=Path,
        default=DEFAULT_CSV_PATH,
        help="Path to celebrities.csv",
    )
    parser.add_argument(
        "--database-url",
        type=str,
        default=os.environ.get("PRODUCTION_DATABASE_URL") or os.environ.get("DATABASE_URL"),
        help="Database connection URL",
    )
    parser.add_argument(
        "--min-rows",
        type=int,
        default=MIN_ROWS_DEFAULT,
        help=f"Minimum rows required to proceed with load (default: {MIN_ROWS_DEFAULT})",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Generate and validate SQL script without executing against database",
    )
    args = parser.parse_args()

    if not args.csv_file.exists():
        print(f"Error: CSV file not found: {args.csv_file}", file=sys.stderr)
        sys.exit(1)

    print(f"Parsing {args.csv_file}...")
    rows = parse_celebrities_csv(args.csv_file)
    print(f"Parsed {len(rows)} celebrity records.")

    if args.dry_run:
        print("[DRY RUN] Validating SQL COPY script generation...")
        script = generate_load_script(rows)
        print(f"[DRY RUN] Generated script of {len(script)} characters.")
        print("[DRY RUN] Header preview:")
        print("\n".join(script.splitlines()[:15]))
        print("...")
        print("[DRY RUN] Finished without executing.")
        return

    try:
        execute_load(
            database_url=args.database_url,
            rows=rows,
            min_rows=args.min_rows,
        )
    except Exception as e:
        print(f"Error executing load: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
