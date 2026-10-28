/* walkthrough_ask.js  (Co-learner v0.1.9)
 *
 * Injected into every study page after walkthrough_index.js (WKUserScript at .atDocumentEnd, main frame only).
 * Asking the chat about part of the page:
 *   - select text and a small "Ask about this" button appears next to it; a click posts
 *     {kind: "selection", text, section} to the app (message handler "clask");
 *   - __coLearnerAsk.collect({hide?}) -> the selection as above, or else the section being read,
 *     {kind: "section", text, section}: the indexed entry about a third of the way down the view (below the sticky
 *     top bar); null if neither. The Walkthrough tab's Ask button and Slides › Ask About Walkthrough use it.
 *   - __coLearnerAsk.sectionAt(x, y) -> the section path at a point of the view ("" if none), for a captured area.
 *   - __coLearnerAsk.crosshair(on) -> a crosshair cursor everywhere while the app drags out an area.
 *   - __coLearnerAsk.textOf(range | node), sectionOf(node) -> the extraction and the path below (also for tests).
 * "text" keeps math as TeX ($...$ and $$...$$ from MathJax 3's own records, KaTeX's TeX annotation), skips hidden
 * parts, controls and figures, and puts each block on its own line. "section" is the path of titles the app's
 * "Showing: ..." line uses (__coLearnerWT.entryAt), joined with " › "; mind maps have none.
 */
(function () {
  "use strict";
  var VERSION = "0.1.9";
  if (window.__coLearnerAsk && window.__coLearnerAsk.version === VERSION) return;

  var MAX_SELECTION = 8000, MAX_SECTION = 6000;

  /* ---------------- text, with math as TeX ---------------- */
  var SKIP = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, SVG: 1, CANVAS: 1, IFRAME: 1, VIDEO: 1, AUDIO: 1,
    IMG: 1, INPUT: 1, TEXTAREA: 1, SELECT: 1, BUTTON: 1, "MJX-ASSISTIVE-MML": 1 };

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
  function listMark(li, cs) {
    if (cs.display !== "list-item" || cs.listStyleType === "none") return "";
    var list = li.parentElement;
    if (!list || list.tagName !== "OL") return "- ";
    var n = parseInt(list.getAttribute("start"), 10);
    n = isNaN(n) ? 1 : n;
    for (var s = li.previousElementSibling; s; s = s.previousElementSibling) if (s.tagName === "LI") n++;
    return n + ". ";
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

  /* The text of `range` as the reader sees it, at most `limit` characters. */
  function rangeText(range, limit) {
    var root = range.commonAncestorContainer;
    if (root && root.nodeType !== 1) root = root.parentNode;
    if (!root || root.nodeType !== 1) return "";
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
    function math(el) {
      var f = formula(el, mj);
      if (!f.tex) { text(f.plain, false); return; }
      if (f.display) { br(); put("$$" + f.tex + "$$"); br(); }
      else put("$" + f.tex + "$");
    }
    function element(el, pre) {
      var tag = el.tagName.toUpperCase();
      if (tag === "BR") { put("\n"); return; }
      if (SKIP[tag] || el === host) return;
      var cs = getComputedStyle(el);
      if (!rendered(el, cs)) return;
      if (isFormula(el)) { math(el); return; }
      var d = cs.display, cell = d === "table-cell", block = !cell && !/^(inline|contents|ruby)/.test(d);
      var p = pre || /^(pre|break-spaces)/.test(cs.whiteSpace);
      if (cell) {
        if (el.previousElementSibling) { out = out.replace(/ +$/, ""); put(" | "); }
      } else if (block) {
        br();
        if (tag === "LI") put(listMark(el, cs));
      }
      walk(el, p);
      if (block) br();
    }
    function walk(node, pre) {
      for (var ch = node.firstChild; ch && !full; ch = ch.nextSibling) {
        if (!range.intersectsNode(ch)) continue;
        if (ch.nodeType === 3) {
          var t = ch.nodeValue;
          if (ch === range.endContainer) t = t.slice(0, range.endOffset);
          if (ch === range.startContainer) t = t.slice(range.startOffset);
          text(t, pre);
        } else if (ch.nodeType === 1) {
          element(ch, pre);
        }
      }
    }

    var f = formulaRoot(root);
    if (f) math(f);
    else walk(root, /^(pre|break-spaces)/.test(getComputedStyle(root).whiteSpace));
    return finish(out, limit);
  }

  function nodeText(node, limit) {
    var r = document.createRange();
    r.selectNodeContents(node);
    return rangeText(r, limit);
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
  /* the text of a section, or of a heading span (its heading up to the next heading of the same or a higher level) */
  function entryText(at, limit) {
    var r = document.createRange();
    if (at.kind === "heading" && at.block) {
      r.setStartBefore(at.el);
      if (at.end) r.setEndBefore(at.end); else r.setEnd(at.block, at.block.childNodes.length);
    } else {
      r.selectNodeContents(at.el);
    }
    return rangeText(r, limit);
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
  /* a non-empty selection of page text (not inside a text field), or null */
  function pageSelection() {
    var sel = window.getSelection();
    if (!sel || !sel.rangeCount || sel.isCollapsed || inField(sel) || !sel.toString().trim()) return null;
    return sel;
  }
  function startNode(r) {
    var n = r.startContainer;
    if (n.nodeType === 1 && r.startOffset < n.childNodes.length) n = n.childNodes[r.startOffset];
    return n;
  }
  function selectionPayload() {
    var sel = pageSelection();
    if (!sel) return null;
    var range = sel.getRangeAt(0);
    var text = rangeText(range, MAX_SELECTION) || finish(sel.toString(), MAX_SELECTION);
    if (!text) return null;
    var p = { kind: "selection", text: text }, path = pathText(entryAt(startNode(range)));
    if (path) p.section = path;
    return p;
  }

  function collect(opts) {
    if (opts && opts.hide) hide();
    var p = selectionPayload();
    if (p) return p;
    var at = readingEntry(), text = at ? entryText(at, MAX_SECTION) : "";
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
  var host = null, shown = false;
  var ICON = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3 2.5h10A1.5 1.5 0 0 1 14.5 4v6a1.5 1.5 0 0 1-1.5 ' +
    '1.5H8.2L5 14v-2.5H3A1.5 1.5 0 0 1 1.5 10V4A1.5 1.5 0 0 1 3 2.5z" fill="none" stroke="currentColor" ' +
    'stroke-width="1.5" stroke-linejoin="round"/></svg>';
  var CSS =
    "button{all:initial;box-sizing:border-box;display:inline-flex;align-items:center;gap:5px;padding:5px 11px 5px 9px;" +
    "border-radius:999px;border:1px solid rgba(255,255,255,.22);background:#2563eb;color:#fff;cursor:pointer;" +
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
    var rects = sel.getRangeAt(0).getClientRects(), list = [];
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
  /* next to the end of the selection, below its line, or above it when there's no room; hidden while that end is
     scrolled out of view */
  function place() {
    if (!shown || !host) return;
    var sel = window.getSelection();
    if (!sel || !sel.rangeCount || sel.isCollapsed) { hide(); return; }
    var e = selectionEnd(sel);
    var vw = document.documentElement.clientWidth || window.innerWidth, vh = window.innerHeight, top = stickyInset();
    if (!e || e.bottom < top || e.top > vh) { host.style.setProperty("visibility", "hidden", "important"); return; }
    host.style.setProperty("visibility", "visible", "important");
    var w = host.offsetWidth, h = host.offsetHeight, gap = 6;
    var x = e.back ? e.x - 12 : e.x - w + 12, y;
    if (e.back) { y = e.top - h - gap; if (y < top + 4) y = e.bottom + gap; }
    else { y = e.bottom + gap; if (y + h > vh - 6) y = e.top - h - gap; }
    x = Math.max(6, Math.min(x, vw - w - 6));
    y = Math.max(top + 4, Math.min(y, vh - h - 6));
    host.style.setProperty("left", Math.round(x) + "px", "important");
    host.style.setProperty("top", Math.round(y) + "px", "important");
  }

  function ask() {
    var p = shown ? selectionPayload() : null;
    hide();
    if (!p) return;
    try { window.webkit.messageHandlers.clask.postMessage(p); } catch (e) { return; }   /* not in Co-learner */
    var sel = window.getSelection();
    try { if (sel && sel.rangeCount) sel.collapseToEnd(); } catch (e) { /* ignore */ }
  }

  /* after the selection settles (double and triple clicks): show for page text, hide otherwise */
  function update() { setTimeout(function () { if (pageSelection()) show(); else hide(); }, 0); }

  /* listeners never cancel or stop the page's events (its own widgets and the arrow keys work as before) */
  document.addEventListener("mouseup", function (e) { if (e.button === 0 && e.target !== host) update(); }, true);
  document.addEventListener("keyup", function (e) { if (e.shiftKey && /^Arrow/.test(e.key)) update(); }, true);
  document.addEventListener("mousedown", function (e) { if (shown && e.target !== host) hide(); }, true);
  document.addEventListener("keydown", function (e) { if (shown && e.key === "Escape") hide(); }, true);
  document.addEventListener("selectionchange", function () { if (shown) place(); });
  window.addEventListener("scroll", function () { if (shown) place(); }, { capture: true, passive: true });
  window.addEventListener("resize", function () { if (shown) place(); }, { passive: true });

  /* ---------------- area selection in the app ---------------- */
  function crosshair(on) {
    var s = document.getElementById("colearner-crosshair");
    if (on) {
      hide();
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
    textOf: function (target, limit) {
      var n = limit || MAX_SELECTION;
      return target && typeof target.intersectsNode === "function" ? rangeText(target, n) : target ? nodeText(target, n) : "";
    },
    sectionOf: function (node) { return pathText(entryAt(node)); } };
})();
