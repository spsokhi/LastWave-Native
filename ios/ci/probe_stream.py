"""CI diagnostic: can this machine get playable YouTube audio at all?

Mirrors the app's InnerTube.swift flow (web config, search, /player for each
client, then a 2-byte range request on the chosen audio URL) using only the
standard library, so a failure in the simulator test can be told apart from a
network/IP block on the runner.

Usage: python3 ios/ci/probe_stream.py "search query"
"""

import json
import re
import sys
import urllib.error
import urllib.request

WEB_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0"
CONSENT = "SOCS=CAESEwgDEgk2ODE4NDk5NzAaAmVuIAEaBgiA_LyaBg; CONSENT=YES+cb.20210328-17-p0.en+FX+999"
CLIENTS = [
    ("VISIONOS", "0.1", "101",
     "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
     {"osName": "visionOS", "osVersion": "1.3.21O771", "deviceMake": "Apple", "deviceModel": "RealityDevice14,1"}),
    ("ANDROID_VR", "1.65.10", "28",
     "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
     {"osName": "Android", "osVersion": "12", "deviceMake": "Oculus", "deviceModel": "Quest 3", "androidSdkVersion": "32"}),
    ("IOS", "21.26.4", "5",
     "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2;)",
     {"osName": "iPhone", "osVersion": "18.3.2.22D82", "deviceMake": "Apple", "deviceModel": "iPhone16,2"}),
]


def fetch(url, data=None, headers=None, timeout=15):
    request = urllib.request.Request(url, data=data, headers=headers or {})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.headers, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.headers, error.read()


def config_value(html, key):
    match = re.search(r'"%s"\s*:\s*"([^"]+)"' % key, html)
    return match.group(1).replace("\\u003d", "=") if match else None


def main():
    query = sys.argv[1] if len(sys.argv) > 1 else "Daft Punk Get Lucky"
    status, _, body = fetch("https://music.youtube.com/", headers={"User-Agent": WEB_UA, "Cookie": CONSENT})
    html = body.decode("utf-8", "replace")
    key = config_value(html, "INNERTUBE_API_KEY")
    version = config_value(html, "INNERTUBE_CONTEXT_CLIENT_VERSION")
    visitor = config_value(html, "VISITOR_DATA") or config_value(html, "visitorData") or config_value(html, "EOM_VISITOR_DATA")
    print(f"config: HTTP {status} key={'yes' if key else 'no'} version={version} visitor={'yes' if visitor else 'no'}")

    search_body = {
        "context": {"client": {"clientName": "WEB_REMIX", "clientVersion": version, "hl": "en", "gl": "US", "visitorData": visitor}},
        "query": query,
        "params": "EgWKAQIIAWoKEAkQBRAKEAMQBA==",
    }
    status, _, body = fetch(
        f"https://music.youtube.com/youtubei/v1/search?key={key}&prettyPrint=false",
        json.dumps(search_body).encode(),
        {"Content-Type": "application/json", "User-Agent": WEB_UA, "Origin": "https://music.youtube.com",
         "X-YouTube-Client-Name": "67", "X-YouTube-Client-Version": version or "", "X-Goog-Visitor-Id": visitor or ""},
    )
    match = re.search(r'"videoId":\s*"([\w-]{11})"', body.decode("utf-8", "replace"))
    video_id = match.group(1) if match else None
    print(f"search: HTTP {status} first videoId={video_id}")
    if not video_id:
        return

    for name, client_version, client_id, user_agent, extra in CLIENTS:
        context = {"clientName": name, "clientVersion": client_version, "hl": "en", "gl": "US", "visitorData": visitor, **extra}
        status, _, body = fetch(
            "https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
            json.dumps({"context": {"client": context}, "videoId": video_id, "contentCheckOk": True, "racyCheckOk": True}).encode(),
            {"Content-Type": "application/json", "User-Agent": user_agent, "X-YouTube-Client-Name": client_id,
             "X-YouTube-Client-Version": client_version, "X-Goog-Visitor-Id": visitor or "", "Origin": "https://www.youtube.com"},
        )
        try:
            player = json.loads(body)
        except ValueError:
            print(f"{name}: player HTTP {status}, non-JSON body")
            continue
        playability = player.get("playabilityStatus", {})
        streaming = player.get("streamingData", {})
        audio = [f for f in streaming.get("adaptiveFormats", []) if f.get("mimeType", "").startswith("audio/mp4") and "url" in f]
        line = f"{name}: player HTTP {status} status={playability.get('status')} reason={playability.get('reason')} mp4-audio={len(audio)} hls={'yes' if streaming.get('hlsManifestUrl') else 'no'}"
        media_headers = {"User-Agent": user_agent, "X-Goog-Visitor-Id": visitor or ""}
        if audio and name != "IOS":
            best = sorted(audio, key=lambda f: (f.get("itag") != 140, -f.get("bitrate", 0)))[0]
            length = int(best.get("contentLength") or 0)
            ranges = [("range 0-1", "bytes=0-1"), ("1MB chunk", "bytes=0-1048575"), ("open range", "bytes=0-")]
            if length:
                ranges.append(("full bounded range", f"bytes=0-{length - 1}"))
            for label, byte_range in ranges:
                media_status, headers, _ = fetch(best["url"], headers={**media_headers, "Range": byte_range}, timeout=15)
                line += f" | {label}: HTTP {media_status} {headers.get('Content-Type') if headers else ''}"
        if streaming.get("hlsManifestUrl"):
            media_status, _, _ = fetch(streaming["hlsManifestUrl"], headers=media_headers)
            line += f" | hls manifest: HTTP {media_status}"
        print(line)


if __name__ == "__main__":
    main()
