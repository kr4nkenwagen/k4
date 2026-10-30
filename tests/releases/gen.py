#!/usr/bin/env python3
"""Writes the fake TMDB, IGDB and Hardcover answers for k4-releases' tests (invented titles), named
the way releases.py names a request in FAKE mode. Run: K4_RELEASES_NOW=1793352734 python3 gen.py DIR
(then follow and calendar one each, and write data.txt / nokeys.txt from `releases.py data`)"""
import json, os, sys, urllib.parse
sys.path.insert(0, os.path.expanduser("~/.local/share/k4"))
os.environ.setdefault("K4_RELEASES_FAKE", sys.argv[1])
import releases as R

out = sys.argv[1]
os.makedirs(out, exist_ok=True)


def put(url, data, body=None):
    with open(os.path.join(out, R.fake_name(url, body)), "w") as f: json.dump(data, f, ensure_ascii=False)


def tmdb_url(path, **q):
    q["api_key"] = "test"
    return R.TMDB + path + "?" + urllib.parse.urlencode(sorted(q.items()))


t = R.today()
d = lambda n: (t + R.dt.timedelta(days=n)).isoformat()
# movies: discover (2 pages), then each one's details
for page, ids in ((1, [101, 102]), (2, [])):
    put(tmdb_url("/discover/movie", region="SE", **{"release_date.gte": t.isoformat(), "release_date.lte": (t + R.dt.timedelta(days=240)).isoformat(),
        "with_release_type": "2|3|4", "sort_by": "popularity.desc", "include_adult": "false", "language": "en-US", "page": page}), {"results": [{"id": i} for i in ids]})
put(tmdb_url("/movie/101", append_to_response="videos,credits,release_dates,watch/providers", language="en-US"), {
    "title": "The Last Lighthouse", "release_date": d(49), "runtime": 124, "genres": [{"name": "Drama"}, {"name": "Mystery"}],
    "overview": "A keeper on a northern island finds the light has been signalling to someone.", "vote_average": 7.8, "vote_count": 40, "poster_path": "",
    "credits": {"crew": [{"job": "Director", "name": "Ada Holm"}], "cast": [{"name": "Nils Berg"}, {"name": "Saga Lund"}]},
    "release_dates": {"results": [{"iso_3166_1": "SE", "release_dates": [{"type": 3, "release_date": d(49) + "T00:00:00Z"}, {"type": 4, "release_date": d(110) + "T00:00:00Z"}]},
                                  {"iso_3166_1": "US", "release_dates": [{"type": 3, "release_date": d(42) + "T00:00:00Z"}]}]},
    "videos": {"results": [{"site": "YouTube", "type": "Teaser", "key": "teaser101", "name": "Teaser"}, {"site": "YouTube", "type": "Trailer", "key": "trail101", "name": "Official Trailer", "official": True}]},
    "watch/providers": {"results": {}}})
put(tmdb_url("/movie/102", append_to_response="videos,credits,release_dates,watch/providers", language="en-US"), {
    "title": "Paper Harbour", "release_date": d(7), "runtime": 98, "genres": [{"name": "Comedy"}], "overview": "Two ferry pilots, one route.", "vote_count": 0, "poster_path": "",
    "credits": {"crew": [], "cast": [{"name": "Lina Ek"}]},
    "release_dates": {"results": [{"iso_3166_1": "SE", "release_dates": [{"type": 4, "release_date": d(7) + "T00:00:00Z"}]}]},
    "videos": {"results": []}, "watch/providers": {"results": {"SE": {"flatrate": [{"provider_name": "Netflix"}]}}}})
# TV
put(tmdb_url("/discover/tv", **{"air_date.gte": t.isoformat(), "air_date.lte": (t + R.dt.timedelta(days=150)).isoformat(), "sort_by": "popularity.desc",
    "watch_region": "SE", "include_null_first_air_dates": "false", "language": "en-US", "page": 1}), {"results": [{"id": 201}, {"id": 202}]})
put(tmdb_url("/tv/201", append_to_response="videos,credits,watch/providers", language="en-US"), {
    "name": "Northern Static", "first_air_date": "2025-03-01", "number_of_seasons": 2, "genres": [{"name": "Sci-Fi & Fantasy"}],
    "next_episode_to_air": {"air_date": d(13), "season_number": 2, "episode_number": 1}, "overview": "Radio signals from an empty sky.", "vote_count": 0,
    "credits": {"cast": [{"name": "Omar Said"}]}, "videos": {"results": [{"site": "YouTube", "type": "Trailer", "key": "trail201", "name": "Season 2 Trailer"}]},
    "watch/providers": {"results": {"SE": {"flatrate": [{"provider_name": "Max"}]}}}, "networks": []})
put(tmdb_url("/tv/202", append_to_response="videos,credits,watch/providers", language="en-US"), {
    "name": "Daily Weather Hour", "first_air_date": "2020-01-01", "number_of_seasons": 9, "genres": [],
    "next_episode_to_air": {"air_date": d(1), "season_number": 9, "episode_number": 140}, "overview": "", "vote_count": 0,
    "credits": {"cast": []}, "videos": {"results": []}, "watch/providers": {"results": {}}, "networks": [{"name": "SVT"}]})
# games: Steam's popular upcoming, the featured coming-soon, each app's details
put("%s/search/results/?filter=popularcomingsoon&json=1&count=40&cc=se&l=english" % R.STEAM, {"items": [{"name": "Ashfall Tactics", "logo": "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/301/abc/capsule_231x87.jpg"}]})
put("%s/api/featuredcategories?cc=se&l=english" % R.STEAM, {"coming_soon": {"items": [{"id": 302, "name": "Quiet Orbit"}]}})
day = lambda n: (t + R.dt.timedelta(days=n))
put("%s/api/appdetails?appids=301&cc=se&l=english" % R.STEAM, {"301": {"success": True, "data": {"type": "game", "name": "Ashfall Tactics", "release_date": {"coming_soon": True, "date": day(32).strftime("%-d %b, %Y")},
    "short_description": "Turn-based strategy on a cooling world.", "genres": [{"description": "Strategy"}], "developers": ["Ember Works"], "publishers": ["Ember Works"],
    "platforms": {"windows": True, "linux": True}, "header_image": "", "movies": [{"name": "Reveal Trailer", "hls_h264": "https://video.example/301.m3u8"}]}}})
put("%s/api/appdetails?appids=302&cc=se&l=english" % R.STEAM, {"302": {"success": True, "data": {"type": "game", "name": "Quiet Orbit", "release_date": {"coming_soon": True, "date": "Q1 2027"},
    "short_description": "A slow space station.", "genres": [{"description": "Simulation"}], "developers": ["Orbit Lab"], "platforms": {"windows": True}, "header_image": "", "movies": []}}})
# books
q = '{ books(where: {release_date: {_gt: "%s"}}, order_by: {users_count: desc}, limit: 40) { %s } }' % (t.isoformat(), R.HC_FIELDS)
put("https://api.hardcover.app/v1/graphql", {"data": {"books": [{"id": 401, "title": "The Glass Orchard", "slug": "the-glass-orchard", "release_date": d(6), "description": "<p>The orchard remembers.</p>",
     "pages": 412, "users_count": 950, "cached_tags": {"Genre": [{"tag": "Fantasy"}, {"tag": "Literary"}]}, "image": {"url": ""}, "contributions": [{"author": {"name": "Lina Ek"}}], "book_series": [{"position": 2, "series": {"name": "Orchard"}}]}]}},
    json.dumps({"query": q}))
# the dated-again answer for a followed movie (tick): The Last Lighthouse moved a week later
moved = json.load(open(os.path.join(out, R.fake_name(tmdb_url("/movie/101", append_to_response="videos,credits,release_dates,watch/providers", language="en-US")))))
moved["release_dates"]["results"][0]["release_dates"][0]["release_date"] = d(56) + "T00:00:00Z"
json.dump(moved, open(os.path.join(out, "moved-101.json"), "w"))
print("ok")
