"""
Wikipedia and Wikidata source pipeline for celebrity recommendations.
Fetches top viewed Wikipedia articles, inspects Wikidata for humans and
fictional characters, and categorises each entry.
Python 3 standard library only.
"""

from __future__ import annotations

import datetime
import json
import urllib.parse
import urllib.request
from typing import Any, Callable

from merge import normalise, VALID_CATEGORIES

# Wikidata Q-IDs
HUMAN_QID = "Q5"
DISAMBIGUATION_QID = "Q4167410"

FICTIONAL_QIDS = frozenset(
    {
        "Q95074",  # fictional character
        "Q15632617",  # fictional human
        "Q21070568",  # fictional entity
        "Q15773317",  # mythological character
        "Q4271324",  # mythological humanoid
        "Q130022",  # mythological figure
        "Q383884",  # mythological character
        "Q111031201",  # fictional person
        "Q14860489",  # fictional character with superpowers
        "Q170584",  # comic book character
        "Q22908",  # legendary character
        "Q7889",  # video game character
        "Q12377751",  # fictional human character
    }
)

# Common occupation Q-IDs
FILM_TV_OCCUPATIONS = frozenset(
    {
        "Q33999",  # actor
        "Q245068",  # comedian
        "Q2526255",  # film director
        "Q28389",  # screenwriter
        "Q3455803",  # television presenter
        "Q2516843",  # film actor
        "Q10798782",  # television actor
        "Q3282637",  # film producer
        "Q11424",  # film
    }
)

MUSIC_OCCUPATIONS = frozenset(
    {
        "Q177220",  # singer
        "Q639669",  # musician
        "Q753110",  # songwriter
        "Q2252262",  # rapper
        "Q183945",  # record producer
        "Q130857",  # DJ
        "Q36834",  # composer
    }
)

SPORTS_OCCUPATIONS = frozenset(
    {
        "Q2066131",  # athlete
        "Q937857",  # association football player
        "Q3665646",  # basketball player
        "Q10833314",  # tennis player
        "Q11513337",  # baseball player
        "Q1150437",  # boxer
        "Q378622",  # racing driver
        "Q1078733",  # swimmer
        "Q19363028",  # American football player
    }
)

PUBLIC_FIGURE_OCCUPATIONS = frozenset(
    {
        "Q82955",  # politician
        "Q2285706",  # head of state
        "Q483501",  # businessperson
        "Q131524",  # entrepreneur
        "Q1930187",  # journalist
        "Q15253558",  # activist
        "Q40348",  # lawyer
        "Q901",  # scientist
        "Q36180",  # writer / author
    }
)

META_PREFIXES = (
    "special:",
    "wikipedia:",
    "portal:",
    "help:",
    "file:",
    "category:",
    "template:",
    "talk:",
    "user:",
    "draft:",
    "timedtext:",
)

META_TITLES = frozenset(
    {
        "main_page",
        "search",
        "index",
        "404.php",
    }
)

USER_AGENT = "celebrity-list-builder/1.0 (https://github.com/xozai/celebrity-new)"


def default_fetch_url(url: str) -> bytes:
    """Fetch URL over HTTP using standard library urllib."""
    req = urllib.request.Request(
        url,
        headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read()


def is_meta_article(title: str) -> bool:
    """Check if Wikipedia title is a meta-article, namespace page, or disambiguation."""
    t = title.strip().lower()
    if t in META_TITLES:
        return True
    if any(t.startswith(prefix) for prefix in META_PREFIXES):
        return True
    if t.endswith("_(disambiguation)"):
        return True
    return False


def parse_pageviews_payload(payload: dict | str) -> list[dict[str, Any]]:
    """Parse Wikimedia pageviews API payload and filter non-articles."""
    if isinstance(payload, str):
        payload = json.loads(payload)

    articles_map: dict[str, int] = {}
    items = payload.get("items", [])
    for item in items:
        for entry in item.get("articles", []):
            title = entry.get("article", "")
            views = int(entry.get("views", 0))
            if not title or is_meta_article(title):
                continue
            articles_map[title] = articles_map.get(title, 0) + views

    # Sort descending by views
    sorted_items = sorted(articles_map.items(), key=lambda kv: kv[1], reverse=True)
    return [{"title": title, "views": views} for title, views in sorted_items]


def classify_category(
    p31: list[str],
    p106: list[str],
    description: str = "",
) -> str:
    """Classify celebrity into one of VALID_CATEGORIES based on Wikidata and description."""
    desc = (description or "").lower()

    if any(q in FICTIONAL_QIDS for q in p31) or "fictional" in desc or "character" in desc:
        return "fictional"

    if any(q in FILM_TV_OCCUPATIONS for q in p106) or any(
        kw in desc
        for kw in (
            "actor",
            "actress",
            "filmmaker",
            "film director",
            "director",
            "comedian",
            "host",
            "screenwriter",
        )
    ):
        return "film_tv"

    if any(q in MUSIC_OCCUPATIONS for q in p106) or any(
        kw in desc
        for kw in (
            "singer",
            "musician",
            "songwriter",
            "rapper",
            "band",
            "composer",
            "guitarist",
            "vocalist",
        )
    ):
        return "music"

    if any(q in SPORTS_OCCUPATIONS for q in p106) or any(
        kw in desc
        for kw in (
            "footballer",
            "player",
            "athlete",
            "tennis",
            "boxer",
            "driver",
            "swimmer",
            "basketball",
            "baseball",
            "quarterback",
        )
    ):
        return "sports"

    if any(q in PUBLIC_FIGURE_OCCUPATIONS for q in p106) or any(
        kw in desc
        for kw in (
            "politician",
            "president",
            "prime minister",
            "entrepreneur",
            "businessman",
            "businesswoman",
            "journalist",
            "activist",
            "monarch",
            "king",
            "queen",
            "scientist",
        )
    ):
        return "public_figure"

    return "other"


def parse_wikidata_entities(wikidata_json: dict | str) -> list[dict[str, Any]]:
    """
    Parse Wikidata entities response. Keep only entities that represent humans
    (P31 == Q5) or fictional characters, and exclude disambiguation pages.
    """
    if isinstance(wikidata_json, str):
        wikidata_json = json.loads(wikidata_json)

    entities = wikidata_json.get("entities", {})
    candidates: list[dict[str, Any]] = []

    for qid, entity in entities.items():
        if not isinstance(entity, dict) or "missing" in entity:
            continue

        claims = entity.get("claims", {})

        # Extract P31 instance of IDs
        p31_statements = claims.get("P31", [])
        p31_ids: list[str] = []
        for stmt in p31_statements:
            mainsnak = stmt.get("mainsnak", {})
            datavalue = mainsnak.get("datavalue", {})
            val = datavalue.get("value", {})
            if isinstance(val, dict) and "id" in val:
                p31_ids.append(val["id"])

        # Skip disambiguation pages
        if DISAMBIGUATION_QID in p31_ids:
            continue

        # Check if human or fictional
        is_human = HUMAN_QID in p31_ids
        is_fictional = any(q in FICTIONAL_QIDS for q in p31_ids)
        if not (is_human or is_fictional):
            continue

        # Extract English description
        desc_entry = entity.get("descriptions", {}).get("en", {})
        description = desc_entry.get("value", "").strip()
        if "disambiguation" in description.lower():
            continue

        # Extract English label / name
        label_entry = entity.get("labels", {}).get("en", {})
        name = label_entry.get("value", "").strip()
        if not name:
            continue

        # Extract P106 occupations
        p106_statements = claims.get("P106", [])
        p106_ids: list[str] = []
        for stmt in p106_statements:
            mainsnak = stmt.get("mainsnak", {})
            datavalue = mainsnak.get("datavalue", {})
            val = datavalue.get("value", {})
            if isinstance(val, dict) and "id" in val:
                p106_ids.append(val["id"])

        cat = classify_category(p31_ids, p106_ids, description)

        candidates.append(
            {
                "wikidata_id": qid,
                "name": name,
                "name_norm": normalise(name),
                "description": description,
                "category": cat,
            }
        )

    return candidates


def get_default_months(count: int = 12) -> list[tuple[str, str]]:
    """Return list of (year_str, month_str) for the previous count months."""
    months = []
    today = datetime.date.today()
    # Start from previous month
    year = today.year
    month = today.month - 1
    if month == 0:
        month = 12
        year -= 1

    for _ in range(count):
        months.append((f"{year:04d}", f"{month:02d}"))
        month -= 1
        if month == 0:
            month = 12
            year -= 1
    return months


def fetch_wikipedia_celebrities(
    months: list[tuple[str, str]] | None = None,
    fetch_fn: Callable[[str], bytes] = default_fetch_url,
    max_candidates: int = 4000,
) -> list[dict[str, Any]]:
    """
    Fetch top articles across given months from Wikimedia Pageviews API,
    look up Wikidata entities, filter to humans/fictional characters,
    and return ranked celebrity records.
    """
    if months is None:
        months = get_default_months(12)

    # 1. Aggregate views across months
    all_views: dict[str, int] = {}
    for year, month in months:
        url = (
            f"https://wikimedia.org/api/rest_v1/metrics/pageviews/top/"
            f"en.wikipedia/all-access/{year}/{month}/all-days"
        )
        try:
            raw = fetch_fn(url)
            parsed = parse_pageviews_payload(raw.decode("utf-8"))
            for entry in parsed:
                t = entry["title"]
                all_views[t] = all_views.get(t, 0) + entry["views"]
        except Exception:
            continue

    if not all_views:
        return []

    # Sort articles by total views descending and take top candidate articles
    sorted_articles = sorted(all_views.items(), key=lambda kv: kv[1], reverse=True)
    top_articles = sorted_articles[:max_candidates]

    # 2. Look up Wikidata entities in batches of 50
    candidates: list[dict[str, Any]] = []
    seen_norm: set[str] = set()
    batch_size = 50

    for i in range(0, len(top_articles), batch_size):
        batch = [t for t, _ in top_articles[i : i + batch_size]]
        titles_param = "|".join(urllib.parse.quote(t) for t in batch)
        wikidata_url = (
            f"https://www.wikidata.org/w/api.php?action=wbgetentities"
            f"&sites=enwiki&titles={titles_param}&props=descriptions|claims|labels"
            f"&languages=en&format=json"
        )
        try:
            raw = fetch_fn(wikidata_url)
            entities = parse_wikidata_entities(raw.decode("utf-8"))
            for ent in entities:
                norm = ent["name_norm"]
                if not norm or norm in seen_norm:
                    continue
                seen_norm.add(norm)
                # Attach total views from the article
                candidates.append(ent)
        except Exception:
            continue

    if not candidates:
        return []

    # Assign rank-normalised popularity in [0.0, 1.0]
    total = len(candidates)
    result = []
    for rank, cand in enumerate(candidates, start=1):
        # Rank 1 gets 1.0, rank N gets > 0.0
        pop = round(max(0.0, min(1.0, (total - rank + 1) / total)), 4)
        result.append(
            {
                "name": cand["name"],
                "name_norm": cand["name_norm"],
                "description": cand["description"],
                "category": cand["category"],
                "popularity": pop,
                "sources": ["wikipedia"],
            }
        )

    return result
