# Co-learner

A Mac app for reviewing lecture slides with an AI tutor next to them. Version 0.1.8.

- **Left:** the lecture slides. The bar on top holds the lecture picker and the open decks as tabs (browser-style: + or ⌘T for a New Tab); the strip at the bottom holds slide thumbnails.
- **Right, Chat tab:** one conversation per lecture deck, with Claude, ChatGPT, or Both. Move through the slides and keep asking: the assistants remember the conversation, and each message tells them which slide you're on.
- **Right, Walkthrough tab:** the walkthrough or review page for this deck, scrolled to the section for the current slide. For decks with typed LaTeX notes it also offers those notes (PDF), opened at the page that shows the current slide.

### How the chat works

- **What the assistants get.** A new conversation starts with the text of every slide (cheap) and the image of the slide you're on. Afterwards each question is tagged "you're on slide N"; a slide's image is attached the first time it comes up, and so are slides you mention ("compare with slide 3", "slides 5–8"). Claude can also open any slide image itself.
- **What you see.** *This slide* shows what you asked on the slide on screen; *All* shows the whole conversation with a slide tag on each question (click it to jump). "Also asked on slides" and orange dots on the thumbnails show where you asked before.
- **Buttons.** *Explain this slide* and *Visualize this slide* are one click for the whole slide. **✂︎ Select area** (or ⌥-drag on the slide, or ⌘⇧A) lets you drag a box over part of a slide like a screenshot; the cut-out goes with your next question, and the buttons become *Explain this area* / *Visualize this area*.
- **New chat / History.** *New chat* starts a fresh conversation about the deck (long ones get slower and use more of your limits); *History* switches between earlier ones or deletes them. Chats from before v0.1.5 (one per slide) were gathered into one conversation marked "per-slide chats"; the old per-slide file `<name>-<hash>.json` is left unchanged (older versions still read it), and the new conversations are saved in `<name>-<hash>.chat2.json`.
- Claude and ChatGPT share the conversation: each is shown what the other said that it hasn't seen yet. Each assistant is only "busy" for itself.
- **Search.** *Search* (⇧⌘F) finds text across saved conversations in every deck, including closed decks and older per-slide chats. Words match regardless of case or accents; results show the deck, slide and matching excerpt, newest first (up to 100). Click a result to reopen its conversation and slide and highlight the message in *All*. Searching does not alter saved chats. A moved or missing PDF must be restored before its result can open.
- **Slide references.** References such as “slide 12” or “slides 3 and 5” in an assistant's answer are clickable when they name valid app slide numbers. Clicking one opens that slide while keeping the answer visible in *All*. Range endpoints are clickable; code, equations and existing web links are left alone. References use the app's numbering, which may differ from printed slide footers.

## Using it

| Action | How |
|---|---|
| Open a lecture | **Lectures** menu (top left) or the list on the start screen. Any other PDF: ⌘O |
| Tabs | **+** after the tabs or ⌘T opens a New Tab with the lecture list; picking a lecture there opens it in that tab. Click a tab to switch; × or ⌘W closes the tab on screen. Each deck remembers its slide |
| Next / previous slide | → / ← (anywhere, except while typing in the chat box or using a visual or slider), ⌘] / ⌘[ , or click a thumbnail |
| Ask | type and press Enter (Shift+Enter for a new line), or *Explain this slide* / *Visualize this slide*. Esc leaves the chat box (so ← → turn slides again) |
| Ask about part of a slide | **✂︎ Select area** under the chat, ⌥-drag on the slide, or ⌘⇧A; drag a box; Esc cancels. The buttons become *Explain this area* / *Visualize this area* |
| See the conversation | *This slide* / *All* at the top of the chat; *History* for earlier chats; *New chat* for a fresh one |
| Find an earlier answer | **Search** at the top of the chat, or ⇧⌘F; type words and click a result to open its deck, conversation and slide |
| Follow a slide reference | click an underlined slide number in an assistant's answer |
| Model and effort | click the model button next to Claude / ChatGPT / Both (e.g. "● Opus 5.5 Medium ⌄"): pick a model and slide the effort (also in Settings ⌘,). **Choose models…** picks which models the menu shows; new models appear by themselves (marked *New* for a week). ChatGPT also has a **Fast mode** toggle; the selector and answers show *Fast* when enabled. Each answer is labelled with the model and effort it used |
| Plan usage | bottom right of the chat shows the short version; click it for the usage card: Claude's current session, week (all models) and week (Fable) with bars and reset times, and ChatGPT's limits, with your plan names. The card refreshes when opened (if older than 2 minutes) and with ↻; it also updates after every answer |
| Link / unlink a walkthrough or notes PDF | Walkthrough tab › 🔗 menu: **Link a walkthrough page or notes PDF…**, **Unlink "…"** for each page, **Link again** for pages you unlinked. A page you link syncs to the slides right away (HTML pages through their slide references, notes PDFs through their slide stamps). Unlinked pages stay out even if they are found again; unlinking a notes PDF also stops Claude reading its .tex |
| Light / Dark / Automatic | the ☀︎ / ☾ button at the right of the top bar, View › Appearance, or Settings |
| Jump to the chat box | ⌘L |
| Chat / Walkthrough tab | ⌘1 / ⌘2 |
| Pop out Chat or Walkthrough (e.g. onto an iPad as a second screen) | the ⧉ button at the right of the panel header, or Slides › Pop Out Chat (⌥⌘1) / Pop Out Walkthrough (⌥⌘2). The first time, a pop-out goes to another screen if one is connected (both share it, Chat on the left); after that each window remembers where it was. With both out, the slides fill the window. **Put back** in the window's title bar, its close button or ⌘W docks it again; pop-outs left open come back at the next launch |
| Slides / right panel width | opens at 3 : 2 every launch; drag the divider, double-click it to go back to 3 : 2 |
| Stop an answer | the red **Stop** button (stops answers still running in this chat, on any slide) |
| Visuals | "Visualize" answers come with a live interactive drawing; **Open in window** shows it bigger; **Code** shows the source |

## First launch

If a linked folder is on your Desktop, macOS asks once whether Co-learner may access files there. Click **Allow**.

**Signing.** `scripts/build_app.sh` signs the app with a private certificate, "Co-learner Local Signing", kept in the login keychain of this Mac. macOS remembers the Desktop permission by the bundle ID (`com.yifeidai.colearner`) plus that certificate, so it survives rebuilds and renaming the app. Without the certificate the script signs ad-hoc, and macOS asks again after every rebuild. To recreate the certificate on another Mac: make a self-signed certificate with the Code Signing extended key usage named exactly "Co-learner Local Signing" (Keychain Access › Certificate Assistant › Create a Certificate, type Code Signing, or openssl + `security import … -T /usr/bin/codesign`); no trust change is needed.

## How it talks to Claude and ChatGPT

No API keys. The app runs the command-line tools that are already logged in on this Mac:

- **Claude:** Claude Code in headless mode (`claude -p`, streamed JSON). The app picks the newest copy it can find, including the one the Claude desktop app keeps up to date. Opus 5.5 needs Claude Code 2.1.280 or newer. It runs with its own system prompt, no MCP servers, no settings or memory files, and read-only tools (Read, Grep, Glob). It is told which files belong to the deck (walkthrough page, typed lecture notes `.tex`, lecture transcripts) and reads them when a question needs more than the slide; deny rules keep it out of the handwritten scans (`*inclass*`, `*_scribing_*.pdf`).
- **ChatGPT:** the Codex CLI (`codex exec --json`), using the ChatGPT login, read-only sandbox, shell tools and web search off. Default model `gpt-6-astra`, reasoning effort medium. **Fast mode** in the model selector or Settings requests faster processing with the same model and effort, using plan limits faster. It is off by default, remembered between launches, and applies to the next question, including follow-ups in an existing chat. The CLI is explicitly given `service_tier=fast` or `service_tier=default` so switching it off also restores standard speed on resumed chats. See [Codex speed settings](https://learn.chatgpt.com/docs/agent-configuration/speed).

Each conversation (one per deck) keeps one Claude session and one Codex thread, resumed for follow-ups.

## Files

| What | Where |
|---|---|
| Chats (`<name>-<hash>.chat2.json` per deck; `<name>-<hash>.json` is the pre-0.1.5 per-slide file, left as it was) | `~/Library/Application Support/Co-learner/chats/` |
| Links you add with the 🔗 button | `~/Library/Application Support/Co-learner/links.json` |
| Your own library override (optional) | `~/Library/Application Support/Co-learner/library.json` |
| Rendered slide images sent to the assistants | `~/Library/Caches/Co-learner/slides/` |

## The library

`tools/make_library.py` writes `Sources/CoLearner/library.json`: the slide folder of each course, nicer deck titles, which walkthrough/review pages and notes belong to which deck, per-deck settings, and each course's study folders.

New things are found on their own at launch (or Lectures › Reload library, ⇧⌘R):
- **New slide PDFs** in a course's slide folder.
- **New notes PDFs** in a study folder (e.g. `notes/L06_notes.pdf`): matched exactly through the deck name and slide number pdfTeX stamps on every slide crop; a `.tex` with the same name is offered to Claude.
- **New walkthrough/review pages** in a study folder (`output/walkthrough`, `output/quiz-review`, `output/mindmap`): matched by the deck codes on the page ("decks 03a and 03b", "W7L1"), "Lecture N", or the title's words against the deck titles. Checked on the author's library at the time: discovery alone found all 29 links, with nothing missing or extra.
- Anything else: the 🔗 menu in the Walkthrough tab links a page by hand, and unlinks any page (listed, found, or linked) for that deck. Hand links and unlinks live in `links.json`.

- Courses whose library.json `layout` is `twoUp` (handouts with two slides per page): the app splits those PDFs so that slide numbers match the printed ones. `FrameDetector.swift` measures where the two slides sit in each deck when it opens (it votes over the first pages; the slide is a block of columns with one long dark run, or its border lines when the slide is light), so a new deck with a slightly different layout is still cut at the slide borders. library.json's frames are only the fallback. Checked on 10 two-up decks: every page agreed with the detected frames.
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

## Testing

Run `scripts/test.sh` on macOS with the Command Line Tools. The Swift Testing suite uses temporary chats and PDFs, fake CLI executables, and a nonpersistent WebKit fixture. It never sends questions to a live AI service or changes your saved chats. XCTest and Xcode are not required. To run one suite, for example: `scripts/test.sh --filter ChatContextTests`.

Version 0.1.8 has 47 tests across nine suites. Fast mode coverage checks CLI tiers for new and resumed chats, selector on/off messages, keyboard focus, streaming redraws, and narrow-panel layout. Search coverage includes unopened decks, legacy migration and deleted-chat handling, unsaved messages, matching and result limits, stale replies, failed-open retries, and revealing the selected message. Slide-reference tests exercise the actual sanitized chat renderer, click messages, bounds and deck/conversation validation, streamed updates, and preservation of code, equations and web links. Both interfaces are checked at a 420px panel width. Set `COLEARNER_TEST_SNAPSHOTS=1` when running the suite to save search and citation previews under `/tmp/colearner-v017-*.png` and the Fast mode preview at `/tmp/colearner-v018-fast-mode.png`.

## Reliability review (2026-10-18)

The six findings below are fixed and covered by regression tests:

| Finding | Fix and regression coverage |
|---|---|
| A partial ChatGPT answer could be marked successful after a failed CLI exit. | Require `turn.completed`; preserve partial text and report incomplete turns. Backend tests cover clean/error exits, explicit errors, retries, and cancellation before/after completion. |
| Crash recovery retained context markers for turns the assistant might never have received. | Clear the interrupted provider's session and seen markers, preserving messages and the other provider. Recovery tests reopen real saved chat files and verify the repaired state persists. |
| Replaced slides and linked/unlinked notes did not refresh existing assistant sessions. | Persist a source revision per provider; changed sources cancel affected runs and rebuild context on the next question. Reload changed PDFs and invalidate slide-image/thumbnail caches. Tests cover saved sessions, revisions with restored timestamps, link/unlink/edit operations, and unchanged-source resumes. Older unversioned sessions refresh once; chat history is retained. |
| Rebuilt notes PDFs retained outdated slide-to-page maps and displayed pages. | Version both the mapping cache and the displayed PDF. Real PDF fixtures cover replacement, shared notes, newly referenced decks, deletion, incomplete builds, and recovery. Use **Reload library** after rebuilding notes. |
| Walkthrough arrow handling also turned slides while operating interactive visuals. | Let widgets handle keys first; respect handled events and focusable visuals. Execute the actual injected JavaScript against widget and ordinary-page key cases. |
| A delayed walkthrough scroll could run after switching decks or pages. | Cancel queued work and reject callbacks from older selections/navigation. Controller tests cover page switches, shared HTML with different deck metadata, clearing, and disabling Follow slides. |

Verified on 2026-10-18: all 23 tests across four suites passed, and the optimized release build succeeded. These tests exercise local protocol and UI behavior with controlled fixtures; live Claude/ChatGPT service availability is outside their scope.

## Layout

| File | Role |
|---|---|
| `App.swift` | app entry, menus, Settings |
| `AppModel.swift` | open decks, current slide, 2-up splitting, thumbnails |
| `MainView.swift` | window layout, lecture bar, right panel |
| `Panels.swift` | the slides / right-panel split (3 : 2), hosting the shared panel views, Chat / Walkthrough pop-out windows |
| `HoverStyles.swift` | hover highlights for the tab bar's small buttons and menus |
| `SlidesView.swift` | PDFKit slide view and thumbnail strip |
| `ChatController.swift` | chat web view bridge, sending, streaming, stop |
| `Backends.swift` | Claude Code and Codex runners and their JSON parsers |
| `ProcessRunner.swift` | child processes and line-by-line output |
| `SlideContext.swift` | slide and area images, the deck header a new conversation gets, slide numbers mentioned in a question |
| `ChatStore.swift` | conversations per deck on disk (and the v1 → v2 migration) |
| `ChatSearch.swift`, `ChatNavigation.swift` | read-only search of saved chats, result resolution and slide-link validation |
| `WalkthroughPane.swift` | walkthrough tab (html pages) |
| `StudyPDF.swift`, `ScribeMap.swift` | notes PDFs in the walkthrough tab, slide → notes page |
| `StudyDiscovery.swift` | finds study pages and notes made later and matches them to decks |
| `Prompts.swift` | the tutor instructions |
| `ModelCatalog.swift` | live model lists (Claude Code / Codex), shown/hidden models, effort levels; usage windows |
| `UsageFetcher.swift` | on-demand plan usage (Claude `/usage`, Codex app-server) |
| `FrameDetector.swift` | finds the two slide frames on 2-up handout pages |
| `Web/` | chat page (`chat.html/css/js`, `render.js`), section indexer (`walkthrough_index.js`), vendored KaTeX, marked and DOMPurify |

## Changelog

- **0.1.8** (2026-10-18): add a saved Fast mode toggle to the ChatGPT model selector and Settings, with Fast labels on the selector and answers. Keeps model and reasoning effort unchanged and explicitly applies Fast or standard speed to new and resumed turns. Includes offline CLI and WebKit coverage.
- **0.1.7** (2026-10-18): search saved chats across decks with ⇧⌘F, matching excerpts and direct navigation to the conversation, slide and highlighted message. Click slide references in assistant answers to see their source while keeping the answer visible. Includes offline search, navigation and real WebKit regression coverage.
- **0.1.6** (2026-10-18): six reliability fixes for incomplete ChatGPT answers, crash recovery, refreshed assistant context after source changes, rebuilt notes PDFs, interactive walkthrough keyboard controls, and delayed scrolling across deck switches. Adds 23 offline regression tests across four suites; optimized release build verified. See the reliability review above for findings and coverage.
- **0.1.5** (2026-10-17): one conversation per deck (deck text up front, slide images on demand, slides you mention attached, This slide / All view, New chat, History); select an area of a slide and ask about it; buttons cut to Explain and Visualize. Per-slide chats migrate into one conversation. Light / Dark / Automatic appearance switch. Browser-style tabs (+ / ⌘T New Tab with the lecture list, ⌘W closes a tab, tabs sized to their titles) with hover highlights on +, ×, the slide arrows and the menus; the Lectures menu lists deck names only. Slides and the right panel open at 3 : 2 (custom divider; double-click resets). Chat and Walkthrough can pop out into their own windows (for an iPad second screen), follow the slides there, dock back on close, and reopen at launch. Stop only stops the assistants being asked, and the answer shows "stopping…" until that assistant has really stopped (no new question can race it); a stopped or failed answer no longer counts as "seen" by that assistant; more ways to name slides ("slide #4", "pg 12", "3 through 6"). Builds are signed with a local certificate, so macOS keeps the Desktop permission across updates; the build script stops on a failed build.
- **0.1.4** (2026-10-17): link and unlink study pages per deck from the Walkthrough tab (🔗 menu), with Link again; hand-linked pages of two-up decks use the split-slide numbering. Tested with the real library loader on a scratch settings folder (11/11).
- **0.1.3** (2026-10-17): walkthrough pages and notes PDFs made later are found automatically (StudyDiscovery.swift).
- **0.1.2** (2026-10-17): model lists come from the tools and refresh at every launch (and with *Refresh list*): Claude Code's aliases resolved with `/model <alias>`, effort levels from `claude --help`, Codex's `model/list`. Choose which models the menu shows; *New* badge for new models (and when an alias like "opus" starts meaning a newer model); effort is a slider; no model descriptions. A refresh that comes back partial or offline (Codex's built-in presets) is not applied; the plan's list comes from Codex's own cache, which model/list refreshes. Reviewed (2 reviewers + verifiers): model buttons no longer get rebuilt while an answer streams (clicks were lost), the effort slider keeps keyboard focus and drags across redraws.
- **0.1.1** (2026-10-17): model and effort menu, click-to-open usage card refreshed on demand (`claude -p /usage`, Codex app-server rate limits), ← → turn slides, 2-up slide frames measured per deck, chat page no longer scrolls away.
- **0.1** (2026-10-17): first version. Reviewed by four independent reviewers (Swift core, UI/model, chat page with 103 browser tests, requirements) with adversarial verification; all confirmed findings fixed before release (two-up slide image and text, deck-switch slide, notes map, chat-page sandbox and sanitizing, partial answers on quit, session handling).
