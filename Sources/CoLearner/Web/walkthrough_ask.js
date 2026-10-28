/* walkthrough_ask.js  (Co-learner v0.1.9)
 *
 * Injected into every study page after walkthrough_index.js (WKUserScript at .atDocumentEnd, main frame only).
 * Asking the chat about part of the page:
 *   - select text or a formula and a small "Ask about this" button appears next to it, off the page's controls when
 *     it can be; a click posts {kind: "selection", text, section} to the app (message handler "clask"). Sent away
 *     (a click elsewhere, Esc, the app), it stays away until the selection changes;
 *   - __coLearnerAsk.collect({hide?}) -> the selection as above when part of it is on screen, or else the section
 *     being read, {kind: "section", text, section}: the indexed entry about a third of the way down the view (below
 *     the sticky top bar), whole, or when it is too long for that and its top is scrolled away, its title, a "…" line
 *     and its text from the first block on screen. null if neither. The Walkthrough tab's Ask button and Slides ›
 *     Ask About Walkthrough use it.
 *   - __coLearnerAsk.hide() -> hides the button (before the app snapshots an area) until the selection changes.
 *   - __coLearnerAsk.sectionAt(x, y) -> the section path at a point of the view ("" if none), for a captured area.
 *   - __coLearnerAsk.crosshair(on) -> a crosshair cursor everywhere while the app drags out an area.
 *   - __coLearnerAsk.textOf(range | node), sectionOf(node) -> the extraction and the path below (also for tests).
 * "text" keeps math as TeX ($...$ and $$...$$ from MathJax 3's own records, KaTeX's TeX annotation; <sup>/<sub> as
 * ^{...}/_{...}), skips hidden parts, form fields and figures, keeps button text (an answer choice reads "A. ..."),
 * and puts each block on its own line (a button's flex items share one). A quote that uses the page's own MathJax
 * macros (\tp, \Rot, ...) ends with a line defining them. "section" is the path of titles the app's "Showing: ..."
 * line uses (__coLearnerWT.entryAt), joined with " › "; mind maps have none.
 */
(function () {
  "use strict";
  var VERSION = "0.1.9";
  if (window.__coLearnerAsk && window.__coLearnerAsk.version === VERSION) return;

  var MAX_SELECTION = 8000, MAX_SECTION = 6000;

  /* ---------------- text, with math as TeX ---------------- */
  /* not read: code, media, drawings and form fields (button text is: answer choices are buttons) */
  var SKIP = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, SVG: 1, CANVAS: 1, IFRAME: 1, VIDEO: 1, AUDIO: 1,
    IMG: 1, INPUT: 1, TEXTAREA: 1, SELECT: 1, "MJX-ASSISTIVE-MML": 1 };

  /* MathJax 3 keeps every formula it typeset (startup.document.math, an iterable linked list):
     typesetRoot (the mjx-container) -> {math: TeX, display} */
  function mathJaxItems() {
    var map = new Map();
    var M = window.MathJax, doc = M && M.startup && M.startup.document, list = doc && doc.math;
    if (!list) return map;
    var items = [];
    try { items = Array.from(list); } catch (e) { return map; }
    for (var i = 0; i < items.length; i++) {
      var it = items[i];
      if (it && it.typesetRoot && it.typesetRoot.nodeType === 1 && typeof it.math === "string") map.set(it.typesetRoot, it);
    }
    return map;
  }

  function isFormula(el) {
    var tag = el.tagName.toUpperCase();
    return tag === "MJX-CONTAINER" || tag === "MATH" || el.classList.contains("katex");
  }
  /* the formula a node sits in (a selection made inside one takes all of it) */
  function formulaRoot(el) {
    return el.closest("mjx-container") || el.closest(".katex") || el.closest("math");
  }
  /* MathJax's record of the TeX, else a TeX annotation (KaTeX, MathML), else the formula's spoken text */
  function formula(el, mj) {
    var it = mj.get(el);
    if (it) return { tex: String(it.math).trim(), display: !!it.display };
    var d = el.getAttribute("display");
    var ann = el.querySelector('annotation[encoding="application/x-tex"]');
    if (ann) return { tex: ann.textContent.trim(), display: d === "true" || d === "block" || !!el.closest(".katex-display") };
    var mml = el.tagName.toUpperCase() === "MATH" ? el : el.querySelector("mjx-assistive-mml, math");
    return { tex: "", plain: mml ? mml.textContent : "" };
  }

  function rendered(el, cs) {
    if (cs.display === "none" || cs.visibility === "hidden" || cs.visibility === "collapse") return false;
    var up = el.parentElement;
    if (up && up.tagName === "DETAILS" && !up.open && el.tagName !== "SUMMARY") return false;   /* folded away */
    return cs.display === "contents" || el.getClientRects().length > 0;
  }
  /* A button laid out as a flex row (an answer choice: its key, then its text) reads as one line. Elsewhere each
     flex item keeps a line of its own: the items of legends, chip rows and control rows would run together. */
  function isRow(el, cs) {
    return el.tagName === "BUTTON" && /flex$/.test(cs.display) && !/^column/.test(cs.flexDirection);
  }
  function listMark(li, cs) {
    if (cs.display !== "list-item" || cs.listStyleType === "none") return "";
    var list = li.parentElement;
    if (!list || list.tagName !== "OL") return "- ";
    var n = parseInt(list.getAttribute("start"), 10);
    n = isNaN(n) ? 1 : n;
    for (var s = li.previousElementSibling; s; s = s.previousElementSibling) if (s.tagName === "LI") n++;
    return n + ". ";
  }
  /* an answer choice's key: the lone letter or number before its text in a button ("A" reads "A. ...") */
  function isKey(el) {
    var b = el.parentElement;
    return !!b && b.tagName === "BUTTON" && !el.previousElementSibling && !!el.nextElementSibling &&
      /^\s*[A-Za-z0-9]\s*$/.test(el.textContent);
  }

  function finish(s, limit) {
    s = String(s || "").replace(/\u00a0/g, " ").replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
    if (s.length > limit) {
      var cut = s.slice(0, limit - 1), sp = cut.search(/\s\S*$/);
      if (sp > limit - 400) cut = cut.slice(0, sp);
      s = cut + "\u2026";
    }
    return s;
  }

  function nodeLength(n) { return n.nodeType === 1 ? n.childNodes.length : (n.nodeValue || "").length; }
  function climbable(n) { return n !== document.body && !!n.parentNode && n.parentNode.nodeType === 1; }
  /* A copy of `range` without ends that only touch a node: a triple click or a drag into the margin ends at the very
     start of the next block (whose display formula or list marker would come along), a drag from the margin starts
     at the very end of the previous one. */
  function tidy(range) {
    var r = range.cloneRange();
    while (!r.collapsed && r.endOffset === 0 && climbable(r.endContainer)) r.setEndBefore(r.endContainer);
    while (!r.collapsed && r.startOffset === nodeLength(r.startContainer) && climbable(r.startContainer)) {
      r.setStartAfter(r.startContainer);
    }
    return r;
  }

  /* The text of `range` as the reader sees it, at most `limit` characters. */
  function rangeText(range, limit) {
    range = tidy(range);
    var root = range.commonAncestorContainer;
    if (root && root.nodeType !== 1) root = root.parentNode;
    if (range.collapsed || !root || root.nodeType !== 1) return "";
    var mj = mathJaxItems(), out = "", full = false;

    function put(s) {
      if (full || !s) return;
      out += s;
      if (out.length > limit + 200) full = true;
    }
    function last() { return out.charAt(out.length - 1); }
    function text(s, pre) {
      if (!s) return;
      if (!pre) {
        s = s.replace(/\s+/g, " ");
        if (s.charAt(0) === " " && (!out || last() === " " || last() === "\n")) s = s.slice(1);
      }
      put(s);
    }
    function br() {
      if (!out || last() === "\n") return;
      out = out.replace(/ +$/, "");
      put("\n");
    }
    function space() {
      var c = last();
      if (out && c !== " " && c !== "\n") put(" ");
    }
    function math(el) {
      var f = formula(el, mj);
      if (!f.tex) { text(f.plain, false); return; }
      if (f.display) { br(); put("$$" + f.tex + "$$"); br(); }
      else put("$" + f.tex + "$");
    }
    /* <sup>/<sub> outside formulas: T<sup>−1</sup> reads T^{−1}, x<sub>a</sub> reads x_{a} */
    function script(el, pre, mark) {
      var at = out.length, was = full;
      walk(el, pre, false);
      var s = out.slice(at).replace(/^\s+|\s+$/g, "");
      out = out.slice(0, at);
      full = was;
      if (s) put(mark + "{" + s + "}");
    }
    /* `row`: el is an item of such a row (blockified, but side by side with the others) */
    function element(el, pre, row) {
      var tag = el.tagName.toUpperCase();
      if (tag === "BR") { put("\n"); return; }
      if (SKIP[tag] || el === host) return;
      var cs = getComputedStyle(el);
      if (!rendered(el, cs)) return;
      var d = cs.display;
      if (row && d !== "contents") space();
      if (isFormula(el)) { math(el); return; }
      var p = pre || /^(pre|break-spaces)/.test(cs.whiteSpace);
      if (tag === "SUP" || tag === "SUB") { script(el, p, tag === "SUP" ? "^" : "_"); return; }
      var cell = d === "table-cell", block = !row && !cell && !/^(inline|contents|ruby)/.test(d);
      if (cell) {
        if (el.previousElementSibling) { out = out.replace(/ +$/, ""); put(" | "); }
      } else if (block) {
        br();
        if (tag === "LI") put(listMark(el, cs));
      }
      walk(el, p, d === "contents" ? row : isRow(el, cs));
      if (row && isKey(el)) put(".");
      if (block) br();
    }
    function walk(node, pre, row) {
      for (var ch = node.firstChild; ch && !full; ch = ch.nextSibling) {
        if (!range.intersectsNode(ch)) continue;
        if (ch.nodeType === 3) {
          var t = ch.nodeValue;
          if (ch === range.endContainer) t = t.slice(0, range.endOffset);
          if (ch === range.startContainer) t = t.slice(range.startOffset);
          if (row && /\S/.test(t)) space();
          text(t, pre);
        } else if (ch.nodeType === 1) {
          element(ch, pre, row);
        }
      }
    }

    var f = formulaRoot(root);
    if (f) math(f);
    else {
      var cs = getComputedStyle(root);
      walk(root, /^(pre|break-spaces)/.test(cs.whiteSpace), isRow(root, cs));
    }
    return finish(out, limit);
  }

  function nodeText(node, limit) {
    var r = document.createRange();
    r.selectNodeContents(node);
    return rangeText(r, limit);
  }

  /* ---------------- the page's own TeX macros ---------------- */
  /* MathJax's tex.macros: in MathJax.config once MathJax has started, in window.MathJax (the config) before */
  function pageMacros() {
    var M = window.MathJax, tex = M && ((M.config && M.config.tex) || M.tex), defs = tex && tex.macros;
    return defs && typeof defs === "object" ? defs : null;
  }
  /* "Macros used above (defined by this page): \tp = ^{\top}; \bm{#1} = \boldsymbol{#1}" for the page's macros that
     `text` uses (and those their definitions use), or "" */
  function macroLine(text) {
    var defs = pageMacros(), seen = Object.create(null), used = [], queue = [text];
    if (!defs) return "";
    while (queue.length) {
      var s = queue.shift(), re = /\\([A-Za-z]+)/g, m;
      while ((m = re.exec(s))) {
        var name = m[1], d = Object.prototype.hasOwnProperty.call(defs, name) ? defs[name] : null;
        if (seen[name] || d == null) continue;
        seen[name] = true;
        var list = Array.isArray(d), body = list ? d[0] : d, n = list ? parseInt(d[1], 10) || 0 : 0, args = "";
        if (typeof body !== "string") continue;
        var opt = list && n > 0 && d.length > 2;   /* the first argument is optional, with a default */
        for (var k = 1; k <= n; k++) args += k === 1 && opt ? "[#1]" : "{#" + k + "}";
        used.push("\\" + name + args + " = " + body + (opt ? " ([#1] defaults to " + d[2] + ")" : ""));
        queue.push(body);
      }
    }
    return used.length ? "Macros used above (defined by this page): " + used.join("; ") : "";
  }
  /* `text` with that line at its end, within `limit` */
  function withMacros(text, limit) {
    var line = text ? macroLine(text) : "";
    if (!line) return text;
    if (line.length > limit / 4) line = finish(line, Math.floor(limit / 4));
    if (text.length + 2 + line.length > limit) text = finish(text, limit - 2 - line.length);
    return text + "\n\n" + line;
  }

  /* ---------------- where a node sits ---------------- */
  function entryAt(node) {
    var W = window.__coLearnerWT;
    if (!node || !W || typeof W.entryAt !== "function") return null;
    try { return W.entryAt(node); } catch (e) { return null; }
  }
  function pathText(at) {
    var p = at && at.path ? at.path.filter(function (t) { return !!t; }) : [];
    return p.join(" \u203a ");
  }
  /* a section, or a heading span (its heading up to the next heading of the same or a higher level) */
  function entryRange(at) {
    var r = document.createRange();
    if (at.kind === "heading" && at.block) {
      r.setStartBefore(at.el);
      if (at.end) r.setEndBefore(at.end); else r.setEnd(at.block, at.block.childNodes.length);
    } else {
      r.selectNodeContents(at.el);
    }
    return r;
  }
  /* the heading that titles an entry: a heading span's own, else the entry's first heading unless a nested entry's */
  function titleOf(at) {
    if (at.kind === "heading") return at.el;
    var h = at.el.querySelector("h1, h2, h3, h4, h5, h6"), e = h && entryAt(h);
    return e && e.n === at.n ? h : null;
  }
  /* the first block of `r` that reaches below `top` (a block cut by that line is entered when it holds blocks) */
  function firstBelow(r, top) {
    function inner(node) {
      for (var ch = node.firstChild; ch; ch = ch.nextSibling) {
        if (ch.nodeType !== 1 || !r.intersectsNode(ch)) continue;
        var d = getComputedStyle(ch).display, found;
        if (d === "contents") { if ((found = inner(ch))) return found; continue; }
        if (d === "none" || /^inline/.test(d)) continue;
        var b = ch.getBoundingClientRect();
        if (b.bottom <= top || (!b.width && !b.height)) continue;
        if (b.top < top && !isFormula(ch) && !SKIP[ch.tagName.toUpperCase()] && (found = inner(ch))) return found;
        return ch;
      }
      return null;
    }
    var root = r.commonAncestorContainer;
    return inner(root.nodeType === 1 ? root : root.parentNode);
  }
  /* The text of the entry being read: all of it when it fits. A longer one whose top is scrolled away (its first
     6000 characters may all be above the view) gives its title, a "…" line, then its text from the first block on
     screen. */
  function sectionText(at, limit) {
    var r = entryRange(at), all = rangeText(r, limit + 1000), top = stickyInset();
    if (all.length <= limit || at.el.getBoundingClientRect().top >= top) return finish(all, limit);
    var from = firstBelow(r, top), head = titleOf(at);
    if (!from || r.comparePoint(from, 0) !== 0) return finish(all, limit);
    if (head && (head === from || head.contains(from) || from.contains(head) ||
        !(head.compareDocumentPosition(from) & Node.DOCUMENT_POSITION_FOLLOWING))) return finish(all, limit);
    var above = r.cloneRange();   /* what the cut leaves out, after the title */
    if (head) above.setStartAfter(head);
    above.setEndBefore(from);
    if (above.collapsed || !rangeText(above, 20)) return finish(all, limit);
    var title = head ? nodeText(head, 300) : finish(all.split("\n")[0], 140);
    title = (title ? title + "\n" : "") + "\u2026\n";
    r.setStartBefore(from);
    return title + rangeText(r, limit - title.length);
  }

  /* the sticky top bar's height (as the indexer measures it when scrolling to a section) */
  function stickyInset() {
    var inset = 0, q = document.querySelectorAll("nav, header, .topnav, .mm-head, [class*='sticky']");
    for (var i = 0; i < q.length; i++) {
      var cs = getComputedStyle(q[i]);
      if (cs.position !== "sticky" && cs.position !== "fixed") continue;
      var r = q[i].getBoundingClientRect();
      if (r.height > window.innerHeight * 0.4 || r.width < window.innerWidth * 0.5 || r.bottom <= 0) continue;
      inset = Math.max(inset, (parseFloat(cs.top) || 0) + r.height);
    }
    return inset;
  }

  /* the node at a point of the view: the text nearest to it inside the element there (a point between two
     paragraphs hits their block, which would lose the heading span they're in) */
  function nodeAt(x, y) {
    var el = document.elementFromPoint(x, y);
    if (!el || el === host) return null;
    var c = document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
    return c && el.contains(c.startContainer) ? c.startContainer : el;
  }

  /* the indexed entry being read: under a point a third of the way down the view, below the top bar */
  function readingEntry() {
    var inset = stickyInset(), vh = window.innerHeight, vw = document.documentElement.clientWidth || window.innerWidth;
    var main = document.querySelector("main") || document.body;
    var mr = main ? main.getBoundingClientRect() : { left: 0, right: vw };
    var xs = [(Math.max(mr.left, 0) + Math.min(mr.right, vw)) / 2, vw / 2, vw * 0.3];
    var y0 = inset + (vh - inset) / 3, dys = [0, 40, -40, 90, -90, 160, -160, 240];
    for (var i = 0; i < dys.length; i++) {
      var y = y0 + dys[i];
      if (y <= inset || y >= vh) continue;
      for (var j = 0; j < xs.length; j++) {
        var at = entryAt(nodeAt(xs[j], y));
        if (at) return at;
      }
    }
    return null;
  }

  /* ---------------- the selection ---------------- */
  function inField(sel) {
    var a = document.activeElement;
    if (a && a !== document.body && (/^(INPUT|TEXTAREA|SELECT)$/.test(a.tagName) || a.isContentEditable)) return true;
    var ends = [sel.anchorNode, sel.focusNode];
    for (var i = 0; i < ends.length; i++) {
      var e = ends[i] && (ends[i].nodeType === 1 ? ends[i] : ends[i].parentElement);
      if (e && e.closest("input, textarea, select, [contenteditable]:not([contenteditable='false'])")) return true;
    }
    return false;
  }
  /* a non-empty selection of the page (not inside a text field), or null. It counts by what it quotes: a formula
     alone has no text to toString() (MathJax draws SVG, and its copy for screen readers can't be selected). */
  function pageSelection() {
    var sel = window.getSelection();
    if (!sel || !sel.rangeCount || sel.isCollapsed || inField(sel)) return null;
    if (!sel.toString().trim() && !rangeText(sel.getRangeAt(0), 100)) return null;
    return sel;
  }
  function startNode(r) {
    var n = r.startContainer;
    if (n.nodeType === 1 && r.startOffset < n.childNodes.length) n = n.childNodes[r.startOffset];
    return n;
  }
  /* in a fixed or sticky element (the top bar itself), which doesn't scroll under the top bar */
  function pinned(node) {
    for (var e = node.nodeType === 1 ? node : node.parentElement; e && e !== document.body; e = e.parentElement) {
      var pos = getComputedStyle(e).position;
      if (pos === "fixed" || pos === "sticky") return true;
    }
    return false;
  }
  /* part of `range` is in the view, below the top bar */
  function onScreen(range) {
    var rects = range.getClientRects(), top = pinned(range.commonAncestorContainer) ? 0 : stickyInset();
    var vh = window.innerHeight, vw = document.documentElement.clientWidth || window.innerWidth;
    for (var i = 0; i < rects.length; i++) {
      var b = rects[i];
      if (b.width > 0.5 && b.height > 0.5 && b.bottom > top && b.top < vh && b.right > 0 && b.left < vw) return true;
    }
    return false;
  }
  /* `seen`: only a selection that is (partly) on screen (one scrolled away, say by Follow slides, is not what the student
     is looking at) */
  function selectionPayload(seen) {
    var sel = pageSelection();
    if (!sel) return null;
    var range = tidy(sel.getRangeAt(0));
    if (seen && !onScreen(range)) return null;
    var text = rangeText(range, MAX_SELECTION) || finish(sel.toString(), MAX_SELECTION);
    if (!text) return null;
    var p = { kind: "selection", text: withMacros(text, MAX_SELECTION) }, path = pathText(entryAt(startNode(range)));
    if (path) p.section = path;
    return p;
  }

  function collect(opts) {
    if (opts && opts.hide) dismiss();
    var p = selectionPayload(true);
    if (p) return p;
    var at = readingEntry(), text = at ? withMacros(sectionText(at, MAX_SECTION), MAX_SECTION) : "";
    if (!text) return null;
    p = { kind: "section", text: text };
    var path = pathText(at);
    if (path) p.section = path;
    return p;
  }

  /* ---------------- the "Ask about this" button ----------------
     A fixed host with a closed shadow root, so page CSS can't reach it. Its label is CSS generated content and the
     host can't be selected, so it never ends up in a selection or a quote. It never takes focus: mousedown on it is
     cancelled, which also keeps the page's selection. */
  var host = null, shown = false, dismissed = null;
  var ICON = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3 2.5h10A1.5 1.5 0 0 1 14.5 4v6a1.5 1.5 0 0 1-1.5 ' +
    '1.5H8.2L5 14v-2.5H3A1.5 1.5 0 0 1 1.5 10V4A1.5 1.5 0 0 1 3 2.5z" fill="none" stroke="currentColor" ' +
    'stroke-width="1.5" stroke-linejoin="round"/></svg>';
  /* visibility:inherit after all:initial, so hiding the host hides the button too */
  var CSS =
    "button{all:initial;visibility:inherit;box-sizing:border-box;display:inline-flex;align-items:center;gap:5px;" +
    "padding:5px 11px 5px 9px;border-radius:999px;border:1px solid rgba(255,255,255,.22);background:#2563eb;" +
    "color:#fff;cursor:pointer;" +
    "font:600 12px/16px -apple-system,BlinkMacSystemFont,'Helvetica Neue',Helvetica,Arial,sans-serif;white-space:nowrap;" +
    "box-shadow:0 2px 8px rgba(15,23,42,.28),0 0 0 1px rgba(15,23,42,.08);-webkit-user-select:none;user-select:none}" +
    "button::after{content:'Ask about this'}" +
    "button:hover{background:#1d4ed8}button:active{background:#1e40af}" +
    "svg{width:13px;height:13px;flex:none}" +
    "@media (prefers-color-scheme: dark){button{border-color:rgba(255,255,255,.4);" +
    "box-shadow:0 2px 12px rgba(0,0,0,.65),0 0 0 1px rgba(0,0,0,.4)}}";

  function makeButton() {
    host = document.createElement("colearner-ask");
    host.setAttribute("data-clwt-skip", "");
    host.style.cssText = "all:initial!important;position:fixed!important;z-index:2147483647!important;" +
      "display:none!important;left:0;top:0;-webkit-user-select:none!important;user-select:none!important";
    var root = host.attachShadow({ mode: "closed" });
    root.innerHTML = "<style>" + CSS + "</style><button type='button' tabindex='-1' aria-label='Ask the chat about this'>" +
      ICON + "</button>";
    var stop = function (e) { e.stopPropagation(); };
    host.addEventListener("mousedown", function (e) { e.preventDefault(); e.stopPropagation(); });
    ["mouseup", "pointerdown", "pointerup", "dblclick"].forEach(function (t) { host.addEventListener(t, stop); });
    host.addEventListener("click", function (e) { e.preventDefault(); e.stopPropagation(); ask(); });
  }

  function show() {
    if (!host) makeButton();
    if (!host.isConnected) document.documentElement.appendChild(host);
    shown = true;
    host.style.setProperty("display", "block", "important");
    place();
  }
  function hide() {
    shown = false;
    if (host) host.style.setProperty("display", "none", "important");
  }
  function marks(sel) { return [sel.anchorNode, sel.anchorOffset, sel.focusNode, sel.focusOffset]; }
  function sameMarks(a, b) { return a[0] === b[0] && a[1] === b[1] && a[2] === b[2] && a[3] === b[3]; }
  /* Sent away (a click elsewhere, Esc, the app): it stays away for this selection. WebKit keeps a selection when a
     page button, slider or drawing is clicked, and every mouseup would bring the button back. */
  function dismiss() {
    if (shown) {
      var sel = window.getSelection();
      dismissed = sel && sel.rangeCount ? marks(sel) : null;
    }
    hide();
  }

  /* made from the end towards the start; boundary points, not nodes, are compared (a selection that ends after a
     display formula ends in the formula's parent, which as a node comes before the text the selection starts in) */
  function backward(sel) {
    if (!sel.anchorNode || !sel.focusNode) return false;
    try {
      var r = document.createRange();
      r.setStart(sel.anchorNode, sel.anchorOffset);
      return r.comparePoint(sel.focusNode, sel.focusOffset) < 0;
    } catch (e) { return false; }
  }
  /* where the selection ends on screen (where the pointer let go): the right end of its lowest line, or the left end
     of its top line when it was made backwards. WebKit's range rects come in no useful order and include the glyphs
     of MathJax's clipped copy for screen readers, so this goes by position. */
  function selectionEnd(sel) {
    var rects = tidy(sel.getRangeAt(0)).getClientRects(), list = [];
    for (var i = 0; i < rects.length; i++) if (rects[i].width > 0.5 && rects[i].height > 0.5) list.push(rects[i]);
    if (!list.length) return null;
    var back = backward(sel), line = list[0];
    list.forEach(function (r) { if (back ? r.top < line.top : r.bottom > line.bottom) line = r; });
    var x = back ? line.left : line.right;
    list.forEach(function (r) {
      var mid = (r.top + r.bottom) / 2;
      if (mid >= line.top && mid <= line.bottom) x = back ? Math.min(x, r.left) : Math.max(x, r.right);
    });
    return { x: x, top: line.top, bottom: line.bottom, back: back };
  }
  /* page controls the button must not cover: a click meant for one would ask instead. Formulas are not controls,
     but a button that holds one is. */
  var CONTROLS = "a[href], button, input, select, textarea, label, summary, svg, canvas, video, iframe, " +
    "[contenteditable]:not([contenteditable='false']), [role='button'], [role='checkbox'], [role='radio'], " +
    "[role='slider'], [role='switch'], [role='tab'], [role='option'], [role='menuitem']";
  function overControl(x, y, w, h) {
    var pts = [[x + 3, y + 3], [x + w - 3, y + 3], [x + 3, y + h - 3], [x + w - 3, y + h - 3], [x + w / 2, y + h / 2]];
    for (var i = 0; i < pts.length; i++) {
      var el = document.elementFromPoint(pts[i][0], pts[i][1]);
      if (!el || el === host) continue;
      var f = el.closest("mjx-container, .katex");
      if (f) el = f.parentElement;
      if (el && el.closest(CONTROLS)) return true;
    }
    return false;
  }
  /* Next to the end of the selection: below its line (above it for a selection made backwards), else on the other
     side when there's no room or a control there, else beside its end; hidden while that end is scrolled out of
     view. */
  function place() {
    if (!shown || !host) return;
    var sel = window.getSelection();
    if (!sel || !sel.rangeCount || sel.isCollapsed) { hide(); return; }
    var e = selectionEnd(sel);
    var vw = document.documentElement.clientWidth || window.innerWidth, vh = window.innerHeight, top = stickyInset();
    host.style.setProperty("visibility", "hidden", "important");   /* also out of the way while looking under it */
    if (!e || e.bottom < top || e.top > vh) return;
    var w = host.offsetWidth, h = host.offsetHeight, gap = 6, x = e.back ? e.x - 12 : e.x - w + 12;
    var below = [x, e.bottom + gap], above = [x, e.top - h - gap];
    var beside = [e.back ? e.x - w - gap : e.x + gap, (e.top + e.bottom - h) / 2];
    var spots = e.back ? [above, below, beside] : [below, above, beside], fits = null, free = null;
    for (var i = 0; i < spots.length && !free; i++) {
      var sx = Math.max(6, Math.min(spots[i][0], vw - w - 6)), sy = spots[i][1];
      if (sy < top + 4 || sy + h > vh - 6) continue;
      if (!fits) fits = [sx, sy];
      if (!overControl(sx, sy, w, h)) free = [sx, sy];
    }
    var at = free || fits || [Math.max(6, Math.min(x, vw - w - 6)), Math.max(top + 4, Math.min(spots[0][1], vh - h - 6))];
    host.style.setProperty("left", Math.round(at[0]) + "px", "important");
    host.style.setProperty("top", Math.round(at[1]) + "px", "important");
    host.style.setProperty("visibility", "visible", "important");
  }

  function ask() {
    var p = shown ? selectionPayload(false) : null;
    hide();
    if (!p) return;
    try { window.webkit.messageHandlers.clask.postMessage(p); } catch (e) { return; }   /* not in Co-learner */
    var sel = window.getSelection();
    try { if (sel && sel.rangeCount) sel.collapseToEnd(); } catch (e) { /* ignore */ }
  }

  /* after the selection settles (double and triple clicks): show for page text unless sent away, hide otherwise */
  function update() {
    setTimeout(function () {
      var sel = pageSelection();
      if (!sel) { hide(); return; }
      if (dismissed && sameMarks(marks(sel), dismissed)) return;
      dismissed = null;
      show();
    }, 0);
  }

  /* listeners never cancel or stop the page's events (its own widgets and the arrow keys work as before) */
  document.addEventListener("mouseup", function (e) { if (e.button === 0 && e.target !== host) update(); }, true);
  document.addEventListener("keyup", function (e) { if (e.shiftKey && /^Arrow/.test(e.key)) update(); }, true);
  document.addEventListener("mousedown", function (e) { if (shown && e.target !== host) dismiss(); }, true);
  document.addEventListener("keydown", function (e) { if (shown && e.key === "Escape") dismiss(); }, true);
  /* any change of the selection ends a dismissal (selecting the same words again is a new selection) */
  document.addEventListener("selectionchange", function () { dismissed = null; if (shown) place(); });
  window.addEventListener("scroll", function () { if (shown) place(); }, { capture: true, passive: true });
  window.addEventListener("resize", function () { if (shown) place(); }, { passive: true });

  /* ---------------- area selection in the app ---------------- */
  function crosshair(on) {
    var s = document.getElementById("colearner-crosshair");
    if (on) {
      dismiss();
      if (!s) {
        s = document.createElement("style");
        s.id = "colearner-crosshair";
        s.textContent = "*,*::before,*::after{cursor:crosshair!important}";
        (document.head || document.documentElement).appendChild(s);
      }
    } else if (s) {
      s.remove();
    }
    return !!on;
  }
  function sectionAt(x, y) { return pathText(entryAt(nodeAt(x, y))); }

  window.__coLearnerAsk = { version: VERSION, collect: collect, sectionAt: sectionAt, crosshair: crosshair,
    hide: function () { dismiss(); return true; },
    textOf: function (target, limit) {
      var n = limit || MAX_SELECTION;
      return target && typeof target.intersectsNode === "function" ? rangeText(target, n) : target ? nodeText(target, n) : "";
    },
    sectionOf: function (node) { return pathText(entryAt(node)); } };
})();
