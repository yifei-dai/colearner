/* walkthrough_index.js  (Co-learner v0.1)
 *
 * Inject into a loaded study page (WKUserScript at .atDocumentEnd, or evaluateJavaScript after didFinish).
 * Builds an index "section/subsection -> PDF pages of the lecture deck" and scrolls/highlights the best
 * section for "deck X, PDF page N".
 *
 * API (all return plain JSON-serializable objects):
 *   __coLearnerWT.index({rebuild?, numbering?, ownDeck?})
 *       -> {version, family, course, numbering, ownDeck, decks:[keys], entries:[{n, anchor, id, title, kind,
 *           level, parent, aux, slides:{deck:[pdfPages]}, cites:{...}, mentions:{...}}]}
 *   __coLearnerWT.locate({file? | deck?, page})
 *       -> {ok, match, matchedPage, anchor, id, title, kind, path:[titles], slides:{deck:[pdfPages]}, deckKeys}
 *          match: "declared" | "cited" | "mentioned"      (a section/subsection covers page N)
 *                 "nearest-preceding"                      (N uncovered: block of the closest covered page < N)
 *                 "page-range" | "before-first" | "deck-not-on-page"   (anchor = the page hero / top)
 *   __coLearnerWT.go({file? | deck?, page, behavior?:'auto'|'smooth', highlight?:true, pinMs?:5000})
 *       -> locate result + {scrolled}. pinMs: keep the target pinned while the layout settles (MathJax from
 *          cdnjs, images); it always waits for MathJax (max 20 s); any wheel/touch/mouse/key stops it; -1 = off.
 *   __coLearnerWT.coverage({file? | deck?, pages})  -> {pages, counts:{<match>: n}, byPage:[{page, match, ...}]}
 *   __coLearnerWT.deckKeyFromFile("01b-intro.pdf") -> "01b"   ("7-search.pdf" -> "L7", other names -> "")
 *   __coLearnerWT.entryAt(node) -> the innermost section / subsection / heading span holding node, or null
 *       -> {n, title, kind, anchor, path:[titles], el, block, end}   (used by walkthrough_ask.js)
 *
 * "page" is always the 1-based PDF page index of the deck shown in the app.
 * Printed slide numbers in the page text are converted per course:
 *   footer-numbered decks ("plus1"): "slide N" / "footer N" = printed footer -> PDF N+1 (PDF 1 = untitled title page); "pg N" = PDF N
 *   two-up handouts ("half"): "slide N" = printed slide, 2 slides per PDF page -> PDF ceil(N/2)
 *   other decks ("identity"): "slide N" = PDF N
 *   "title slide" -> PDF 1 (all).  data-pages="N" / "N-M" -> PDF pages.
 */
(function () {
  "use strict";
  var VERSION = "0.1.0";
  if (window.__coLearnerWT && window.__coLearnerWT.version === VERSION) return;

  var CACHE = null;
  var PIN = null;
  var LAST = null;

  /* ---------------- text helpers ---------------- */
  function norm(s) {
    return String(s == null ? "" : s)
      .replace(/[\u00a0\u2009\u202f\u2007]/g, " ")
      .replace(/[\u2010-\u2015\u2212]/g, "\u2013") // all dashes -> en dash
      .replace(/\s+/g, " ");
  }
  function clip(s, n) { s = norm(s).trim(); return s.length > n ? s.slice(0, n - 1) + "\u2026" : s; }

  /* ---------------- course / numbering ---------------- */
  var NUMBERING = {
    identity: function (n) { return n; },
    plus1: function (n) { return n + 1; },
    half: function (n) { return Math.ceil(n / 2); }
  };

  function detectCourse() {
    var bits = [document.title || ""];
    var q = document.querySelectorAll("header .eyebrow, .hero .eyebrow, h1, #mm-sub");
    for (var i = 0; i < q.length && i < 4; i++) bits.push(q[i].textContent);
    if (window.MM && window.MM.DATA && window.MM.DATA.course) bits.push(window.MM.DATA.course);
    var probe = norm(bits.join(" "));
    if (!/W47\d\d|E47\d\d/.test(probe) && document.body) probe += " " + norm(document.body.textContent.slice(0, 6000));
    var m = probe.match(/\b(?:COMS|CS)\s*W?\s*(4701|4731|4733)\b/i) || probe.match(/\bW(4701|4731|4733)\b/);
    if (m) return "w" + m[1];
    if (/\bCS ?4731\b/i.test(probe)) return "w4731";
    return "generic";
  }
  function defaultNumbering(course) {
    return course === "w4701" ? "plus1" : course === "w4731" ? "half" : "identity";
  }

  /* deck keys: "01a".."06b" (decks named 01a-...), "L1".."L9" (decks named 1-...), "" (the page's own deck); "W4L1" style for week and lecture codes */
  function deckKeyFromFile(file) {
    var b = String(file || "").split("/").pop();
    var m = b.match(/^(\d{2}[ab])[-_ ]/i);
    if (m) return m[1].toLowerCase();
    m = b.match(/^(\d{1,2})-/);
    if (m) return "L" + (+m[1]);
    return "";
  }

  /* ---------------- reference parser ---------------- */
  var KW = /(^|[^A-Za-z0-9])(slides?|pg|pages?|footers?)(?:\s*-\s*|\s+)(?=\d)/gi;
  var NUM = /^(\d{1,3})(?![A-Za-z0-9]|\.\d)/;
  var RANGE = /^\s*(?:to|\u2013|-)\s*(\d{1,3})(?![A-Za-z0-9]|\.\d)/i;
  var SEP = /^\s*(?:,\s*(?:and\s+)?|and\s+|&\s*)(?=\d)/i;
  var TITLE_SLIDE = /\btitle slide\b/gi;

  function qualifier(before, course) {
    var m = before.match(/(^|[^A-Za-z0-9])(\d{2}[ab])\s*(?:\u00b7\s*)?$/i);
    if (m) return m[2].toLowerCase();
    m = before.match(/\b(W\d{1,2}L\d)\s*$/);
    if (m) return m[1];
    m = before.match(/\b(?:lecture|lec\.?)\s*(\d{1,2})\s*,?\s*(?:footer\s*)?$/i) || before.match(/\bL(\d{1,2})\s*,?\s*$/);
    if (m) return course === "w4733" ? "?" : "L" + (+m[1]);
    return null;
  }

  /* returns [{key, pages:[pdf...]}] ; ctxKey = deck inherited from the enclosing section */
  function parseRefs(text, ctxKey, st) {
    var t = norm(text), out = [], m;
    KW.lastIndex = 0;
    while ((m = KW.exec(t))) {
      var kw = m[2].toLowerCase();
      var isPdf = kw === "pg" || kw === "page" || kw === "pages";
      if ((kw === "page" || kw === "pages") && !st.allowPages) continue;
      var j = m.index + m[0].length, rest = t.slice(j), nums = [], mm;
      for (;;) {
        mm = NUM.exec(rest); if (!mm) break;
        var a = +mm[1], b = a; rest = rest.slice(mm[0].length);
        var rr = RANGE.exec(rest);
        if (rr) { var bb = +rr[1]; if (bb >= a && bb - a < 150) { b = bb; rest = rest.slice(rr[0].length); } }
        nums.push([a, b]);
        var ss = SEP.exec(rest); if (!ss) break;
        rest = rest.slice(ss[0].length);
      }
      if (!nums.length) continue;
      var before = t.slice(Math.max(0, m.index + m[1].length - 40), m.index + m[1].length);
      var q = qualifier(before, st.course);
      if (q === "?") continue;
      var key = q != null ? q : (ctxKey != null ? ctxKey : "");
      var conv = isPdf ? NUMBERING.identity : st.conv;
      var pages = [];
      for (var k = 0; k < nums.length; k++)
        for (var n = nums[k][0]; n <= nums[k][1]; n++) { var p = conv(n); if (p >= 1 && pages.indexOf(p) < 0) pages.push(p); }
      if (pages.length) out.push({ key: key, pages: pages });
      KW.lastIndex = j;
    }
    TITLE_SLIDE.lastIndex = 0;
    if (TITLE_SLIDE.test(t)) out.push({ key: ctxKey != null ? ctxKey : "", pages: [1] });
    return out;
  }

  /* ---------------- DOM index (walkthrough / review / recap families) ---------------- */
  var SKIP_TAGS = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, SVG: 1, CANVAS: 1, "MJX-CONTAINER": 1, MATH: 1,
    IFRAME: 1, VIDEO: 1, AUDIO: 1, IMG: 1, SELECT: 1, TEXTAREA: 1, INPUT: 1 };
  var BLOCK = /^(P|LI|DIV|H[1-6]|TD|TH|TR|DT|DD|FIGCAPTION|FIGURE|SECTION|ARTICLE|HEADER|BLOCKQUOTE|UL|OL|DL|TABLE|BUTTON|LABEL|SUMMARY|DETAILS|ASIDE|MAIN|NAV|PRE|BR)$/;

  function containerKind(el) {
    var tag = el.tagName;
    if (tag === "HEADER" && (el.classList.contains("hero") || (el.parentElement && /^(MAIN|BODY)$/.test(el.parentElement.tagName) && el.querySelector("h1")))) return "page";
    if (tag === "SECTION" && (el.id || el.classList.contains("topic"))) return "section";
    if (el.matches(".sub[id], article[id], [data-pages], [data-slides], .sheet-card, .card[id]")) return "sub";
    if (el.id && /^(DIV|ASIDE)$/.test(tag)) {
      var c = el.firstElementChild, k = 0;
      while (c && k < 2) { if (/^H[23]$/.test(c.tagName)) return "sub"; c = c.nextElementSibling; k++; }
    }
    return null;
  }

  function build(opts) {
    opts = opts || {};
    var course = detectCourse();
    var numbering = opts.numbering || defaultNumbering(course);
    var st = { course: course, conv: NUMBERING[numbering] || NUMBERING.identity, allowPages: false };
    var hero = document.querySelector("header.hero") || document.querySelector("main > header, body > header");
    var heroText = hero ? norm((hero.querySelector(".eyebrow") || {}).textContent || "") : "";
    var ownDeck = opts.ownDeck != null ? opts.ownDeck : "";
    if (opts.ownDeck == null) {
      var lm = heroText.match(/\bLecture\s+(\d{1,2})\b/i);
      if (course === "w4701" && lm) ownDeck = "L" + (+lm[1]);
      var dk = uniq((heroText.match(/\b\d{2}[ab]\b/gi) || []).map(function (s) { return s.toLowerCase(); }));
      if (course === "w4733" && dk.length === 1) ownDeck = dk[0];
    }

    var E = [];
    function newEntry(el, kind, parent, level) {
      var e = { n: E.length, el: el, kind: kind, parent: parent ? parent.n : -1, level: level, kids: [],
        D: {}, C: {}, M: {}, ctx: parent ? parent.ctx : ownDeck, title: "", aux: parent ? parent.aux : false,
        spans: [], titleEl: null, declEls: [] };
      E.push(e);
      if (parent) parent.kids.push(e.n);
      return e;
    }
    function ownedBy(node, cont) {
      for (var a = node.parentElement; a; a = a.parentElement) { if (a === cont) return true; if (containerKind(a)) return false; }
      return false;
    }
    function firstOwn(cont, sel) {
      var q = cont.querySelectorAll(sel);
      for (var i = 0; i < q.length; i++) if (ownedBy(q[i], cont)) return q[i];
      return null;
    }
    function setupContainer(e) {
      var el = e.el;
      var head = firstOwn(el, "h1, h2, h3, h4, h5");
      var eb = firstOwn(el, ".eyebrow");
      var pgh = firstOwn(el, ".pg-h, .pg-n");
      e.titleEl = head;
      e.declEls = [head, eb, pgh].filter(Boolean);
      var declText = e.declEls.map(function (x) { return x.textContent; }).join(" ");
      var toks = uniq((norm(declText).match(/\b\d{2}[ab]\b/gi) || []).map(function (s) { return s.toLowerCase(); }));
      if (course === "w4733" && toks.length === 1) e.ctx = toks[0];
      if (el.hasAttribute("data-deck")) e.ctx = el.getAttribute("data-deck");
      var dp = el.getAttribute("data-pages"), ds = el.getAttribute("data-slides");
      if (dp) addSpec(e, "D", dp, NUMBERING.identity);
      if (ds) addSpec(e, "D", ds, st.conv);
      e.title = clip((head && head.textContent) || (eb && eb.textContent) || el.getAttribute("aria-label") || el.id || "", 140);
      /* practice / cheat-sheet sections are only used when no lecture section matches */
      if ((e.kind === "section" && /^(quiz|exam|sheet|practice|refs|references)\b/i.test(el.id || "")) ||
          /\b(practice quiz|exam practice|cheat sheet|self-test)\b/i.test(e.title)) e.aux = true;
    }
    function addSpec(e, tier, spec, conv) {
      String(spec).split(/[,\s]+/).forEach(function (part) {
        var m = part.match(/^(\d+)(?:[-\u2013](\d+))?$/); if (!m) return;
        var a = +m[1], b = m[2] ? +m[2] : a;
        for (var n = a; n <= b && n - a < 300; n++) addPage(e[tier], e.ctx, conv(n));
      });
    }
    function addPage(obj, key, p) { key = key || ""; (obj[key] || (obj[key] = {}))[p] = 1; }

    /* text buffer: refs are parsed per contiguous run of text with the same target+tier */
    var buf = null;
    function flush() {
      if (!buf || !buf.text.trim()) { buf = null; return; }
      st.allowPages = buf.tier === "D";
      var refs = parseRefs(buf.text, buf.target.ctx, st);
      for (var i = 0; i < refs.length; i++)
        for (var k = 0; k < refs[i].pages.length; k++) addPage(buf.target[buf.tier], refs[i].key, refs[i].pages[k]);
      buf = null;
    }
    function pushText(target, tier, text) {
      if (buf && (buf.target !== target || buf.tier !== tier)) flush();
      if (!buf) buf = { target: target, tier: tier, text: "" };
      buf.text += text;
    }

    function isSpanHeading(el, cont) {
      if (!/^H[3-5]$/.test(el.tagName)) return false;
      if (el === cont.titleEl) return false;
      if (el.closest("figure, details, table, .cp, .worked, .quiz, .q")) return false;
      return true;
    }

    var ROOT = { ctx: ownDeck, D: {}, C: {}, M: {}, n: -1 };
    function textTarget(cont) { return cont ? (cont.spans.length ? cont.spans[cont.spans.length - 1] : cont) : ROOT; }
    /* tier: "D" declared (titles, eyebrows, .pg-n, data-pages), "C" cited (.src pills), "M" mentioned (other text) */
    function walk(node, cont, tier, declTarget) {
      for (var ch = node.firstChild; ch; ch = ch.nextSibling) {
        if (ch.nodeType === 3) { pushText(tier === "D" ? declTarget : textTarget(cont), tier, ch.nodeValue); continue; }
        if (ch.nodeType !== 1) continue;
        var tag = ch.tagName.toUpperCase();
        if (SKIP_TAGS[tag]) { if (tag === "MJX-CONTAINER" || tag === "MATH") pushText(tier === "D" ? declTarget : textTarget(cont), tier, " "); continue; }
        if (tag === "NAV" || ch.classList.contains("topnav") || ch.hasAttribute("data-clwt-skip")) continue;
        var isBlock = BLOCK.test(tag);
        if (isBlock) flush();
        var kind = containerKind(ch);
        if (kind) {
          var e = newEntry(ch, kind, cont, cont ? cont.level + 1 : (kind === "page" ? 0 : 1));
          setupContainer(e);
          walk(ch, e, "M", null);
          flush();
          continue;
        }
        if (cont && tier !== "D" && isSpanHeading(ch, cont)) {
          var lvl = +ch.tagName.charAt(1);
          while (cont.spans.length && cont.spans[cont.spans.length - 1].hl >= lvl) cont.spans.pop();
          var par = cont.spans.length ? cont.spans[cont.spans.length - 1] : cont;
          var s = newEntry(ch, "heading", par, par.level + 1);
          s.hl = lvl; s.ctx = par.ctx; s.title = clip(ch.textContent, 140);
          cont.spans.push(s);
          walk(ch, cont, "D", s);
          flush();
          continue;
        }
        if (cont && cont.declEls.indexOf(ch) >= 0) walk(ch, cont, "D", cont);
        else if (tier !== "D" && ch.classList.contains("src")) walk(ch, cont, "C", null);
        else walk(ch, cont, tier, declTarget);
        if (isBlock) flush();
      }
    }
    walk(document.body, null, "M", null);
    flush();

    /* aggregate: S = own D if any, else own C + kids S;  Cagg = own C + kids (S u Cagg);  Magg = own M + kids Magg */
    for (var i = E.length - 1; i >= 0; i--) {
      var e = E[i];
      e.S = hasAny(e.D) ? clone(e.D) : clone(e.C);
      e.Cagg = merge(clone(e.C), e.S);
      e.Magg = clone(e.M);
      for (var k = 0; k < e.kids.length; k++) {
        var c = E[e.kids[k]];
        if (!hasAny(e.D)) merge(e.S, c.S);
        merge(e.Cagg, c.S); merge(e.Cagg, c.Cagg);
        merge(e.Magg, c.Magg);
      }
    }
    E.forEach(function (e) {
      if (e.el.id) e.anchor = "#" + cssEscape(e.el.id);
      else { e.el.setAttribute("data-clwt", String(e.n)); e.anchor = '[data-clwt="' + e.n + '"]'; }
    });
    var decks = {};
    E.forEach(function (e) { Object.keys(e.Cagg).concat(Object.keys(e.Magg)).forEach(function (k) { decks[k] = 1; }); });
    return { family: "dom", course: course, numbering: numbering, ownDeck: ownDeck, decks: Object.keys(decks), E: E };
  }

  /* ---------------- mind map family (window.MM.DATA: a root node with label, kind, children and slide sources) ---------------- */
  function buildMindMap() {
    var D = window.MM.DATA, E = [];
    var decks = (D.decks || []).map(function (d) { return d.id; });
    (function rec(n, depth, parent) {
      var e = { n: E.length, node: n, kind: n.kind, level: depth, parent: parent ? parent.n : -1, kids: [], D: {}, C: {}, M: {},
        title: n.label || n.id, anchor: '.node[data-id="' + cssEscape(n.id) + '"]', id: n.id, aux: false };
      (n.sources || []).forEach(function (s) {
        if (s.t === "slide" && s.n != null) { var k = s.deck || ""; (e.D[k] || (e.D[k] = {}))[+s.n] = 1; }
      });
      E.push(e); if (parent) parent.kids.push(e.n);
      (n.children || []).forEach(function (c) { rec(c, depth + 1, e); });
    })(D.root, 0, null);
    E.forEach(function (e) { e.S = clone(e.D); e.Cagg = clone(e.D); e.Magg = {}; });
    return { family: "mindmap", course: detectCourse(), numbering: "identity", ownDeck: decks.length === 1 ? decks[0] : "", decks: decks, E: E };
  }

  /* ---------------- set helpers (sets are {deck: {page:1}}) ---------------- */
  function uniq(a) { var o = []; a.forEach(function (x) { if (o.indexOf(x) < 0) o.push(x); }); return o; }
  function clone(o) { var r = {}; for (var k in o) { r[k] = {}; for (var p in o[k]) r[k][p] = 1; } return r; }
  function merge(a, b) { for (var k in b) { var t = a[k] || (a[k] = {}); for (var p in b[k]) t[p] = 1; } return a; }
  function hasAny(o) { for (var k in o) for (var p in o[k]) return true; return false; }
  function toLists(o) { var r = {}; for (var k in o) { var l = Object.keys(o[k]).map(Number).sort(function (a, b) { return a - b; }); if (l.length) r[k] = l; } return r; }
  function minus(a, b) { var r = {}; for (var k in a) for (var p in a[k]) if (!(b[k] && b[k][p])) (r[k] || (r[k] = {}))[p] = 1; return r; }
  function cssEscape(s) { return (window.CSS && CSS.escape) ? CSS.escape(s) : String(s).replace(/["\\#.:\[\]()]/g, "\\$&"); }

  function getIndex(opts) {
    opts = opts || {};
    if (!CACHE || opts.rebuild || (opts.numbering && opts.numbering !== CACHE.numbering) || (opts.ownDeck != null && opts.ownDeck !== CACHE.ownDeck)) {
      CACHE = (window.MM && window.MM.DATA && window.MM.byId) ? buildMindMap() : build(opts);
    }
    return CACHE;
  }

  function keysFor(idx, q) {
    var key = q.deck != null ? String(q.deck) : (q.file ? deckKeyFromFile(q.file) : "");
    if (/^\d{2}[ab]$/i.test(key)) key = key.toLowerCase();
    if (key === "" || key === idx.ownDeck) return uniq([idx.ownDeck, ""]);
    return [key];
  }
  function has(obj, keys, N) { for (var i = 0; i < keys.length; i++) if (obj[keys[i]] && obj[keys[i]][N]) return true; return false; }
  function size(obj, keys) { var s = 0; for (var i = 0; i < keys.length; i++) if (obj[keys[i]]) s += Object.keys(obj[keys[i]]).length; return s; }
  function minBy(list, rank) {
    var best = null, br = null;
    list.forEach(function (x) {
      var r = rank(x);
      if (!best) { best = x; br = r; return; }
      for (var i = 0; i < r.length; i++) { if (r[i] < br[i]) { best = x; br = r; return; } if (r[i] > br[i]) return; }
    });
    return best;
  }

  /* core: returns {entry, match} or null when nothing on the page contains N */
  function locateCore(idx, keys, N) {
    var E = idx.E;
    if (idx.family === "mindmap") {
      var c = E.filter(function (e) { return has(e.S, keys, N); });
      if (!c.length) return null;
      var b = minBy(c, function (e) { return [size(e.S, keys), e.level, e.n]; });
      return { entry: b, match: "declared" };
    }
    var tops = E.filter(function (e) { return e.parent === -1 && e.kind !== "page"; });
    var tiers = [["D", "declared"], ["S", "declared"], ["Cagg", "cited"], ["Magg", "mentioned"]];
    var best = null, match = null;
    outer:
    for (var aux = 0; aux < 2; aux++) {
      for (var t = 0; t < tiers.length; t++) {
        var f = tiers[t][0];
        if (aux === 1 && f === "Magg") continue; /* a quiz/cheat sheet that only mentions N is not a target */
        var cand = tops.filter(function (e) { return (!!e.aux) === (aux === 1) && has(e[f], keys, N); });
        if (!cand.length) continue;
        /* several sections can contain N (2-up PDF pages, overlapping ranges): prefer the one whose
           descent ends on the most specific block, then the smaller section, then document order */
        best = minBy(cand.map(function (e) { var end = descend(E, e, keys, N); return { top: e, end: end, f: f }; }),
          function (x) { return [endSize(x.end, keys, N), size(x.top[f], keys), x.top.n]; }).end;
        match = tiers[t][1];
        break outer;
      }
    }
    if (!best) {
      var any = E.filter(function (e) { return e.kind !== "page" && has(e.S, keys, N); });
      if (any.length) { best = descend(E, minBy(any, function (e) { return [size(e.S, keys), e.n]; }), keys, N); match = "declared"; }
    }
    if (!best) {
      var pg = E.filter(function (e) { return e.kind === "page" && has(e.D, keys, N); });
      if (pg.length) return { entry: pg[0], match: "page-range" };
      return null;
    }
    return { entry: best, match: match };
  }
  function endSize(e, keys, N) { return has(e.S, keys, N) ? size(e.S, keys) : has(e.Magg, keys, N) ? size(e.Magg, keys) : 1e6; }
  function descend(E, start, keys, N) {
    var cur = start;
    for (;;) {
      var kids = cur.kids.map(function (i) { return E[i]; });
      var curSize = size(cur.S, keys);
      var curOwn = has(cur.D, keys, N) || has(cur.C, keys, N);
      /* go deeper only from a section, or into a strictly more specific child, or into a child whose own
         title declares N when the current block does not itself cite N */
      var ck = kids.filter(function (k) {
        return has(k.S, keys, N) && (cur.kind === "section" || cur.kind === "page" || size(k.S, keys) < curSize || (has(k.D, keys, N) && !curOwn));
      });
      var rank = function (k) { return [size(k.S, keys), has(k.D, keys, N) ? 0 : 1, k.n]; };
      if (!ck.length && cur.kind === "section") {
        /* no subsection is labelled with N: take one whose text discusses N, but only an unlabelled
           subsection, or a labelled one whose sole extra mention is N (a labelled sub that says
           "slides 53 to 63 are out of scope" is not a target for 53..63) */
        ck = kids.filter(function (k) {
          return k.kind !== "heading" && has(k.Magg, keys, N) && (size(k.S, keys) === 0 || size(minus(k.Magg, k.S), keys) === 1);
        });
        rank = function (k) { return [size(k.Magg, keys), k.n]; };
      }
      if (!ck.length) return cur;
      cur = minBy(ck, rank);
    }
  }

  function describe(idx, r, keys, extra) {
    var e = r.entry, path = [];
    for (var a = e; a; a = a.parent >= 0 ? idx.E[a.parent] : null) path.unshift(a.title);
    var out = { ok: true, match: r.match, anchor: e.anchor, id: e.id || (e.el && e.el.id) || null, title: e.title, kind: e.kind,
      path: path, slides: toLists(pick(e.S, keys)) };
    for (var k in extra) out[k] = extra[k];
    return out;
  }
  function pick(o, keys) { var r = {}; keys.forEach(function (k) { if (o[k]) r[k] = o[k]; }); return r; }

  function locate(q) {
    q = q || {};
    var idx = getIndex(q), keys = keysFor(idx, q), N = +q.page;
    if (!(N >= 1)) return { ok: false, error: "page must be a 1-based PDF page number" };
    var r = locateCore(idx, keys, N);
    if (r) return describe(idx, r, keys, { matchedPage: N, deckKeys: keys });
    for (var p = N - 1; p >= 1; p--) {
      r = locateCore(idx, keys, p);
      if (r && r.match !== "page-range") return describe(idx, { entry: r.entry, match: "nearest-preceding" }, keys, { matchedPage: p, deckKeys: keys });
    }
    var refd = idx.E.some(function (e) { return keys.some(function (k) { return e.Cagg[k] || e.Magg[k]; }); });
    var heroE = idx.E.filter(function (e) { return e.kind === "page"; })[0] || idx.E[0];
    if (!heroE) return { ok: false, error: "no sections found", deckKeys: keys };
    return describe(idx, { entry: heroE, match: refd ? "before-first" : "deck-not-on-page" }, keys, { matchedPage: null, deckKeys: keys });
  }

  /* ---------------- scrolling + highlight ---------------- */
  function ensureStyle() {
    if (document.getElementById("clwt-style")) return;
    var s = document.createElement("style");
    s.id = "clwt-style";
    s.textContent =
      ".clwt-target{outline:2px solid rgba(245,166,35,.95)!important;outline-offset:6px;border-radius:6px}" +
      "@keyframes clwt-flash{0%{background-color:rgba(245,166,35,.30)}100%{background-color:transparent}}" +
      ".clwt-flash{animation:clwt-flash 1.8s ease-out 1}";
    (document.head || document.documentElement).appendChild(s);
  }
  function topInset() {
    var inset = 0;
    var q = document.querySelectorAll("nav, header, .topnav, .mm-head, [class*='sticky']");
    for (var i = 0; i < q.length; i++) {
      var cs = getComputedStyle(q[i]);
      if (cs.position !== "sticky" && cs.position !== "fixed") continue;
      var r = q[i].getBoundingClientRect();
      if (r.height > window.innerHeight * 0.4 || r.width < window.innerWidth * 0.5) continue;
      inset = Math.max(inset, (parseFloat(cs.top) || 0) + r.height);
    }
    if (!inset) { var sp = parseFloat(getComputedStyle(document.documentElement).scrollPaddingTop); if (sp > 0) inset = sp; }
    return inset + 12;
  }
  function visibleTarget(idx, e) {
    for (var a = e; a; a = a.parent >= 0 ? idx.E[a.parent] : null) {
      var el = document.querySelector(a.anchor);
      if (!el) continue;
      for (var d = el.parentElement; d; d = d.parentElement) if (d.tagName === "DETAILS" && !d.open) d.open = true;
      if (el.getClientRects().length) return { el: el, entry: a };
    }
    return null;
  }
  function cancelPin() { if (PIN) { PIN(); PIN = null; } }
  function pinTo(el, ms) {
    cancelPin();
    var alive = true, iv = null, to = null;
    var place = function (behavior) {
      if (!alive) return;
      var y = Math.max(0, Math.round(el.getBoundingClientRect().top + window.pageYOffset - topInset()));
      if (behavior === "smooth") { window.scrollTo({ top: y, behavior: "smooth" }); return; }
      /* pages set html{scroll-behavior:smooth}; force an instant jump */
      var h = document.documentElement, old = h.style.scrollBehavior;
      h.style.scrollBehavior = "auto";
      window.scrollTo(0, y);
      h.style.scrollBehavior = old;
    };
    var onUser = function () { cancelPin(); };
    var evs = ["wheel", "touchstart", "mousedown", "keydown"];
    evs.forEach(function (ev) { window.addEventListener(ev, onUser, { passive: true }); });
    iv = setInterval(function () {
      var d = el.getBoundingClientRect().top - topInset();
      var maxY = document.documentElement.scrollHeight - window.innerHeight;
      if (Math.abs(d) > 3 && !(d > 0 && window.pageYOffset >= maxY - 1)) place("auto");
    }, 250);
    /* keep pinning for ms, and in any case until MathJax (loaded async from cdnjs) has typeset, max 20 s */
    var t0 = Date.now();
    var mjDone = function () {
      var M = window.MathJax;
      if (!M || !M.startup) return !document.querySelector("script[src*='mathjax']");
      if (M.startup.promise && !M.__clwtHooked) { M.__clwtHooked = true; M.startup.promise.then(function () { M.__clwtDone = true; }); }
      return !!M.__clwtDone;
    };
    var tick = function () { if (Date.now() - t0 >= 20000 || mjDone()) cancelPin(); else to = setTimeout(tick, 400); };
    to = setTimeout(tick, Math.max(0, ms));
    PIN = function () { alive = false; clearInterval(iv); clearTimeout(to); evs.forEach(function (ev) { window.removeEventListener(ev, onUser); }); };
    return place;
  }

  function go(q) {
    q = q || {};
    var res = locate(q);
    if (!res.ok) return res;
    var idx = getIndex(q);
    if (idx.family === "mindmap") {
      var node = window.MM.byId.get(res.id);
      if (node) {
        window.MM.select(node);   /* opens collapsed ancestors, centers the node, opens the detail panel */
        if (window.MM.state && window.MM.state.view === "outline") {
          res.anchor = '.ol li[data-id="' + cssEscape(res.id) + '"]';
          var li = document.querySelector(res.anchor);
          if (li) li.scrollIntoView({ block: "center", behavior: q.behavior === "smooth" ? "smooth" : "auto" });
        }
      }
      res.scrolled = !!node;
      LAST = res;
      return res;
    }
    var entry = idx.E.filter(function (e) { return e.anchor === res.anchor; })[0];
    var vt = visibleTarget(idx, entry);
    if (!vt) { res.scrolled = false; return res; }
    if (vt.entry !== entry) { res.anchor = vt.entry.anchor; res.title = vt.entry.title; res.fellBackToParent = true; }
    ensureStyle();
    var prev = document.querySelectorAll(".clwt-target");
    for (var i = 0; i < prev.length; i++) prev[i].classList.remove("clwt-target", "clwt-flash");
    if (q.highlight !== false) {
      vt.el.classList.add("clwt-target");
      void vt.el.offsetWidth;
      vt.el.classList.add("clwt-flash");
    }
    var place = pinTo(vt.el, q.pinMs != null ? q.pinMs : 5000);
    place(q.behavior || "auto");
    if (q.pinMs != null && q.pinMs < 0) cancelPin();
    res.scrolled = true;
    LAST = res;
    return res;
  }

  /* ---------------- where a node sits (walkthrough_ask.js: "Ask about this") ---------------- */
  /* The innermost section, subsection or heading span holding `node`, or null when none does (the top bar, a mind
     map): {n, title, kind, anchor, path:[titles, as locate gives them], el, block, end}. A heading span (el = its
     heading) runs to the next heading of the same or a higher level in its block (end), else to the block's end. */
  function entryAt(node) {
    var idx = getIndex(), el = node && (node.nodeType === 1 ? node : node.parentElement);
    if (!el || idx.family !== "dom") return null;
    var E = idx.E, blocks = new Map(), block = null;
    E.forEach(function (e) { if (e.kind !== "heading") blocks.set(e.el, e); });
    for (var a = el; a && !block; a = a.parentElement) block = blocks.get(a) || null;
    if (!block) return null;
    var blockOf = function (h) { while (h && h.kind === "heading") h = h.parent >= 0 ? E[h.parent] : null; return h; };
    /* the heading spans open at the node, as build() stacks them */
    var spans = [], end = null;
    for (var i = block.n + 1; i < E.length; i++) {
      var h = E[i];
      if (h.kind !== "heading" || blockOf(h) !== block) continue;
      if (h.el === el || (h.el.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_FOLLOWING)) {
        while (spans.length && spans[spans.length - 1].hl >= h.hl) spans.pop();
        spans.push(h);
      } else if (!spans.length || h.hl <= spans[spans.length - 1].hl) {
        end = h.el;
        break;
      }
    }
    var e = spans.length ? spans[spans.length - 1] : block, path = [];
    for (var p = e; p; p = p.parent >= 0 ? E[p.parent] : null) path.unshift(p.title);
    return { n: e.n, title: e.title, kind: e.kind, anchor: e.anchor, path: path, el: e.el, block: block.el,
      end: e === block ? null : end };
  }

  function coverage(q) {
    q = q || {};
    var n = +q.pages, out = { pages: n, counts: { declared: 0, cited: 0, mentioned: 0, "page-range": 0, "nearest-preceding": 0, "before-first": 0, "deck-not-on-page": 0 }, byPage: [] };
    for (var p = 1; p <= n; p++) {
      var r = locate({ deck: q.deck, file: q.file, page: p });
      out.counts[r.match] = (out.counts[r.match] || 0) + 1;
      out.byPage.push({ page: p, match: r.match, matchedPage: r.matchedPage, anchor: r.anchor, title: r.title });
    }
    return out;
  }

  function index(opts) {
    var idx = getIndex(opts);
    return {
      version: VERSION, family: idx.family, course: idx.course, numbering: idx.numbering, ownDeck: idx.ownDeck, decks: idx.decks,
      entries: idx.E.map(function (e) {
        return { n: e.n, anchor: e.anchor, id: e.id || (e.el && e.el.id) || null, title: e.title, kind: e.kind, level: e.level,
          parent: e.parent, aux: !!e.aux, slides: toLists(e.S), cites: toLists(minus(e.Cagg, e.S)),
          mentions: toLists(minus(minus(e.Magg, e.Cagg), e.S)) };
      })
    };
  }

  window.__coLearnerWT = { version: VERSION, index: index, locate: locate, go: go, coverage: coverage,
    deckKeyFromFile: deckKeyFromFile, parseRefs: function (t, ctx, course, numbering) {
      return parseRefs(t, ctx || "", { course: course || detectCourse(), conv: NUMBERING[numbering || defaultNumbering(course || detectCourse())], allowPages: true });
    }, last: function () { return LAST; }, cancelPin: cancelPin, entryAt: entryAt };
})();
