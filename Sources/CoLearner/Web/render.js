// Markdown + math renderer shared by the chat view.
// Math is cut out before markdown runs (so "_" and "*" inside formulas survive),
// replaced by private-use placeholders, and swapped for KaTeX output at the end.
(function () {
  "use strict";

  const PH_OPEN = "";
  const PH_CLOSE = "";
  const ENV_RE = /^\\begin\{(equation|equation\*|align|align\*|aligned|gather|gather\*|gathered|bmatrix|pmatrix|vmatrix|matrix|cases|array)\}/;

  // Find the end of a fenced code block that starts at `i` (a line starting with ``` or ~~~).
  // An unterminated fence (still streaming) runs to the end of the text.
  function fenceEnd(src, i) {
    const m = /^(`{3,}|~{3,})[^\n]*(\n|$)/.exec(src.slice(i));
    const ch = m[1][0];
    const closeRe = new RegExp("^[ \\t]*\\" + ch + "{" + m[1].length + ",}[ \\t]*$");
    let j = i + m[0].length;
    while (j < src.length) {
      const nl = src.indexOf("\n", j);
      const end = nl === -1 ? src.length : nl;
      if (closeRe.test(src.slice(j, end))) return nl === -1 ? src.length : nl + 1;
      j = end + 1;
    }
    return src.length;
  }

  function atLineStart(src, i) {
    let k = i - 1;
    while (k >= 0 && (src[k] === " " || src[k] === "\t")) k--;
    return k < 0 || src[k] === "\n";
  }

  // Returns {text, maths:[{tex, display}]}
  function extractMath(src) {
    const maths = [];
    let out = "";
    let i = 0;
    const n = src.length;
    const push = (tex, display) => {
      maths.push({ tex, display });
      return PH_OPEN + (maths.length - 1) + PH_CLOSE;
    };
    while (i < n) {
      const c = src[i];
      // fenced code
      if ((c === "`" || c === "~") && src.startsWith(c.repeat(3), i) && atLineStart(src, i)) {
        const e = fenceEnd(src, i);
        out += src.slice(i, e);
        i = e;
        continue;
      }
      // inline code: a run of N backticks closed by the same run
      if (c === "`") {
        let r = 1;
        while (src[i + r] === "`") r++;
        const ticks = "`".repeat(r);
        const close = src.indexOf(ticks, i + r);
        if (close !== -1) {
          out += src.slice(i, close + r);
          i = close + r;
          continue;
        }
        out += ticks;
        i += r;
        continue;
      }
      if (c === "\\") {
        const nx = src[i + 1];
        if (nx === "$") { out += "\\$"; i += 2; continue; }
        if (nx === "[" || nx === "(") {
          const closer = nx === "[" ? "\\]" : "\\)";
          const close = src.indexOf(closer, i + 2);
          if (close !== -1) {
            out += push(src.slice(i + 2, close), nx === "[");
            i = close + 2;
            continue;
          }
        }
        if (nx === "b" && atLineStart(src, i)) {
          const m = ENV_RE.exec(src.slice(i));
          if (m) {
            const endTag = "\\end{" + m[1] + "}";
            const close = src.indexOf(endTag, i);
            if (close !== -1) {
              out += push(src.slice(i, close + endTag.length), true);
              i = close + endTag.length;
              continue;
            }
          }
        }
        out += c + (nx === undefined ? "" : nx);
        i += 2;
        continue;
      }
      if (c === "$") {
        if (src[i + 1] === "$") {
          const close = src.indexOf("$$", i + 2);
          if (close !== -1) {
            let tex = src.slice(i + 2, close);
            if (/^[ \t]*>/.test(src.slice(src.lastIndexOf("\n", i) + 1, i))) tex = tex.replace(/^[ \t]*>[ \t]?/gm, "");
            out += push(tex, true);
            i = close + 2;
            continue;
          }
          out += "$$";
          i += 2;
          continue;
        }
        // inline $...$: no space right after the opener, no space right before the closer,
        // closer not followed by a digit (avoids "$5 and $10"), no blank line inside.
        const nx = src[i + 1];
        if (nx && nx !== " " && nx !== "\n" && nx !== "\t") {
          let j = i + 1;
          let found = -1;
          while (j < n) {
            const d = src[j];
            if (d === "\\") { j += 2; continue; }
            if (d === "\n" && src[j + 1] === "\n") break;
            if (d === "$") {
              const prev = src[j - 1];
              const after = src[j + 1];
              if (prev !== " " && prev !== "\t" && !(after && /[0-9]/.test(after))) { found = j; }
              break;
            }
            j++;
          }
          if (found !== -1 && found > i + 1) {
            out += push(src.slice(i + 1, found), false);
            i = found + 1;
            continue;
          }
        }
        out += "$";
        i += 1;
        continue;
      }
      out += c;
      i += 1;
    }
    return { text: out, maths };
  }

  function katexHTML(tex, display) {
    try {
      return window.katex.renderToString(tex, {
        displayMode: display,
        throwOnError: false,
        strict: "ignore",
        trust: false,
        output: "htmlAndMathml",
      });
    } catch (e) {
      const span = document.createElement("code");
      span.textContent = tex;
      return span.outerHTML;
    }
  }

  const PH_RE = new RegExp(PH_OPEN + "(\\d+)" + PH_CLOSE, "g");

  // Model output is untrusted: no forms (they would navigate the chat page), no global <style>,
  // no embedded frames or inline styles. Visuals get their own sandboxed iframe (chat.js).
  const PURIFY = {
    FORBID_TAGS: ["style", "form", "input", "button", "textarea", "select", "option", "iframe", "frame",
      "object", "embed", "link", "meta", "base", "dialog"],
    FORBID_ATTR: ["style"],
  };

  function renderMarkdown(src) {
    const { text, maths } = extractMath(src || "");
    const html = window.DOMPurify.sanitize(window.marked.parse(text, { gfm: true, breaks: false, async: false }), PURIFY);
    if (!maths.length) return html;
    // Swap placeholders for KaTeX in text nodes only; inside attributes (e.g. image alt) put the TeX back.
    const tpl = document.createElement("template");
    tpl.innerHTML = html;
    const walker = document.createTreeWalker(tpl.content, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT);
    const textNodes = [];
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      if (n.nodeType === Node.TEXT_NODE) {
        if (n.nodeValue.indexOf(PH_OPEN) !== -1) textNodes.push(n);
      } else {
        for (const a of Array.from(n.attributes)) {
          if (a.value.indexOf(PH_OPEN) !== -1) {
            n.setAttribute(a.name, a.value.replace(PH_RE, (_, k) => (maths[Number(k)] ? "$" + maths[Number(k)].tex + "$" : "")));
          }
        }
      }
    }
    for (const n of textNodes) {
      const span = document.createElement("span");
      const inCode = n.parentElement && n.parentElement.closest("code, pre");
      span.innerHTML = n.nodeValue.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]).replace(PH_RE, (_, k) => {
        const m = maths[Number(k)];
        if (!m) return "";
        if (inCode) return (m.display ? "$$" + m.tex + "$$" : "$" + m.tex + "$").replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]);
        return katexHTML(m.tex, m.display);
      });
      n.replaceWith(...span.childNodes);
    }
    return tpl.innerHTML;
  }

  window.CLRender = { renderMarkdown, extractMath };
})();
