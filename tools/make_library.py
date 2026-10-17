#!/usr/bin/env python3
"""Writes Sources/CoLearner/library.json, the library bundled with the app. It is empty, so a new install starts with
no courses: sections are made on the lecture page (New Section, then + to link a folder of slides).

A personal library (course folders, nicer deck titles, the study pages and notes that belong to each deck) goes in
~/Library/Application Support/Co-learner/library.json, which the app reads before the bundled one. Its format is
LibraryFile in Sources/CoLearner/Library.swift."""
import json, os

OUT = os.path.join(os.path.dirname(__file__), "..", "Sources", "CoLearner", "library.json")
json.dump({"version": 1, "courses": [], "decks": {}}, open(OUT, "w"), indent=1)
print(f"wrote {os.path.normpath(OUT)}: empty library")
