#!/usr/bin/env python3
"""Generate a single image via the Gemini API (gemini-2.5-flash-image) and save it as PNG.

Usage:
    python3 scripts/generate-gemini-image.py "<prompt>" <output-path> [--aspect-ratio 16:9]

Reads GEMINI_API_KEY from the repo-root .env file.
"""
import argparse
import base64
import os
import sys

import requests

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENV_PATH = os.path.join(REPO_ROOT, ".env")
MODEL = "gemini-2.5-flash-image"


def load_env(path):
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prompt", help="Image generation prompt")
    parser.add_argument("output_path", help="Where to save the resulting PNG")
    parser.add_argument("--aspect-ratio", default="16:9", help="e.g. 16:9, 1:1, 4:5")
    args = parser.parse_args()

    env = load_env(ENV_PATH)
    api_key = env.get("GEMINI_API_KEY")
    if not api_key:
        print("GEMINI_API_KEY not found in .env", file=sys.stderr)
        sys.exit(1)

    url = f"https://generativelanguage.googleapis.com/v1beta/models/{MODEL}:generateContent"
    resp = requests.post(
        url,
        headers={"x-goog-api-key": api_key, "Content-Type": "application/json"},
        json={
            "contents": [{"parts": [{"text": args.prompt}]}],
            "generationConfig": {"imageConfig": {"aspectRatio": args.aspect_ratio}},
        },
        timeout=120,
    )

    if resp.status_code != 200:
        print(f"HTTP {resp.status_code}: {resp.text[:2000]}", file=sys.stderr)
        sys.exit(1)

    data = resp.json()
    candidates = data.get("candidates", [])
    if not candidates:
        print(f"No candidates returned: {data}", file=sys.stderr)
        sys.exit(1)

    parts = candidates[0].get("content", {}).get("parts", [])
    for part in parts:
        inline = part.get("inlineData") or part.get("inline_data")
        if inline:
            img_bytes = base64.b64decode(inline["data"])
            with open(args.output_path, "wb") as f:
                f.write(img_bytes)
            print(f"Saved image to {args.output_path} ({len(img_bytes)} bytes)")
            return
        elif "text" in part:
            print("Model text response:", part["text"][:500])

    print("No image data found in response.", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()
