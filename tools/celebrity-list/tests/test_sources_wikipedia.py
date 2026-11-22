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
        # Video game class Q7889 must be dropped (Finding 7)
        self.assertNotIn("Elden Ring", names)

    def test_ranking_by_view_count_not_entity_order(self):
        """Verify that ranking reflects pageview counts rather than entity dictionary order (Finding 6)."""
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

        # In wikidata_entities.json, Sherlock Holmes is listed first,
        # but in wikipedia_pageviews.json, Taylor Swift (3.5M views) > Cillian Murphy (2.8M) > Sherlock Holmes (1.8M).
        names_by_rank = [r["name"] for r in rows]
        self.assertEqual(names_by_rank[0], "Taylor Swift")
        self.assertEqual(names_by_rank[1], "Cillian Murphy")
        self.assertEqual(names_by_rank[2], "Sherlock Holmes")
        self.assertGreater(rows[0]["popularity"], rows[2]["popularity"])

    def test_incomplete_fetch_fails_build(self):
        """Verify that API errors or fetch failures raise an exception after retries (Finding 3)."""
        attempts = 0

        def failing_fetch(url):
            nonlocal attempts
            attempts += 1
            raise urllib.error.URLError("Connection reset")

        with self.assertRaises(RuntimeError):
            fetch_wikipedia_celebrities(
                months=[("2024", "01")],
                fetch_fn=failing_fetch,
                max_retries=2,
            )
        self.assertEqual(attempts, 2)

    def test_api_error_response_fails_build(self):
        """Verify that an API returning an error object raises RuntimeError (Finding 3)."""
        def error_fetch(url):
            return json.dumps({"error": {"code": "internal-error", "info": "Service Unavailable"}}).encode("utf-8")

        with self.assertRaises(RuntimeError):
            fetch_wikipedia_celebrities(
                months=[("2024", "01")],
                fetch_fn=error_fetch,
                max_retries=1,
            )


if __name__ == "__main__":
    unittest.main()
