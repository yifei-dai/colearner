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

  let state = { hasDeck: false, deckTitle: "", page: 0, pageCount: 0, messages: [], others: [], provider: "claude", models: {} };
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

  function busy() {
    return state.messages.some((m) => m.role === "assistant" && m.status === "streaming");
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
    const isBusy = busy();
    sendBtn.textContent = isBusy ? "Stop" : "Send";
    sendBtn.classList.toggle("stop", isBusy);
    sendBtn.disabled = !state.hasDeck;
    for (const c of document.querySelectorAll(".chip")) c.disabled = !state.hasDeck || isBusy;
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
    frame.style.height = "260px";
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
    const reporter =
      "<script>(function(){var last=0;function r(){var h=Math.ceil(Math.max(document.documentElement.scrollHeight,document.body?document.body.scrollHeight:0));" +
      "if(Math.abs(h-last)>4){last=h;parent.postMessage({clFrame:" + JSON.stringify(id) + ",h:h},'*');}}" +
      "addEventListener('load',r);setTimeout(r,50);setTimeout(r,400);setTimeout(r,1500);" +
      "if(window.ResizeObserver){new ResizeObserver(r).observe(document.documentElement);}})();<\/script>";
    const base = "<style>html,body{margin:0;padding:8px;font:14px -apple-system,Helvetica,sans-serif;background:#fff;color:#111}</style>";
    let body = code;
    if (lang === "svg" && !/<html[\s>]/i.test(code)) body = "<!doctype html><html><head>" + base + "</head><body>" + code + "</body></html>";
    if (!/<html[\s>]/i.test(body)) body = "<!doctype html><html><head><meta charset='utf-8'>" + base + "</head><body>" + body + "</body></html>";
    if (/<head[^>]*>/i.test(body)) body = body.replace(/<head[^>]*>/i, (m) => m + "<meta charset='utf-8'>" + reporter);
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
  input.addEventListener("keydown", (e) => {
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
    for (const f of document.querySelectorAll("iframe[data-fid]")) {
      if (f.dataset.fid === d.clFrame) f.style.height = Math.min(Math.max(d.h, 80), 900) + "px";
    }
  });

  renderAll();
  post({ type: "ready" });
})();
