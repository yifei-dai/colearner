// Add current-deck slide navigation to sanitized assistant prose. Keep markup and excluded content intact.
(function () {
  "use strict";

  const EXCLUDED = "a, button, pre, code, script, style, textarea, select, svg, math, iframe, .katex, .katex-error, .visual";
  const BLOCK = /^(ADDRESS|ARTICLE|ASIDE|BLOCKQUOTE|BR|DD|DIV|DL|DT|FIGCAPTION|FIGURE|H[1-6]|HR|LI|OL|P|SECTION|TABLE|TD|TH|TR|UL)$/;
  const START = /\bslides?\b(?:\s*#\s*|\s+)/gi;
  const NUMBER = /^(?:#\s*)?(\d{1,3}(?:,\d{3})+|\d+)(?![\w]|\.\d)/;
  const RANGE = /^\s*(?:[-\u2010-\u2015]|to\b|through\b)\s*/i;
  const LIST = /^\s*(?:,\s*(?:(?:and|or)\s+)?|(?:and|or)\s+|&\s*)/i;

  function numberAt(text, at) {
    const m = NUMBER.exec(text.slice(at));
    if (!m) return null;
    const start = at + m[0].length - m[1].length;
    return { start, end: at + m[0].length, page: Number(m[1].replace(/,/g, "")) };
  }

  // An explicit foreign-deck qualifier is not permission to navigate the current deck.
  function qualifiedElsewhere(text, start, end) {
    const before = text.slice(Math.max(0, start - 100), start);
    const after = text.slice(end, end + 100);
    const deck = "(?:lecture|deck|presentation)";
    const other = "(?:another|other|different|previous|next)";
    const named = "(?:" + deck + "\\s+(?:#\\s*)?[A-Za-z0-9]+|W\\d+L\\d+|\\d{2}[ab]|[^\\s]+\\.pdf)";
    return new RegExp("(?:\\b" + other + "\\s+" + deck + "|\\b" + named + ")\\s*(?:[,:·(—-]\\s*)?(?:see\\s+)?(?:['’]s\\s*)?$", "i").test(before)
      || new RegExp("^\\s*(?:\\(\\s*)?(?:(?:of|in|from)\\s+)?(?:the\\s+)?(?:" + other + "\\s+" + deck + "|" + named + ")\\b", "i").test(after);
  }

  function references(text, pageCount) {
    const out = [];
    START.lastIndex = 0;
    let match;
    while ((match = START.exec(text))) {
      let first = numberAt(text, START.lastIndex);
      if (!first) continue;
      const candidates = [];
      let end = first.end;
      for (;;) {
        const range = RANGE.exec(text.slice(first.end));
        const last = range && numberAt(text, first.end + range[0].length);
        if (last) {
          end = last.end;
          // Long, backwards, or out-of-deck ranges are not useful navigation references.
          if (first.page >= 1 && last.page <= pageCount && last.page >= first.page && last.page - first.page <= 100) {
            candidates.push(first, last);
          }
        } else {
          end = first.end;
          if (first.page >= 1 && first.page <= pageCount) candidates.push(first);
        }
        const sep = LIST.exec(text.slice(end));
        const next = sep && numberAt(text, end + sep[0].length);
        if (!next) break;
        first = next;
      }
      if (!qualifiedElsewhere(text, match.index, end)) out.push(...candidates);
      START.lastIndex = end;
    }
    return out;
  }

  function decorate(root, context) {
    const pageCount = Number(context && context.pageCount);
    if (!root || !Number.isSafeInteger(pageCount) || pageCount < 1 ||
        !context.deckPath || !context.conversationID || root.closest(".msg.user")) return;

    // Group prose across inline emphasis so `slide <strong>12</strong>` still has its prefix.
    // Break at code, links, math, visuals and block boundaries to avoid borrowing unrelated text.
    const runs = [];
    let run = null;
    function flush() { if (run) runs.push(run); run = null; }
    function visit(node) {
      if (node.nodeType === Node.TEXT_NODE) {
        if (!run) run = { text: "", nodes: [] };
        const start = run.text.length;
        run.text += node.nodeValue;
        run.nodes.push({ node, start, end: run.text.length });
        return;
      }
      if (node.nodeType !== Node.ELEMENT_NODE) return;
      if (node.matches(EXCLUDED)) { flush(); return; }
      const block = BLOCK.test(node.tagName);
      if (block) flush();
      for (const child of node.childNodes) visit(child);
      if (block) flush();
    }
    visit(root);
    flush();

    for (const { text, nodes } of runs) {
      // Work backwards so replacing later text leaves earlier offsets in the same text node valid.
      for (const ref of references(text, pageCount).reverse()) {
        const part = nodes.find((n) => n.start <= ref.start && n.end >= ref.end);
        if (!part) continue; // Do not rewrite a number whose digits themselves span multiple elements.
        const range = document.createRange();
        range.setStart(part.node, ref.start - part.start);
        range.setEnd(part.node, ref.end - part.start);
        const button = document.createElement("button");
        button.type = "button";
        button.className = "slide-ref";
        button.dataset.slide = String(ref.page);
        button.dataset.deckPath = context.deckPath;
        button.dataset.conversationId = context.conversationID;
        button.title = "Go to slide " + ref.page;
        button.setAttribute("aria-label", button.title);
        button.appendChild(range.extractContents());
        range.insertNode(button);
      }
    }
  }

  window.CLSlideLinks = { decorate };
})();
