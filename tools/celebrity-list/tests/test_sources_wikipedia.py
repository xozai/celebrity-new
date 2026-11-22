import json
import sys
import unittest
from pathlib import Path

# Add tools/celebrity-list to path
tools_dir = Path(__file__).resolve().parent.parent
if str(tools_dir) not in sys.path:
    sys.path.insert(0, str(tools_dir))

from sources_wikipedia import (
    parse_pageviews_payload,
    is_meta_article,
    parse_wikidata_entities,
    classify_category,
    fetch_wikipedia_celebrities,
)


class TestWikipediaSource(unittest.TestCase):
    def setUp(self):
        self.fixtures_dir = Path(__file__).resolve().parent / "fixtures"
        with open(self.fixtures_dir / "wikipedia_pageviews.json", "r", encoding="utf-8") as f:
            self.pageviews_json = json.load(f)
        with open(self.fixtures_dir / "wikidata_entities.json", "r", encoding="utf-8") as f:
            self.wikidata_json = json.load(f)

    def test_meta_article_filtering(self):
        self.assertTrue(is_meta_article("Main_Page"))
        self.assertTrue(is_meta_article("Special:Search"))
        self.assertTrue(is_meta_article("Wikipedia:About"))
        self.assertTrue(is_meta_article("Portal:Current_events"))
        self.assertTrue(is_meta_article("Taylor_Swift_(disambiguation)"))
        self.assertFalse(is_meta_article("Taylor_Swift"))
        self.assertFalse(is_meta_article("Cillian_Murphy"))

    def test_parse_pageviews(self):
        articles = parse_pageviews_payload(self.pageviews_json)
        # Should exclude Main_Page, Special:Search, Wikipedia:About
        article_names = [a["title"] for a in articles]
        self.assertNotIn("Main_Page", article_names)
        self.assertNotIn("Special:Search", article_names)
        self.assertIn("Taylor_Swift", article_names)
        self.assertIn("Cillian_Murphy", article_names)
        # Highest views article should be first
        self.assertEqual(article_names[0], "Taylor_Swift")

    def test_category_classification(self):
        # Taylor Swift: music
        cat_music = classify_category(p31=["Q5"], p106=["Q177220"], description="American singer-songwriter")
        self.assertEqual(cat_music, "music")

        # Cillian Murphy: film_tv
        cat_film = classify_category(p31=["Q5"], p106=["Q33999"], description="Irish actor")
        self.assertEqual(cat_film, "film_tv")

        # Lionel Messi: sports
        cat_sports = classify_category(p31=["Q5"], p106=["Q937857"], description="Argentine professional footballer")
        self.assertEqual(cat_sports, "sports")

        # Barack Obama: public_figure
        cat_public = classify_category(p31=["Q5"], p106=["Q82955"], description="44th president of the United States")
        self.assertEqual(cat_public, "public_figure")

        # Sherlock Holmes: fictional
        cat_fictional = classify_category(p31=["Q95074"], p106=[], description="fictional detective")
        self.assertEqual(cat_fictional, "fictional")

    def test_parse_wikidata_entities(self):
        celebrities = parse_wikidata_entities(self.wikidata_json)
        names = {c["name"] for c in celebrities}

        # Humans and fictional characters kept
        self.assertIn("Taylor Swift", names)
        self.assertIn("Cillian Murphy", names)
        self.assertIn("Sherlock Holmes", names)
        self.assertIn("Lionel Messi", names)
        self.assertIn("Barack Obama", names)

        # Non-humans / non-fictional characters dropped
        self.assertNotIn("Oppenheimer", names)
        self.assertNotIn("United States", names)

    def test_pipeline_with_mock_fetcher(self):
        def mock_fetch(url):
            if "wikimedia.org" in url:
                return json.dumps(self.pageviews_json).encode("utf-8")
            elif "wikidata.org" in url:
                return json.dumps(self.wikidata_json).encode("utf-8")
            raise ValueError(f"Unexpected URL: {url}")

        rows = fetch_wikipedia_celebrities(
            months=[("2024", "01")],
            fetch_fn=mock_fetch,
        )

        self.assertGreater(len(rows), 0)
        # All rows must have required fields
        for r in rows:
            self.assertIn("name", r)
            self.assertIn("name_norm", r)
            self.assertIn("description", r)
            self.assertIn("category", r)
            self.assertIn("popularity", r)
            self.assertEqual(r["sources"], ["wikipedia"])
            self.assertGreaterEqual(r["popularity"], 0.0)
            self.assertLessEqual(r["popularity"], 1.0)


if __name__ == "__main__":
    unittest.main()
