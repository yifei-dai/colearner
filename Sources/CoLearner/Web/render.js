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
            out += push(src.slice(i + 2, close), true);
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

  function renderMarkdown(src) {
    const { text, maths } = extractMath(src || "");
    let html = window.marked.parse(text, { gfm: true, breaks: false, async: false });
    html = window.DOMPurify.sanitize(html, { ADD_ATTR: ["target"] });
    html = html.replace(PH_RE, (_, k) => {
      const m = maths[Number(k)];
      if (!m) return "";
      return katexHTML(m.tex, m.display);
    });
    return html;
  }

  window.CLRender = { renderMarkdown, extractMath };
})();
