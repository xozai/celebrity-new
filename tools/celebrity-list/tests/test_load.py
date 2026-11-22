import csv
import sys
import tempfile
import unittest
from pathlib import Path

# Add tools/celebrity-list to path
tools_dir = Path(__file__).resolve().parent.parent
if str(tools_dir) not in sys.path:
    sys.path.insert(0, str(tools_dir))

from load import (
    parse_celebrities_csv,
    generate_load_sql,
    execute_load,
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

    def test_generate_load_sql(self):
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
                "description": "American television host and comedian",
                "category": "film_tv",
                "popularity": 0.85,
                "sources": ["wikipedia"],
            },
        ]

        sql = generate_load_sql(parsed)

        # Check transaction boundaries
        self.assertIn("BEGIN;", sql)
        self.assertIn("COMMIT;", sql)

        # Check temporary staging table
        self.assertIn("staging_celebrities", sql)

        # Check SQL escaping for single quotes: Conan O'Brien -> 'Conan O''Brien'
        self.assertIn("Conan O''Brien", sql)

        # Check upsert logic
        self.assertIn("ON CONFLICT (name_norm) DO UPDATE SET", sql)

        # Check delete logic for absent rows
        self.assertIn("DELETE FROM celebrities", sql)
        self.assertIn("WHERE name_norm NOT IN (SELECT name_norm FROM staging_celebrities)", sql)

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

        # Should raise ValueError if row count is below min_rows
        with self.assertRaises(ValueError):
            execute_load(
                database_url="postgresql://user:pass@localhost:5432/db",
                rows=parsed,
                min_rows=2000,
                executor=lambda sql: None,
            )

    def test_execute_load_with_mock_executor(self):
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
        executed_sqls = []

        def mock_executor(sql: str) -> None:
            executed_sqls.append(sql)

        execute_load(
            database_url="postgresql://user:pass@localhost:5432/db",
            rows=parsed,
            min_rows=1,
            executor=mock_executor,
        )

        self.assertEqual(len(executed_sqls), 1)
        self.assertIn("tom hanks", executed_sqls[0])


if __name__ == "__main__":
    unittest.main()
