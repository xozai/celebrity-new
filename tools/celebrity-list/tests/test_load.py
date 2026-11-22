import csv
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# Add tools/celebrity-list to path
tools_dir = Path(__file__).resolve().parent.parent
if str(tools_dir) not in sys.path:
    sys.path.insert(0, str(tools_dir))

from load import (
    parse_celebrities_csv,
    generate_load_script,
    parse_database_url,
    execute_load,
    sanitize_error_message,
)


class TestLoad(unittest.TestCase):
    def setUp(self):
        self.sample_rows = [
            {
                "name": "Tom Hanks",
                "name_norm": "tom hanks",
                "description": "American actor",
                "category": "film_tv",
                "popularity": "0.95",
                "sources": "{imdb,wikipedia}",
            },
            {
                "name": "Conan O'Brien",
                "name_norm": "conan o'brien",
                "description": "American television host and comedian",
                "category": "film_tv",
                "popularity": "0.85",
                "sources": "{wikipedia}",
            },
        ]

    def test_parse_csv(self):
        with tempfile.NamedTemporaryFile("w+", delete=False, suffix=".csv") as f:
            writer = csv.DictWriter(
                f,
                fieldnames=["name", "name_norm", "description", "category", "popularity", "sources"],
            )
            writer.writeheader()
            for r in self.sample_rows:
                writer.writerow(r)
            tmp_path = Path(f.name)

        try:
            parsed = parse_celebrities_csv(tmp_path)
            self.assertEqual(len(parsed), 2)
            self.assertEqual(parsed[0]["name"], "Tom Hanks")
            self.assertEqual(parsed[0]["popularity"], 0.95)
            self.assertEqual(parsed[0]["sources"], ["imdb", "wikipedia"])
            self.assertEqual(parsed[1]["name"], "Conan O'Brien")
            self.assertEqual(parsed[1]["sources"], ["wikipedia"])
        finally:
            tmp_path.unlink()

    def test_generate_load_script_uses_copy_no_sql_interpolation(self):
        """Verify rows are staged through COPY ... FROM STDIN with CSV data, not SQL interpolation (Finding 1)."""
        parsed = [
            {
                "name": "Tom Hanks",
                "name_norm": "tom hanks",
                "description": "American actor",
                "category": "film_tv",
                "popularity": 0.95,
                "sources": ["imdb", "wikipedia"],
            },
            {
                "name": "Conan O'Brien",
                "name_norm": "conan o'brien",
                "description": "American comedian and host\nwith newline",
                "category": "film_tv",
                "popularity": 0.85,
                "sources": ["wikipedia"],
            },
        ]

        script = generate_load_script(parsed)

        # Static SQL checks
        self.assertIn("BEGIN;", script)
        self.assertIn("CREATE TEMP TABLE staging_celebrities", script)
        self.assertIn(
            "COPY staging_celebrities (name, name_norm, description, category, popularity, sources) FROM STDIN WITH (FORMAT csv, HEADER false);",
            script,
        )
        self.assertIn("\\.\n", script)
        self.assertIn("ON CONFLICT (name_norm) DO UPDATE SET", script)
        self.assertIn("DELETE FROM celebrities", script)
        self.assertIn("COMMIT;", script)

        # Verify NO SQL INSERT statements exist (rows must be passed via COPY CSV data)
        self.assertNotIn("INSERT INTO staging_celebrities", script)
        self.assertNotIn("VALUES", script)

    def test_parse_database_url_into_pg_env(self):
        """Verify DATABASE_URL is parsed into PG* environment variables without URL in argv (Finding 2)."""
        url = "postgresql://postgres:my_secret_password_123@db.projectref.supabase.co:6543/postgres?sslmode=require"
        pg_env = parse_database_url(url)

        self.assertEqual(pg_env["PGHOST"], "db.projectref.supabase.co")
        self.assertEqual(pg_env["PGPORT"], "6543")
        self.assertEqual(pg_env["PGUSER"], "postgres")
        self.assertEqual(pg_env["PGPASSWORD"], "my_secret_password_123")
        self.assertEqual(pg_env["PGDATABASE"], "postgres")
        self.assertEqual(pg_env["PGSSLMODE"], "require")

    def test_min_rows_guard(self):
        parsed = [
            {
                "name": "Tom Hanks",
                "name_norm": "tom hanks",
                "description": "American actor",
                "category": "film_tv",
                "popularity": 0.95,
                "sources": ["imdb"],
            }
        ]

        with self.assertRaises(ValueError):
            execute_load(
                database_url="postgresql://user:pass@localhost:5432/db",
                rows=parsed,
                min_rows=2000,
                executor=lambda script, env: None,
            )

    @patch("subprocess.run")
    @patch("shutil.which")
    def test_psql_subprocess_invocation_and_sanitized_credentials(self, mock_which, mock_run):
        """Verify psql arguments contain NO database URL or credentials and uses PG* env (Finding 2)."""
        mock_which.return_value = "/usr/bin/psql"
        mock_run.return_value = MagicMock(returncode=0)

        parsed = [
            {
                "name": "Tom Hanks",
                "name_norm": "tom hanks",
                "description": "American actor",
                "category": "film_tv",
                "popularity": 0.95,
                "sources": ["imdb"],
            }
        ]
        db_url = "postgresql://appuser:super_secret_pw@db.example.com:5432/celebrity_db"

        execute_load(
            database_url=db_url,
            rows=parsed,
            min_rows=1,
        )

        mock_run.assert_called_once()
        args, kwargs = mock_run.call_args

        cmd = args[0]
        # Command must be psql -X -v ON_ERROR_STOP=1 with NO URL or credentials in argv
        self.assertEqual(cmd, ["/usr/bin/psql", "-X", "-v", "ON_ERROR_STOP=1"])
        for arg in cmd:
            self.assertNotIn("super_secret_pw", arg)
            self.assertNotIn("appuser", arg)
            self.assertNotIn("postgresql://", arg)

        # Credentials must be in kwargs['env']
        env = kwargs["env"]
        self.assertEqual(env["PGUSER"], "appuser")
        self.assertEqual(env["PGPASSWORD"], "super_secret_pw")
        self.assertEqual(env["PGHOST"], "db.example.com")
        self.assertEqual(env["PGDATABASE"], "celebrity_db")

    @patch("subprocess.run")
    @patch("shutil.which")
    def test_psql_subprocess_failure_reports_sanitized_errors(self, mock_which, mock_run):
        """Verify psql failure reports sanitized errors without credential leakage (Finding 2)."""
        mock_which.return_value = "/usr/bin/psql"
        secret_pw = "super_secret_pw"
        db_url = f"postgresql://appuser:{secret_pw}@db.example.com:5432/celebrity_db"

        # Simulate subprocess failure with error output containing connection string
        mock_proc = MagicMock()
        mock_proc.returncode = 1
        mock_run.side_effect = subprocess.CalledProcessError(
            returncode=1,
            cmd=["/usr/bin/psql", "-X", "-v", "ON_ERROR_STOP=1"],
            stderr=f"psql: error: connection to {db_url} failed: password authentication failed".encode("utf-8"),
        )

        parsed = [
            {
                "name": "Tom Hanks",
                "name_norm": "tom hanks",
                "description": "Actor",
                "category": "film_tv",
                "popularity": 0.95,
                "sources": ["imdb"],
            }
        ]

        with self.assertRaises(RuntimeError) as ctx:
            execute_load(
                database_url=db_url,
                rows=parsed,
                min_rows=1,
            )

        err_msg = str(ctx.exception)
        # Ensure password was sanitized out
        self.assertNotIn(secret_pw, err_msg)
        self.assertIn("psql: error:", err_msg)


if __name__ == "__main__":
    unittest.main()
