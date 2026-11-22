import csv
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

# Add tools/celebrity-list to path
tools_dir = Path(__file__).resolve().parent.parent
if str(tools_dir) not in sys.path:
    sys.path.insert(0, str(tools_dir))

from build import build_celebrities_csv, download_imdb_files


class TestBuild(unittest.TestCase):
    def test_build_celebrities_csv(self):
        wiki_candidates = [
            {
                "name": "Beyoncé",
                "name_norm": "beyonce",
                "description": "American singer",
                "category": "music",
                "popularity": 0.95,
                "sources": ["wikipedia"],
            },
            {
                "name": "Adolf Hitler",
                "name_norm": "adolf hitler",
                "description": "Dictator",
                "category": "public_figure",
                "popularity": 0.99,
                "sources": ["wikipedia"],
            },
        ]
        imdb_candidates = [
            {
                "name": "Tom Hanks",
                "name_norm": "tom hanks",
                "description": "Actor, Producer",
                "category": "film_tv",
                "popularity": 0.90,
                "sources": ["imdb"],
            }
        ]

        with tempfile.TemporaryDirectory() as tmp_dir:
            out_csv = Path(tmp_dir) / "celebrities.csv"
            blocklist = {"adolf hitler"}

            rows = build_celebrities_csv(
                wiki_candidates=wiki_candidates,
                imdb_candidates=imdb_candidates,
                blocklist=blocklist,
                output_path=out_csv,
            )

            self.assertEqual(len(rows), 2)
            self.assertTrue(out_csv.exists())

            # Verify CSV contents and header
            with open(out_csv, "r", encoding="utf-8") as f:
                reader = csv.DictReader(f)
                expected_fields = ["name", "name_norm", "description", "category", "popularity", "sources"]
                self.assertEqual(reader.fieldnames, expected_fields)
                written = list(reader)

            self.assertEqual(len(written), 2)
            names = [r["name"] for r in written]
            self.assertIn("Beyoncé", names)
            self.assertIn("Tom Hanks", names)
            self.assertNotIn("Adolf Hitler", names)

            # Check format of sources column
            beyonce_row = next(r for r in written if r["name_norm"] == "beyonce")
            self.assertEqual(beyonce_row["sources"], "{wikipedia}")

    def test_atomic_download_and_refresh(self):
        """Verify atomic download via temp file and rename on success, and refresh flag (Finding 14)."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            data_dir = Path(tmp_dir)

            downloaded_urls = []

            def mock_urlretrieve(url, filename):
                downloaded_urls.append((url, filename))
                with open(filename, "wb") as f:
                    f.write(b"dummy dataset")

            with patch("urllib.request.urlretrieve", side_effect=mock_urlretrieve):
                paths = download_imdb_files(data_dir=data_dir, refresh=False)
                for path in paths.values():
                    self.assertTrue(path.exists())
                    # Ensure temporary file is gone after atomic rename
                    tmp_file = path.with_suffix(path.suffix + ".tmp")
                    self.assertFalse(tmp_file.exists())

                self.assertEqual(len(downloaded_urls), 3)

                # Second call without refresh should use cached files (0 downloads)
                download_imdb_files(data_dir=data_dir, refresh=False)
                self.assertEqual(len(downloaded_urls), 3)

                # Third call with refresh=True should re-download (3 new downloads)
                download_imdb_files(data_dir=data_dir, refresh=True)
                self.assertEqual(len(downloaded_urls), 6)


if __name__ == "__main__":
    unittest.main()
