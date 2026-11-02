/* webbook_read.js  (Co-learner 0.2.1)
 *
 * Runs on every page of a web tab, in Co-learner's own content world (the page's scripts can't see or call it; the
 * page itself is shared). Only the app calls it:
 *   __clReader.read({max, root}) -> {url, title, site, text, truncated}: the page's text in reading order. Headings are
 *     "#"-lines, list items "- " or "1. ", table rows "a | b", pictures "[image: alt]"; math as TeX where the page keeps
 *     it (KaTeX's TeX annotation, MathJax 2's script tags, MathJax 3's records, which the app copies to data-cl-tex in
 *     the page's world first, MathML's alttext), other math as its plain text. Navigation, the page's own header and
 *     footer, sidebars, buttons, forms and hidden parts are left out. `site` is the book's name when the page shows it
 *     (its og:site_name, or a link with text that goes back to the book's start page `root`).
 *   __clReader.readAll({max, root}) -> a Promise of the same, with the text of the page's collapsed PreTeXt examples
 *     and proofs ("knowls") under their titles: kept hidden in the page (refid), or loaded from the same site when
 *     clicked, which is fetched here once per page (at most 60, 4 s each; never the page itself).
 *   __clReader.where({max}) -> {section, visible, scrollY, viewH, viewW, docH}: the titles of the sections a third of
 *     the way down the view (outermost first) and the text of what is on screen, read the same way.
 *   __clReader.sectionAt(y) -> the section path at a height of the view, joined with " › " ("" if none).
 *   __clReader.crosshair(on) -> a crosshair cursor everywhere while the app drags out an area.
 *   __clReader.textOf(node, max) -> the extraction of one node (for tests).
 */
(function () {
  "use strict";
  var VERSION = "0.2.1";
  if (window.__clReader && window.__clReader.version === VERSION) return;

  var SKIP = { STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, CANVAS: 1, VIDEO: 1, AUDIO: 1, INPUT: 1, TEXTAREA: 1, SELECT: 1,
    OBJECT: 1, EMBED: 1, HEAD: 1, LINK: 1, META: 1, BUTTON: 1, DIALOG: 1, WBR: 1, "MJX-ASSISTIVE-MML": 1 };
  var BLOCK = { P: 1, DIV: 1, SECTION: 1, ARTICLE: 1, MAIN: 1, HEADER: 1, FOOTER: 1, ASIDE: 1, UL: 1, OL: 1, DL: 1,
    DT: 1, DD: 1, PRE: 1, BLOCKQUOTE: 1, TABLE: 1, TBODY: 1, THEAD: 1, TFOOT: 1, CAPTION: 1, FIGURE: 1,
    FIGCAPTION: 1, FORM: 1, FIELDSET: 1, DETAILS: 1, SUMMARY: 1, ADDRESS: 1, CENTER: 1, HR: 1, LI: 1, TR: 1 };
  /* blocks followed by an empty line */
  var PARA = { P: 1, PRE: 1, BLOCKQUOTE: 1, TABLE: 1, FIGURE: 1, UL: 1, OL: 1, DL: 1 };
  /* links to a heading itself ("¶", "#", "permalink"), next to section titles */
  var ANCHOR = /(^|\s)(permalink|headerlink|header-anchor|anchor-link|anchorjs-link|hash-link|heading-anchor)(\s|$)/;
  /* rendered copies of math whose source is read elsewhere (MathJax 2 keeps TeX in a script next to them) */
  var RENDERED = /(^|\s)(MathJax|MathJax_Display|MathJax_Preview|MathJax_SVG|MathJax_SVG_Display|MathJax_CHTML|MJX_Assistive_MathML|katex-mathml)(\s|$)/;

  function shown(el) {
    if (!el.ownerDocument || el.ownerDocument !== document) return true;   // a fetched example: nothing is laid out
    try {
      if (typeof el.checkVisibility === "function" && el.checkVisibility({ visibilityProperty: true })) return true;
    } catch (e) { /* older WebKit: below */ }
    var cs = getComputedStyle(el);
    // display: contents has no box of its own (checkVisibility says no), but what is inside shows (SvelteKit and Astro
    // pages wrap everything in one); its children are checked one by one.
    return cs.display === "contents" || cs.display !== "none" && cs.visibility !== "hidden" && typeof el.checkVisibility !== "function";
  }

  /* page chrome: navigation always; the page's own header, footer and sidebars when they are not part of the text */
  function isChrome(el) {
    var tag = el.tagName.toUpperCase(), role = el.getAttribute("role");
    if (tag === "NAV" || role === "navigation" || role === "search") return true;
    if (el.getAttribute("aria-hidden") === "true") return true;
    if (tag === "HEADER" || tag === "FOOTER" || tag === "ASIDE" || role === "banner" || role === "contentinfo" || role === "complementary") {
      return !el.parentElement || !el.parentElement.closest("main, article, section, [role=main]");
    }
    return false;
  }
  function inChrome(el) {
    for (var e = el; e && e !== document.body; e = e.parentElement) if (isChrome(e)) return true;
    return false;
  }

  /* the part of the page that holds the text: <main> (or role=main) when it has some, else the body */
  function rootEl() {
    var m = document.querySelector("main, [role=main]");
    if (m && (m.textContent || "").trim().length > 200) return m;
    return document.body || document.documentElement;
  }

  function attr(el, name) { var v = el.getAttribute(name); return v ? v.trim() : ""; }
  /* a collapsed example, proof or remark (its heading shows, its text comes when clicked), not a reference in a sentence */
  function isBlockKnowl(el) {
    return el.hasAttribute("knowl") && (!!el.querySelector("h1, h2, h3, h4, h5, h6, article")
      || (!!el.parentElement && /(^|\s)hidden-knowl-wrapper(\s|$)/.test(classOf(el.parentElement))));
  }
  function classOf(el) { return typeof el.className === "string" ? el.className : ""; }

  /* TeX for a formula, with its $ or $$, or null when the page doesn't keep it */
  function tex(el, tag) {
    var t = attr(el, "data-cl-tex");
    if (t) return t;
    if (el.classList.contains("katex") || el.classList.contains("katex-display")) {
      var a = el.querySelector('annotation[encoding="application/x-tex"]');
      if (!a) return null;
      var display = el.classList.contains("katex-display") || !!el.closest(".katex-display");
      return display ? "$$" + a.textContent.trim() + "$$" : "$" + a.textContent.trim() + "$";
    }
    if (tag === "MATH") {
      var ann = el.querySelector('annotation[encoding="application/x-tex"]');
      var s = attr(el, "alttext") || (ann ? ann.textContent.trim() : "");
      if (!s) return null;
      return el.getAttribute("display") === "block" ? "$$" + s + "$$" : "$" + s + "$";
    }
    return null;
  }

  /* Writes a subtree as text. `keep(el)` (optional) leaves out elements it returns false for, with all inside;
     `knowls` (optional) maps collapsed examples' links to their text; `hidden`: hidden parts too (a collapsed proof). */
  function writer(limit, keep, knowls, hidden) {
    var out = "", truncated = false, space = false, boundary = false;
    function full() { if (out.length >= limit) { truncated = true; return true; } return false; }
    function clip() { if (out.length > limit) { out = out.slice(0, limit); truncated = true; } }
    function put(s) {
      if (!s || full()) return;
      if (out && !/\s$/.test(out)) {
        if (space) out += " ";
        // Words in separate elements with no space between them are laid out apart ("Section" "3.3" "Linear").
        else if (boundary && /[A-Za-z0-9)\]]$/.test(out) && /^[A-Za-z0-9(\[]/.test(s)) out += " ";
      }
      space = false;
      boundary = false;
      out += s;
      clip();
    }
    function raw(s) { if (!s || full()) return; out += s; space = false; boundary = false; clip(); }
    function br() {
      out = out.replace(/[ \t]+$/, "");
      if (out && out.charAt(out.length - 1) !== "\n") out += "\n";
      space = false;
      boundary = false;
    }
    function para() { br(); if (out && !/\n\n$/.test(out)) out += "\n"; }
    function text(node, pre) {
      var s = node.nodeValue || "";
      if (pre) { raw(s); return; }
      var t = s.replace(/\s+/g, " ");
      if (!t.trim()) { if (t) space = true; return; }
      if (/^\s/.test(t)) space = true;
      put(t.trim());
      if (/\s$/.test(t)) space = true;
    }
    function children(el, pre) {
      for (var c = el.firstChild; c; c = c.nextSibling) {
        if (full()) return;
        if (c.nodeType === 3) text(c, pre);
        else if (c.nodeType === 1) element(c, pre);
      }
    }
    function element(el, pre) {
      var tag = el.tagName.toUpperCase();
      if (tag === "SCRIPT") {
        var type = attr(el, "type");
        if (/^math\/tex/i.test(type)) {
          var src = (el.textContent || "").trim();
          if (src) { put(/mode\s*=\s*display/i.test(type) ? "$$" + src + "$$" : "$" + src + "$"); boundary = true; }
        }
        return;
      }
      // (MathJax 3's own containers carry the class "MathJax" too: they are read below.)
      if (SKIP[tag] || (tag !== "MJX-CONTAINER" && RENDERED.test(classOf(el))) || isChrome(el)) return;
      if (ANCHOR.test(classOf(el)) || (tag === "A" && /^[\s¶#§🔗]*$/.test(el.textContent || "") && !el.querySelector("img, svg"))) return;
      if (keep && !keep(el)) return;
      if (!hidden && !shown(el)) return;
      if (isBlockKnowl(el)) {
        // A collapsed example: its title as the link names it ("Example 3.3.6 Verifying linearity: rotation"), and its
        // text when it was fetched.
        var label = (attr(el, "title") || inner(el, 300).replace(/^#+\s*/, "")).replace(/\s+/g, " ").trim();
        var level = el.querySelector("h1, h2, h3, h4, h5, h6");
        var body = knowls && knowls.get(el);
        para();
        if (label) raw(new Array((level ? +level.tagName.charAt(1) : 5) + 1).join("#") + " " + label
          + (body ? " (collapsed on the page; its text:)" : " (collapsed on the page)"));
        para();
        if (body) { raw(body); para(); }
        return;
      }
      var formula = tex(el, tag);
      if (formula) { put(formula); boundary = true; return; }
      if (tag === "MJX-CONTAINER") { put("[formula]"); boundary = true; return; }
      if (tag === "IMG") { var alt = attr(el, "alt"); if (alt) put("[image: " + alt + "]"); boundary = true; return; }
      if (tag === "IFRAME") { var it = attr(el, "title"); put(it ? "[embedded: " + it + "]" : "[embedded content]"); boundary = true; return; }
      if (tag === "SVG") {
        var titled = el.querySelector("title");
        var label = attr(el, "aria-label") || (titled ? (titled.textContent || "").trim() : "");
        // Math drawn as SVG text comes in runs (a word of \text{}, a symbol): words get their space back.
        var glyphs = Array.from(el.querySelectorAll("text")).reduce(function (acc, t) {
          var run = (t.textContent || "").trim();
          return acc + (acc && /[A-Za-z]$/.test(acc) && /^[A-Za-z]/.test(run) ? " " : "") + run;
        }, "").replace(/\s+/g, " ").trim();
        if (label) put("[figure: " + label + "]");
        else if (glyphs && glyphs.length < 200 && el.getBoundingClientRect().height < 80) put(glyphs);   // math drawn as SVG text
        boundary = true;
        return;
      }
      if (tag === "BR") { br(); return; }
      var h = /^H([1-6])$/.exec(tag);
      if (h) {
        var title = inner(el, 300).replace(/\s+/g, " ").trim();
        para();
        if (title) { raw(new Array(+h[1] + 1).join("#") + " " + title); para(); }
        return;
      }
      if (tag === "SUP" || tag === "SUB") {
        var small = inner(el, 200).replace(/\s+/g, " ").trim();
        if (small) { raw((tag === "SUP" ? "^{" : "_{") + small + "}"); boundary = true; }
        return;
      }
      if (tag === "TR") {
        var cells = Array.from(el.children).filter(function (c) { return /^T[DH]$/.test(c.tagName.toUpperCase()) && shown(c); })
          .map(function (c) { return inner(c, 600).replace(/\s+/g, " ").trim(); });
        br();
        put(cells.join(" | "));
        br();
        return;
      }
      var block = BLOCK[tag] === 1;
      if (block) br(); else boundary = true;
      if (tag === "LI") {
        var parent = el.parentElement, ordered = parent && parent.tagName.toUpperCase() === "OL";
        raw(ordered ? (Array.prototype.indexOf.call(parent.children, el) + 1) + ". " : "- ");
      }
      children(el, pre || tag === "PRE");
      if (block) { if (PARA[tag]) para(); else br(); } else boundary = true;
    }
    return {
      node: function (n) { if (n.nodeType === 3) text(n, false); else if (n.nodeType === 1) element(n, false); },
      children: function (el) { children(el, false); },
      done: function () { return { text: out.replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim(), truncated: truncated }; }
    };
  }

  /* the text inside an element (not the element itself: a heading's title, a table cell) */
  function inner(el, limit) {
    var w = writer(limit);
    w.children(el);
    return w.done().text;
  }

  /* the section headings in reading order, each with its rank: heading level, then how deep it sits in sections */
  function headings(root) {
    return Array.from(root.querySelectorAll("h1, h2, h3, h4, h5, h6")).filter(function (h) {
      return !inChrome(h) && shown(h);
    }).map(function (h) {
      var depth = 0;
      for (var e = h.parentElement; e && e !== root; e = e.parentElement) if (/^(SECTION|ARTICLE)$/.test(e.tagName.toUpperCase())) depth++;
      return { el: h, rank: (+h.tagName.charAt(1)) * 10 + Math.min(depth, 9) };
    });
  }
  function titleOf(h) {
    var k = h.closest("a[knowl]"), t = k ? attr(k, "title") : "";   // a collapsed example: its numbered title
    return (t || inner(h, 300)).replace(/\s+/g, " ").trim().slice(0, 160);
  }

  /* the titles of the sections at height y of the view, outermost first */
  function pathAt(y) {
    var stack = [], list = headings(rootEl());
    for (var i = 0; i < list.length; i++) {
      if (list[i].el.getBoundingClientRect().top > y) break;
      while (stack.length && stack[stack.length - 1].rank >= list[i].rank) stack.pop();
      stack.push(list[i]);
    }
    return stack.map(function (e) { return titleOf(e.el); }).filter(function (t) { return !!t; });
  }

  /* the book's name, when the page shows it */
  function siteName(root) {
    var m = document.querySelector('meta[property="og:site_name"], meta[name="application-name"]');
    var c = m ? (m.getAttribute("content") || "").trim() : "";
    if (c) return c.slice(0, 120);
    if (!root) return "";
    var home = [root, root + "index.html", root + "index.htm"];
    var links = document.querySelectorAll("a[href]");
    for (var i = 0; i < links.length && i < 400; i++) {
      var a = links[i];
      if (home.indexOf(String(a.href).split("#")[0]) < 0) continue;
      var t = (a.textContent || "").replace(/\s+/g, " ").trim();
      if (t.length >= 3 && t.length <= 120 && !/^(home|start|contents|index|toc|table of contents|up|top)$/i.test(t)) return t;
    }
    return "";
  }

  function read(opts, knowls) {
    opts = opts || {};
    var w = writer(Math.max(1000, opts.max || 60000), null, knowls);
    w.node(rootEl());
    var r = w.done();
    return { url: location.href, title: (document.title || "").trim().slice(0, 300), site: siteName(opts.root || ""),
             text: r.text, truncated: r.truncated };
  }

  /* collapsed examples' text by address, for this page (fetched once each) */
  var fetched = new Map();
  function fetchKnowl(href) {
    if (fetched.has(href)) return fetched.get(href);
    var p = (async function () {
      var ctl = new AbortController(), timer = setTimeout(function () { ctl.abort(); }, 4000);
      try {
        var r = await fetch(href, { signal: ctl.signal, credentials: "same-origin" });
        if (!r.ok || !/html|text/i.test(r.headers.get("content-type") || "text/html")) return "";
        var doc = new DOMParser().parseFromString(await r.text(), "text/html");
        var w = writer(6000);
        w.children(doc.body || doc.documentElement);
        return w.done().text;
      } catch (e) { return ""; } finally { clearTimeout(timer); }
    })();
    fetched.set(href, p);
    return p;
  }

  async function readAll(opts) {
    var map = new Map();
    var links = Array.from(rootEl().querySelectorAll("a[knowl]")).filter(isBlockKnowl).slice(0, 60);
    var here = location.href.split("#")[0];
    await Promise.all(links.map(async function (a) {
      // Kept hidden in this page (newer PreTeXt: knowl="" refid="hk-proof-13").
      var ref = attr(a, "refid"), kept = ref && document.getElementById(ref);
      if (kept) {
        var w = writer(6000, null, null, true);
        w.children(kept);
        var t0 = w.done().text;
        if (t0) map.set(a, t0);
        return;
      }
      var src = attr(a, "knowl"), u;
      if (!src) return;
      try { u = new URL(src, location.href); } catch (e) { return; }
      if (u.origin !== location.origin || u.href.split("#")[0] === here) return;
      var t = await fetchKnowl(u.href);
      if (t) map.set(a, t);
    }));
    return read(opts, map);
  }

  function where(opts) {
    opts = opts || {};
    var vh = window.innerHeight, vw = window.innerWidth;
    var w = writer(Math.max(200, opts.max || 2000), function (el) {
      var r = el.getBoundingClientRect();
      if (r.width === 0 && r.height === 0) return true;   // display: contents and empty wrappers
      return r.bottom > 0 && r.top < vh && r.right > 0 && r.left < vw;
    });
    w.node(rootEl());
    var doc = document.scrollingElement || document.documentElement;
    return { section: pathAt(vh / 3), visible: w.done().text, scrollY: Math.round(window.scrollY), viewH: vh, viewW: vw,
             docH: Math.round(doc ? doc.scrollHeight : vh) };
  }

  function crosshair(on) {
    var s = document.getElementById("cl-crosshair-style");
    if (on && !s) {
      s = document.createElement("style");
      s.id = "cl-crosshair-style";
      s.textContent = "*, *::before, *::after { cursor: crosshair !important; }";
      (document.head || document.documentElement).appendChild(s);
    } else if (!on && s) s.remove();
  }

  window.__clReader = { version: VERSION, read: function (o) { return read(o); }, readAll: readAll, where: where, crosshair: crosshair,
    sectionAt: function (y) { return pathAt(y).join(" › "); },
    textOf: function (node, max) { var w = writer(max || 60000); w.node(node); return w.done().text; } };
})();
