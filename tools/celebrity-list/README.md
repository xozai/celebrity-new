# Celebrity List Tools

Tools for generating and managing the curated celebrity recommendation list for Celebrity Celebrity.

## Requirements

- **Python 3.10+**: All scripts (`build.py`, `sources_wikipedia.py`, `sources_imdb.py`, `merge.py`, `load.py`) strictly use the **Python 3 standard library only**. No third-party Python packages (`pip`) are required.
- **PostgreSQL Client (`psql`)**: `load.py` uses `psql` to connect to PostgreSQL / Supabase. Ensure `psql` is installed on your PATH (`postgresql-client` on Debian/Ubuntu, `brew install libpq` on macOS).

## Workflow

### 1. Build the recommendation list
Combines English Wikipedia pageviews (last 12 months), Wikidata human and fictional character records, and IMDb top-rated cast/directors:

```bash
python3 tools/celebrity-list/build.py
```

Outputs `tools/celebrity-list/celebrities.csv`.

Flags:
- `--wiki-months N`: Number of months of Wikipedia pageviews to inspect (default: 12).
- `--imdb-top N`: Number of top IMDb figures to stream and score (default: 3000).
- `--refresh`: Force re-download of IMDb dataset files even if cached locally.
- `--output PATH`: Custom output CSV file path.

### 2. Load recommendations into Supabase

Loads `celebrities.csv` into the Supabase database. Credentials are read from `DATABASE_URL` (or `PRODUCTION_DATABASE_URL`) and passed safely to `psql` through `PG*` environment variables without exposing credentials in command-line arguments:

```bash
DATABASE_URL="postgresql://..." python3 tools/celebrity-list/load.py
```

Flags:
- `--dry-run`: Generate and validate the SQL / COPY staging script without executing against the database.
- `--min-rows N`: Minimum safety threshold of rows required before loading (default: 2000).

### 3. Run unit tests
All tests run with local mock fixtures and zero network access:

```bash
python3 -m unittest discover tools/celebrity-list/tests
```
