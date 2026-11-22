import gzip
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

# Add tools/celebrity-list to path
tools_dir = Path(__file__).resolve().parent.parent
if str(tools_dir) not in sys.path:
    sys.path.insert(0, str(tools_dir))

from sources_imdb import (
    load_title_ratings,
    load_adult_titles,
    stream_imdb_celebrities,
)


class TestImdbSource(unittest.TestCase):
    def setUp(self):
        self.fixtures_dir = Path(__file__).resolve().parent / "fixtures"
        self.ratings_tsv = self.fixtures_dir / "imdb_title_ratings.fixture"
        self.basics_tsv = self.fixtures_dir / "imdb_title_basics.fixture"
        self.names_tsv = self.fixtures_dir / "imdb_name_basics.fixture"

    def test_load_ratings(self):
        ratings = load_title_ratings(self.ratings_tsv)
        self.assertEqual(ratings["tt0000005"], 500000)
        self.assertEqual(ratings["tt0000009"], 950000)

    def test_load_adult_titles(self):
        adults = load_adult_titles(self.basics_tsv)
        self.assertIn("tt0000099", adults)
        self.assertIn("tt0000100", adults)
        self.assertIn("tt0000101", adults)
        self.assertNotIn("tt0000004", adults)
        self.assertNotIn("tt0000005", adults)

    def test_stream_and_score(self):
        celebrities = stream_imdb_celebrities(
            names_path=self.names_tsv,
            titles_path=self.basics_tsv,
            ratings_path=self.ratings_tsv,
            top_n=10,
        )
        self.assertEqual(len(celebrities), 10)

        # Check top candidate has highest popularity 1.0
        self.assertEqual(celebrities[0]["popularity"], 1.0)
        # All returned rows must have required fields
        for c in celebrities:
            self.assertIn("name", c)
            self.assertIn("name_norm", c)
            self.assertIn("description", c)
            self.assertEqual(c["category"], "film_tv")
            self.assertEqual(c["sources"], ["imdb"])
            self.assertGreaterEqual(c["popularity"], 0.0)
            self.assertLessEqual(c["popularity"], 1.0)

    def test_adult_filtering(self):
        celebrities = stream_imdb_celebrities(
            names_path=self.names_tsv,
            titles_path=self.basics_tsv,
            ratings_path=self.ratings_tsv,
            top_n=50,
        )
        names = {c["name"] for c in celebrities}

        # Person with only adult titles must be dropped
        self.assertNotIn("Adult Film Actor Only", names)
        # Person with mixed adult and mainstream title must be kept
        self.assertIn("Mixed Adult Actor", names)
        # Person with no known votes must be dropped
        self.assertNotIn("Unknown Actor No Votes", names)

    def test_gz_file_support(self):
        # Create temporary gzipped versions
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp_path = Path(tmp_dir)
            ratings_gz = tmp_path / "ratings.tsv.gz"
            basics_gz = tmp_path / "basics.tsv.gz"
            names_gz = tmp_path / "names.tsv.gz"

            with open(self.ratings_tsv, "rb") as f_in, gzip.open(ratings_gz, "wb") as f_out:
                shutil.copyfileobj(f_in, f_out)
            with open(self.basics_tsv, "rb") as f_in, gzip.open(basics_gz, "wb") as f_out:
                shutil.copyfileobj(f_in, f_out)
            with open(self.names_tsv, "rb") as f_in, gzip.open(names_gz, "wb") as f_out:
                shutil.copyfileobj(f_in, f_out)

            celebrities = stream_imdb_celebrities(
                names_path=names_gz,
                titles_path=basics_gz,
                ratings_path=ratings_gz,
                top_n=5,
            )
            self.assertEqual(len(celebrities), 5)


if __name__ == "__main__":
    unittest.main()
