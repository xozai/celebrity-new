import os
import sys
import tempfile
import unittest
from pathlib import Path

# Add tools/celebrity-list directory to sys.path
tools_dir = Path(__file__).resolve().parent.parent
if str(tools_dir) not in sys.path:
    sys.path.insert(0, str(tools_dir))

from merge import normalise, load_blocklist, merge, VALID_CATEGORIES


class TestNormalise(unittest.TestCase):
    def test_postgresql_name_norm_contract(self):
        cases = {
            "Beyoncé": "beyonce",
            "Zoë  Kravitz": "zoe kravitz",
            "Björk": "bjork",
            "Æon Flux": "aeon flux",
            "Renée O'Connor": "renee o'connor",
            "Jean-Claude Van Damme": "jean-claude van damme",
            "Samuel L. Jackson": "samuel l. jackson",
            "Łukasz Fabiański": "lukasz fabianski",
            "Mötley Crüe": "motley crue",
            "  Straße  Test ": "strasse test",
            "Œdipe": "oedipe",
            "Søren": "soren",
            "Đorđe": "dorde",
            "½ Man": "1/2 man",
            "Sir ½ Man": "sir 1/2 man",
            "  ¼ Man  ": "1/4 man",
            "Sir\t¾ Man": "sir 3/4 man",
            "Artist©": "artist(c)",
            "Name±": "name+/-",
        }
        for name, expected in cases.items():
            with self.subTest(name=name):
                self.assertEqual(normalise(name), expected)

    def test_lowercase_and_strip(self):
        self.assertEqual(normalise("  Keanu Reeves  "), "keanu reeves")
        self.assertEqual(normalise("TOM HANKS"), "tom hanks")
        self.assertEqual(normalise("Steve   Carell"), "steve carell")

    def test_accents_and_diacritics(self):
        self.assertEqual(normalise("Beyoncé"), "beyonce")
        self.assertEqual(normalise("Renée Zellweger"), "renee zellweger")
        self.assertEqual(normalise("Björk"), "bjork")
        self.assertEqual(normalise("François Truffaut"), "francois truffaut")
        self.assertEqual(normalise("Zoë Kravitz"), "zoe kravitz")
        self.assertEqual(normalise("Penélope Cruz"), "penelope cruz")
        self.assertEqual(normalise("Cillian Murphy"), "cillian murphy")


class TestBlocklist(unittest.TestCase):
    def test_load_blocklist_from_file(self):
        with tempfile.NamedTemporaryFile("w+", delete=False) as f:
            f.write("# Disallowed historical figures\n")
            f.write("Adolf Hitler\n")
            f.write("\n")
            f.write("  Osama bin Laden  \n")
            f.write("# Another comment\n")
            f.write("Jeffrey Dahmer\n")
            tmp_path = f.name

        try:
            blocked = load_blocklist(tmp_path)
            self.assertIn("adolf hitler", blocked)
            self.assertIn("osama bin laden", blocked)
            self.assertIn("jeffrey dahmer", blocked)
            self.assertEqual(len(blocked), 3)
        finally:
            os.remove(tmp_path)

    def test_missing_blocklist_file_raises_error(self):
        non_existent = Path("/path/that/does/not/exist/blocklist.txt")
        with self.assertRaises(FileNotFoundError):
            load_blocklist(non_existent)

    def test_in_memory_blocklist_iterable(self):
        blocked = load_blocklist(["Adolf Hitler", " Osama bin Laden "])
        self.assertEqual(blocked, {"adolf hitler", "osama bin laden"})


class TestMerge(unittest.TestCase):
    def setUp(self):
        self.wiki_rows = [
            {
                "name": "Beyoncé",
                "description": "American singer-songwriter",
                "category": "music",
                "popularity": 0.85,
                "sources": ["wikipedia"],
            },
            {
                "name": "Tom Hanks",
                "description": "American actor and filmmaker",
                "category": "film_tv",
                "popularity": 0.80,
                "sources": ["wikipedia"],
            },
            {
                "name": "Adolf Hitler",
                "description": "Dictator of Germany",
                "category": "public_figure",
                "popularity": 0.99,
                "sources": ["wikipedia"],
            },
        ]
        self.imdb_rows = [
            {
                "name": "Beyonce Knowles",
                "description": "Soundtrack, Actress",
                "category": "film_tv",
                "popularity": 0.90,
                "sources": ["imdb"],
            },
            {
                "name": "Tom Hanks",
                "description": "Actor, Producer",
                "category": "film_tv",
                "popularity": 0.95,
                "sources": ["imdb"],
            },
            {
                "name": "Zendaya",
                "description": "Actress, Producer",
                "category": "film_tv",
                "popularity": 0.88,
                "sources": ["imdb"],
            },
        ]

    def test_merge_overlap_and_higher_score(self):
        merged = merge(self.wiki_rows, self.imdb_rows, blocklist={"adolf hitler"})
        by_norm = {row["name_norm"]: row for row in merged}

        # Tom Hanks is in both: popularity should be max(0.80, 0.95) == 0.95
        self.assertIn("tom hanks", by_norm)
        tom = by_norm["tom hanks"]
        self.assertEqual(tom["popularity"], 0.95)
        self.assertEqual(sorted(tom["sources"]), ["imdb", "wikipedia"])
        self.assertEqual(tom["category"], "film_tv")
        # Richer description from Wikipedia is preferred
        self.assertEqual(tom["description"], "American actor and filmmaker")

    def test_merge_blocklist_removal(self):
        merged = merge(self.wiki_rows, self.imdb_rows, blocklist={"adolf hitler"})
        names = [row["name_norm"] for row in merged]
        self.assertNotIn("adolf hitler", names)

    def test_merge_sorted_by_popularity_descending(self):
        merged = merge(self.wiki_rows, self.imdb_rows, blocklist={"adolf hitler"})
        scores = [row["popularity"] for row in merged]
        self.assertEqual(scores, sorted(scores, reverse=True))

    def test_category_validation(self):
        rows = [
            {
                "name": "Custom Person",
                "description": "Test",
                "category": "invalid_category",
                "popularity": 0.5,
                "sources": ["wikipedia"],
            }
        ]
        merged = merge(rows, [], blocklist=[])
        self.assertEqual(merged[0]["category"], "other")
        self.assertIn(merged[0]["category"], VALID_CATEGORIES)


if __name__ == "__main__":
    unittest.main()
