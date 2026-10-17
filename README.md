# Co-learner

A Mac app for reviewing lecture slides with an AI tutor next to them. Version 0.1.

- **Left:** the lecture slides. The bar on top holds the lecture picker and the open decks as tabs; the strip at the bottom holds slide thumbnails.
- **Right, Chat tab:** ask about the slide on screen. The first question on a slide sends the slide image, its text and the text of the slides around it automatically. Pick **Claude**, **ChatGPT**, or **Both** (two answers to compare).
- **Right, Walkthrough tab:** the walkthrough or review page for this deck, scrolled to the section for the current slide. For decks with typed LaTeX notes it also offers those notes (PDF), opened at the page that shows the current slide.

Each slide keeps its own conversation. Follow-ups continue the same conversation, and the slide's old Q&A is still there when you come back. An orange dot on a thumbnail means that slide has a chat.

Claude and ChatGPT share the slide's conversation: when you ask one of them, it is also shown whatever it hasn't seen yet (the other one's answers, or questions you sent only to the other one), so "ChatGPT says 2 solutions, you say 4 — who's right?" works. Each assistant is only "busy" for itself: in Both mode you can follow up with Claude while ChatGPT is still writing.

## Using it

| Action | How |
|---|---|
| Open a lecture | **Lectures** menu (top left) or the list on the start screen. Any other PDF: ⌘O |
| Next / previous slide | ⌘] / ⌘[ , arrow keys when the slide has focus, or click a thumbnail |
| Ask | type and press Enter (Shift+Enter for a new line), or use the buttons: *Explain this slide*, *Visualize it*, *Derive step by step* |
| Jump to the chat box | ⌘L |
| Chat / Walkthrough tab | ⌘1 / ⌘2 |
| Stop an answer | the red **Stop** button |
| Visuals | "Visualize it" answers come with a live interactive drawing; **Open in window** shows it bigger; **Code** shows the source |
| Model and effort | Co-learner ▸ Settings (⌘,) |

## First launch

If a linked folder is on your Desktop, macOS asks once whether Co-learner may access files there. Click **Allow**. Because the app is not signed with a developer certificate, macOS asks again after each update.

## How it talks to Claude and ChatGPT

No API keys. The app runs the command-line tools that are already logged in on this Mac:

- **Claude:** Claude Code in headless mode (`claude -p`, streamed JSON). The app picks the newest copy it can find, including the one the Claude desktop app keeps up to date. Opus 5.5 needs Claude Code 2.1.280 or newer. It runs with its own system prompt, no MCP servers, no settings or memory files, and read-only tools (Read, Grep, Glob). It is told which files belong to the deck (walkthrough page, typed lecture notes `.tex`, lecture transcripts) and reads them when a question needs more than the slide; deny rules keep it out of the handwritten scans (`*inclass*`, `*_scribing_*.pdf`).
- **ChatGPT:** the Codex CLI (`codex exec --json`), using the ChatGPT login, read-only sandbox, shell tools and web search off. Default model `gpt-6-astra`, reasoning effort medium.

Each slide's conversation keeps one Claude session and one Codex thread, resumed for follow-ups.

## Files

| What | Where |
|---|---|
| Chats (one JSON file per deck) | `~/Library/Application Support/Co-learner/chats/` |
| Links you add with the 🔗 button | `~/Library/Application Support/Co-learner/links.json` |
| Your own library override (optional) | `~/Library/Application Support/Co-learner/library.json` |
| Rendered slide images sent to the assistants | `~/Library/Caches/Co-learner/slides/` |

## The library

`tools/make_library.py` writes `Sources/CoLearner/library.json`: the slide folder of each course, nicer deck titles, which walkthrough/review pages and notes belong to which deck, and per-deck settings. New PDFs in a course's slide folder appear on their own; re-run the script (the build does it) to link new walkthrough pages.

- Courses whose library.json `layout` is `twoUp` (handouts with two slides per page): the app splits those PDFs so that slide numbers match the printed ones.
- A replaced deck: library.json can hide the old deck (`"hidden": true`) and keep its walkthrough linked to the new deck through a page map (`map`).
- Walkthrough sections are found by `Web/walkthrough_index.js`, which reads the slide references in each page (eyebrows, headings, `data-pages`, source pills) and scrolls to the most specific section for the slide.
- Scribe-notes PDFs need no table: pdfTeX stamps each slide crop with its deck file and page (`/PTEX.FileName`, `/PTEX.PageNumber`), and `ScribeMap.swift` reads those.

## Building

Needs only the Command Line Tools (no Xcode):

```bash
scripts/build_app.sh --install
```

This builds `build/Co-learner.app` and copies it to `~/Applications`. For a quick debug run: `swift run`.

Note: SwiftUI's `@State` is a macro in the macOS 27 SDK and its plugin ships only with Xcode, so the code avoids `@State`.

## Layout

| File | Role |
|---|---|
| `App.swift` | app entry, menus, Settings |
| `AppModel.swift` | open decks, current slide, 2-up splitting, thumbnails |
| `MainView.swift` | window layout, lecture bar, right panel |
| `SlidesView.swift` | PDFKit slide view and thumbnail strip |
| `ChatController.swift` | chat web view bridge, sending, streaming, stop |
| `Backends.swift` | Claude Code and Codex runners and their JSON parsers |
| `ProcessRunner.swift` | child processes and line-by-line output |
| `SlideContext.swift` | slide PNG and text sent with the first question |
| `ChatStore.swift` | chat history on disk |
| `WalkthroughPane.swift` | walkthrough tab (html pages) |
| `StudyPDF.swift`, `ScribeMap.swift` | notes PDFs in the walkthrough tab, slide → notes page |
| `Prompts.swift` | the tutor instructions |
| `Web/` | chat page (`chat.html/css/js`, `render.js`), section indexer (`walkthrough_index.js`), vendored KaTeX, marked and DOMPurify |

## Changelog

- **0.1** (2026-10-17): first version. Reviewed by four independent reviewers (Swift core, UI/model, chat page with 103 browser tests, requirements) with adversarial verification; all confirmed findings fixed before release (two-up slide image and text, deck-switch slide, notes map, chat-page sandbox and sanitizing, partial answers on quit, session handling).
