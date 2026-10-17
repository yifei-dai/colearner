// Chat panel. Swift drives it through window.CL.*; it talks back with post({type, ...}).
(function () {
  "use strict";

  const $ = (s) => document.querySelector(s);
  const log = $("#log");
  const input = $("#input");
  const sendBtn = $("#btn-send");

  const QUICK = {
    explain: {
      display: "Explain this slide",
      prompt:
        "Explain this slide to me. Start with the one-sentence takeaway. Then go through it piece by piece: " +
        "define every symbol, say in words what each equation or figure means, and connect it to the slides " +
        "just before and after when that helps.",
    },
    visualize: {
      display: "Visualize it",
      prompt:
        "Visualize the key idea of this slide. Make ONE self-contained interactive visual as a single ```html " +
        "code block (inline SVG or canvas + vanilla JS, sliders or buttons where they help, no external files). " +
        "After the block, say in 2-3 sentences what to look at and what to try.",
    },
    derive: {
      display: "Derive step by step",
      prompt:
        "Derive the main result on this slide step by step. Number the steps, justify each one in words, " +
        "and do not skip algebra. Finish with what the result means.",
    },
  };

  const NAMES = { claude: "Claude", codex: "ChatGPT" };

  let state = { hasDeck: false, deckTitle: "", page: 0, pageCount: 0, messages: [], others: [], provider: "claude" };
  // {claude: {models:[{id,label}], model, efforts:[...], effort}, codex: {...}} — from Swift
  let config = {};
  // {claude: {windows:[{label, percent, resetsAt}], updated}, codex: {...}} — from Swift
  let usage = {};
  const elById = new Map();
  const pendingRender = new Map();
  let rafQueued = false;

  function post(msg) {
    try {
      window.webkit.messageHandlers.cl.postMessage(msg);
    } catch (e) {
      console.log("[post]", JSON.stringify(msg));
    }
  }

  // ---------- rendering ----------
  function nearBottom() {
    return log.scrollHeight - log.scrollTop - log.clientHeight < 80;
  }
  function toBottom() {
    log.scrollTop = log.scrollHeight;
  }

  // Busy = an assistant you are about to ask is still answering. In Both mode Claude usually finishes
  // first; a follow-up to Claude alone shouldn't have to wait for ChatGPT.
  function asking() {
    return state.provider === "both" ? ["claude", "codex"] : [state.provider];
  }
  function busy() {
    const who = asking();
    return state.messages.some((m) => m.role === "assistant" && m.status === "streaming" && who.includes(m.provider));
  }

  function renderHeader() {
    $("#where-deck").textContent = state.hasDeck ? state.deckTitle : "No slides open";
    $("#where-slide").textContent = state.hasDeck ? "slide " + state.page + " / " + state.pageCount : "";
    const others = (state.others || []).filter((p) => p !== state.page);
    const box = $("#others");
    const list = $("#others-list");
    list.textContent = "";
    if (others.length) {
      for (const p of others) {
        const b = document.createElement("button");
        b.className = "pg";
        b.textContent = p;
        b.title = "Go to slide " + p;
        b.onclick = () => post({ type: "gotoSlide", page: p });
        list.appendChild(b);
      }
      box.hidden = false;
    } else box.hidden = true;
    $("#btn-clear").hidden = !state.messages.length;
    $("#attach").textContent = state.hasDeck
      ? state.messages.length
        ? "Chat about slide " + state.page
        : "Slide " + state.page + " is attached"
      : "";
    for (const b of document.querySelectorAll("#providers button")) {
      const on = b.dataset.p === state.provider;
      b.classList.toggle("on", on);
      b.setAttribute("aria-checked", on ? "true" : "false");
    }
    renderPickers();
    const isBusy = busy();
    sendBtn.textContent = isBusy ? "Stop" : "Send";
    sendBtn.classList.toggle("stop", isBusy);
    sendBtn.disabled = !state.hasDeck;
    for (const c of document.querySelectorAll(".chip")) c.disabled = !state.hasDeck || isBusy;
  }

  function renderPickers() {
    const box = $("#pickers");
    box.textContent = "";
    for (const p of asking()) {
      const c = config[p];
      if (!c) continue;
      const wrap = document.createElement("span");
      wrap.className = "pick " + p;
      if (state.provider === "both") {
        const who = document.createElement("span");
        who.className = "who";
        who.textContent = NAMES[p];
        wrap.appendChild(who);
      }
      const mSel = document.createElement("select");
      mSel.title = NAMES[p] + " model";
      for (const m of c.models) {
        const o = document.createElement("option");
        o.value = m.id;
        o.textContent = m.label;
        mSel.appendChild(o);
      }
      mSel.value = c.model;
      mSel.onchange = () => post({ type: "setModel", provider: p, model: mSel.value });
      const eSel = document.createElement("select");
      eSel.title = NAMES[p] + " effort (more effort = slower, more thorough)";
      for (const e of c.efforts) {
        const o = document.createElement("option");
        o.value = e;
        o.textContent = e;
        eSel.appendChild(o);
      }
      eSel.value = c.effort;
      eSel.onchange = () => post({ type: "setEffort", provider: p, effort: eSel.value });
      wrap.append(mSel, eSel);
      box.appendChild(wrap);
    }
  }

  function renderUsage() {
    const box = $("#usage");
    box.textContent = "";
    for (const p of ["claude", "codex"]) {
      const u = usage[p];
      if (!u || !u.windows || !u.windows.length) continue;
      const span = document.createElement("span");
      span.className = "u";
      const b = document.createElement("b");
      b.textContent = NAMES[p] + " ";
      span.appendChild(b);
      const tips = [];
      u.windows.forEach((w, i) => {
        const pct = Math.round(w.percent);
        const part = document.createElement("span");
        part.textContent = (i ? " · " : "") + w.label + " " + pct + "%";
        if (pct >= 95) part.className = "hot";
        else if (pct >= 80) part.className = "warn";
        span.appendChild(part);
        if (w.resetsAt) tips.push(w.label + " resets " + new Date(w.resetsAt * 1000).toLocaleString([], { weekday: "short", hour: "numeric", minute: "2-digit" }));
      });
      if (u.updated) tips.push("as of " + new Date(u.updated * 1000).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }));
      span.title = NAMES[p] + " plan usage: " + tips.join("; ");
      box.appendChild(span);
    }
  }

  function emptyState() {
    const d = document.createElement("div");
    d.className = "empty";
    if (state.hasDeck) {
      d.innerHTML =
        "Ask anything about <b>slide " + state.page + "</b>.<br>The slide image and its text go with your first question automatically.";
    } else {
      d.innerHTML = "Open a lecture from the bar above the slides.";
    }
    return d;
  }

  function makeVisual(code, lang, id) {
    const wrap = document.createElement("div");
    wrap.className = "visual";
    const bar = document.createElement("div");
    bar.className = "vbar";
    const bView = document.createElement("button");
    bView.textContent = "Visual";
    bView.className = "on";
    const bCode = document.createElement("button");
    bCode.textContent = "Code";
    const bPop = document.createElement("button");
    bPop.textContent = "Open in window";
    const grow = document.createElement("span");
    grow.className = "grow";
    bar.append(bView, bCode, grow, bPop);
    const frame = document.createElement("iframe");
    frame.setAttribute("sandbox", "allow-scripts allow-modals");
    frame.dataset.fid = id;
    frame.style.height = "200px";
    const doc = visualDoc(code, lang, id);
    frame.srcdoc = doc;
    const pre = document.createElement("pre");
    const c = document.createElement("code");
    c.textContent = code;
    pre.appendChild(c);
    pre.hidden = true;
    bView.onclick = () => { frame.hidden = false; pre.hidden = true; bView.classList.add("on"); bCode.classList.remove("on"); };
    bCode.onclick = () => { frame.hidden = true; pre.hidden = false; bCode.classList.add("on"); bView.classList.remove("on"); };
    bPop.onclick = () => post({ type: "openVisual", html: doc });
    wrap.append(bar, frame, pre);
    return wrap;
  }

  function visualDoc(code, lang, id) {
    // Reports the content height to the chat so the frame fits it. Layouts sized to the viewport
    // (100vh, innerHeight) would grow with every report, so after a few growth steps the size freezes.
    const reporter =
      "<script>(function(){var last=0,grows=0;function h(){var b=document.body;if(!b)return 0;" +
      "var r=b.getBoundingClientRect(),cs=getComputedStyle(b);" +
      "return Math.ceil(r.height+parseFloat(cs.marginTop)+parseFloat(cs.marginBottom));}" +
      "function r(){var v=h();if(!v||Math.abs(v-last)<=4)return;if(v>last&&last>0&&++grows>6)return;" +
      "last=v;parent.postMessage({clFrame:" + JSON.stringify(id) + ",h:v},'*');}" +
      "addEventListener('load',r);setTimeout(r,50);setTimeout(r,400);setTimeout(r,1500);" +
      "if(window.ResizeObserver){addEventListener('load',function(){new ResizeObserver(r).observe(document.body);});}})();<\/script>";
    const base = "<style>html,body{margin:0;height:auto}body{padding:8px;font:14px -apple-system,Helvetica,sans-serif;background:#fff;color:#111}</style>";
    let body = code;
    if (lang === "svg" && !/<html[\s>]/i.test(code)) body = "<!doctype html><html><head>" + base + "</head><body>" + code + "</body></html>";
    if (!/<html[\s>]/i.test(body)) body = "<!doctype html><html><head><meta charset='utf-8'>" + base + "</head><body>" + body + "</body></html>";
    else if (body.indexOf(base) === -1) body = body.replace(/<head(\s[^>]*)?>/i, (m) => m + base);
    if (/<head(\s[^>]*)?>/i.test(body)) body = body.replace(/<head(\s[^>]*)?>/i, (m) => m + "<meta charset='utf-8'>" + reporter);
    else body = reporter + body;
    return body;
  }

  function enhance(bodyEl, m) {
    const blocks = bodyEl.querySelectorAll("pre > code");
    let k = 0;
    for (const code of blocks) {
      const cls = code.className || "";
      const lm = /language-(html|svg|visual)\b/.exec(cls);
      const pre = code.parentElement;
      if (lm) {
        if (m.status === "streaming") {
          const ph = document.createElement("div");
          ph.className = "visual";
          ph.innerHTML = '<div class="vbar">Building a visual… ' + code.textContent.split("\n").length + " lines</div>";
          pre.replaceWith(ph);
        } else {
          pre.replaceWith(makeVisual(code.textContent, lm[1], m.id + ":" + k++));
        }
      }
    }
    for (const a of bodyEl.querySelectorAll("a[href]")) {
      a.addEventListener("click", (e) => {
        e.preventDefault();
        post({ type: "openLink", url: a.getAttribute("href") });
      });
    }
  }

  function fillMessage(el, m) {
    el.className = "msg " + m.role + (m.provider ? " " + m.provider : "") + (m.status === "streaming" ? " streaming" : "");
    el.textContent = "";
    if (m.role === "user") {
      const b = document.createElement("div");
      b.className = "bubble";
      b.textContent = m.display || m.text;
      el.appendChild(b);
      return;
    }
    const who = document.createElement("div");
    who.className = "who";
    const dot = document.createElement("span");
    dot.className = "dot";
    const name = document.createElement("span");
    name.textContent = NAMES[m.provider] || m.provider || "Assistant";
    who.append(dot, name);
    if (m.model) {
      const md = document.createElement("span");
      md.className = "model";
      md.textContent = m.model;
      who.appendChild(md);
    }
    if (m.status === "streaming") {
      const act = document.createElement("span");
      act.className = "activity";
      act.textContent = m.activity || (m.text ? "" : "thinking…");
      who.appendChild(act);
    } else if (m.status === "stopped") {
      const act = document.createElement("span");
      act.className = "activity";
      act.textContent = "stopped";
      who.appendChild(act);
    }
    el.appendChild(who);
    const body = document.createElement("div");
    body.className = "body";
    if (m.text) {
      body.innerHTML = window.CLRender.renderMarkdown(m.text);
      enhance(body, m);
    }
    el.appendChild(body);
    if (m.error) {
      const er = document.createElement("div");
      er.className = "err";
      er.textContent = m.error;
      el.appendChild(er);
    }
    if (m.status !== "streaming" && m.text) {
      const tools = document.createElement("div");
      tools.className = "tools";
      const cp = document.createElement("button");
      cp.textContent = "Copy";
      cp.onclick = () => { post({ type: "copy", text: m.text }); cp.textContent = "Copied"; setTimeout(() => (cp.textContent = "Copy"), 1200); };
      tools.appendChild(cp);
      el.appendChild(tools);
    }
  }

  function renderAll() {
    elById.clear();
    log.textContent = "";
    if (!state.messages.length) {
      log.appendChild(emptyState());
    } else {
      for (const m of state.messages) {
        const el = document.createElement("div");
        fillMessage(el, m);
        elById.set(m.id, el);
        log.appendChild(el);
      }
    }
    renderHeader();
    toBottom();
  }

  function flushPending() {
    rafQueued = false;
    const stick = nearBottom();
    for (const [id, m] of pendingRender) {
      const el = elById.get(id);
      if (el) fillMessage(el, m);
    }
    pendingRender.clear();
    renderHeader();
    if (stick) toBottom();
  }

  // ---------- API for Swift ----------
  window.CL = {
    setThread(s) {
      state = Object.assign({}, state, s);
      pendingRender.clear();
      renderAll();
    },
    upsertMessage(m) {
      const i = state.messages.findIndex((x) => x.id === m.id);
      if (i === -1) {
        const stick = nearBottom();
        if (!state.messages.length) log.textContent = "";
        state.messages.push(m);
        const el = document.createElement("div");
        fillMessage(el, m);
        elById.set(m.id, el);
        log.appendChild(el);
        renderHeader();
        if (stick || m.role === "user") toBottom();
        return;
      }
      state.messages[i] = m;
      pendingRender.set(m.id, m);
      if (!rafQueued) {
        rafQueued = true;
        requestAnimationFrame(flushPending);
      }
    },
    setOthers(pages) {
      state.others = pages || [];
      renderHeader();
    },
    setProvider(p) {
      state.provider = p;
      renderHeader();
    },
    setConfig(c) {
      config = c || {};
      renderPickers();
    },
    setUsage(u) {
      usage = u || {};
      renderUsage();
    },
    focusInput() {
      input.focus();
    },
    insertText(t) {
      input.value = (input.value ? input.value + "\n" : "") + t;
      autoGrow();
      input.focus();
    },
  };

  // ---------- events ----------
  function send(text, action) {
    if (!state.hasDeck) return;
    if (busy()) return;
    const q = action ? QUICK[action] : null;
    const prompt = q ? q.prompt : text.trim();
    if (!prompt) return;
    post({ type: "send", text: prompt, display: q ? q.display : null, provider: state.provider });
    if (!q) {
      input.value = "";
      autoGrow();
    }
  }

  sendBtn.onclick = () => {
    if (busy()) post({ type: "stop" });
    else send(input.value);
  };
  // ← → turn slides unless a text box, menu or visual has the keys (decided here, synchronously).
  document.addEventListener("keydown", (e) => {
    if ((e.key !== "ArrowLeft" && e.key !== "ArrowRight") || e.metaKey || e.altKey || e.ctrlKey || e.shiftKey) return;
    const a = document.activeElement;
    if (a && ["TEXTAREA", "INPUT", "SELECT", "IFRAME"].includes(a.tagName)) return;
    e.preventDefault();
    post({ type: "turn", delta: e.key === "ArrowLeft" ? -1 : 1 });
  });

  input.addEventListener("keydown", (e) => {
    if (e.key === "Escape") {
      input.blur();
      return;
    }
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing && e.keyCode !== 229) {
      e.preventDefault();
      send(input.value);
    }
  });
  function autoGrow() {
    input.style.height = "auto";
    input.style.height = Math.min(input.scrollHeight, 180) + "px";
  }
  input.addEventListener("input", autoGrow);
  for (const c of document.querySelectorAll(".chip")) c.onclick = () => send("", c.dataset.action);
  for (const b of document.querySelectorAll("#providers button"))
    b.onclick = () => {
      state.provider = b.dataset.p;
      renderHeader();
      post({ type: "setProvider", provider: b.dataset.p });
    };
  $("#btn-clear").onclick = () => post({ type: "clearThread" });

  window.addEventListener("message", (e) => {
    const d = e.data;
    if (!d || typeof d !== "object" || !d.clFrame) return;
    const stick = nearBottom();
    for (const f of document.querySelectorAll("iframe[data-fid]")) {
      if (f.dataset.fid === d.clFrame) f.style.height = Math.min(Math.max(d.h, 60), 900) + "px";
    }
    if (stick) toBottom();
  });

  renderAll();
  post({ type: "ready" });
})();
