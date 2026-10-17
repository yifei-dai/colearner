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

  // Page errors go to the app's log (Console.app / stderr) instead of disappearing.
  window.addEventListener("error", (e) => post({ type: "jsError", message: String(e.message) + " @" + e.lineno + ":" + e.colno }));

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

  // ---------- model menu and usage card (popovers) ----------
  let pop = null; // {kind:'model', provider} | {kind:'usage'}
  const popEl = document.createElement("div");
  popEl.className = "pop";
  popEl.hidden = true;
  document.body.appendChild(popEl);

  function closePop() {
    pop = null;
    popEl.hidden = true;
    document.querySelectorAll(".pickbtn.open, #usage.open").forEach((b) => b.classList.remove("open"));
  }
  function placePop(anchor, alignRight) {
    const r = anchor.getBoundingClientRect();
    popEl.hidden = false;
    const w = popEl.offsetWidth, h = popEl.offsetHeight;
    let left = alignRight ? r.right - w : r.left;
    left = Math.max(8, Math.min(left, window.innerWidth - w - 8));
    let top = r.top - h - 6;
    if (top < 8) top = Math.min(r.bottom + 6, window.innerHeight - h - 8);
    popEl.style.left = left + "px";
    popEl.style.top = Math.max(8, top) + "px";
  }
  document.addEventListener("mousedown", (e) => {
    if (!pop) return;
    if (popEl.contains(e.target) || e.target.closest(".pickbtn") || e.target.closest("#usage")) return;
    closePop();
  });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && pop) { closePop(); e.stopPropagation(); } }, true);

  function el(tag, cls, text) {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }

  // While the effort slider is being dragged, redraws wait until the mouse is released.
  let dragging = false, redrawAfterDrag = null;
  document.addEventListener("pointerup", () => {
    if (!dragging) return;
    dragging = false;
    const q = redrawAfterDrag;
    redrawAfterDrag = null;
    if (q && pop && pop.kind === "model" && pop.provider === q) renderModelPop(q);
  }, true);

  function renderModelPop(p) {
    const c = config[p];
    if (!c) return;
    // The model buttons are redrawn often; always anchor to the one on screen now.
    const anchor = () => document.querySelector(".pickbtn." + p);
    if (dragging) { redrawAfterDrag = p; return; }
    // Keep keyboard focus on the slider across a redraw (arrow keys step the effort).
    const hadFocus = !!document.activeElement && document.activeElement.type === "range" && popEl.contains(document.activeElement);
    popEl.textContent = "";
    if (pop && pop.edit) {
      // Choose which models appear in the menu. The list itself comes from the tool and refreshes at launch.
      popEl.appendChild(el("div", "pop-title", "Show in the " + NAMES[p] + " menu"));
      for (const m of c.models) {
        const row = el("label", "chk");
        const box = el("input");
        box.type = "checkbox";
        box.checked = !m.hidden;
        box.onchange = () => post({ type: "setModelVisible", provider: p, model: m.id, visible: box.checked });
        row.appendChild(box);
        row.appendChild(el("span", "", m.label));
        if (m.isNew) row.appendChild(el("span", "badge", "New"));
        popEl.appendChild(row);
      }
      const foot = el("div", "pop-foot");
      const when = c.updated ? new Date(c.updated * 1000).toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }) : "not yet";
      foot.appendChild(el("span", "", "List from " + (p === "claude" ? "Claude Code" : "Codex") + ", updated " + when));
      const refresh = el("button", "refresh", c.refreshing ? "Refreshing…" : "↻ Refresh list");
      refresh.disabled = !!c.refreshing;
      refresh.title = "Ask Claude Code and Codex for their current models (also done at every launch)";
      refresh.onclick = () => post({ type: "refreshModels" });
      foot.appendChild(refresh);
      const done = el("button", "link", "Done");
      done.onclick = () => { pop.edit = false; renderModelPop(p); };
      foot.appendChild(done);
      popEl.appendChild(foot);
      if (anchor()) placePop(anchor(), false);
      return;
    }
    popEl.appendChild(el("div", "pop-title", NAMES[p] + " model"));
    for (const m of c.models) {
      if (m.hidden && m.id !== c.model) continue;
      const b = el("button", "opt" + (m.id === c.model ? " on" : ""));
      b.appendChild(el("span", "check", m.id === c.model ? "✓" : ""));
      b.appendChild(el("span", "opt-name", m.label));
      if (m.isNew) b.appendChild(el("span", "badge", "New"));
      b.onclick = () => post({ type: "setModel", provider: p, model: m.id });
      popEl.appendChild(b);
    }
    const edit = el("button", "link more", "Choose models…");
    edit.onclick = () => { pop.edit = true; renderModelPop(p); };
    popEl.appendChild(edit);

    // Effort: a slider with one stop per level.
    const n = c.efforts.length;
    let idx = Math.max(0, c.efforts.findIndex((e) => e.id === c.effort));
    const head = el("div", "pop-title effort-title");
    const name = el("span", "effort-now", c.efforts[idx] ? c.efforts[idx].label : "");
    head.append(el("span", "", "Effort"), name);
    popEl.appendChild(head);
    if (n > 1) {
      const wrap = el("div", "slider");
      const range = el("input");
      range.type = "range";
      range.min = "0";
      range.max = String(n - 1);
      range.step = "1";
      range.value = String(idx);
      range.oninput = () => { name.textContent = c.efforts[+range.value].label; ticks.querySelectorAll("span").forEach((t, i) => t.classList.toggle("on", i === +range.value)); };
      range.onchange = () => post({ type: "setEffort", provider: p, effort: c.efforts[+range.value].id });
      const ticks = el("div", "ticks");
      c.efforts.forEach((e, i) => {
        const t = el("span", i === idx ? "on" : "", e.label);
        t.onclick = () => { range.value = String(i); range.oninput(); range.onchange(); };
        ticks.appendChild(t);
      });
      range.addEventListener("pointerdown", () => { dragging = true; });
      wrap.append(range, ticks);
      popEl.appendChild(wrap);
      if (hadFocus) range.focus();
    }
    if (c.hint) popEl.appendChild(el("div", "pop-hint", c.hint));
    if (anchor()) placePop(anchor(), false);
  }

  function resetText(w) {
    if (w.resetsAt) {
      const d = new Date(w.resetsAt * 1000), now = new Date();
      const mins = Math.max(0, Math.round((d - now) / 60000));
      const rel = mins < 60 ? mins + " min" : mins < 1440 ? Math.floor(mins / 60) + " h " + (mins % 60) + " min" : Math.round(mins / 1440) + " days";
      const abs = d.toDateString() === now.toDateString()
        ? d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })
        : d.toLocaleString([], { weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
      return "Resets in " + rel + " (" + abs + ")";
    }
    return w.resetsText ? "Resets " + w.resetsText : "";
  }

  function renderUsagePop(anchor) {
    popEl.textContent = "";
    const head = el("div", "pop-head");
    head.appendChild(el("span", "pop-title", "Plan usage"));
    const loading = ["claude", "codex"].some((p) => usage[p] && usage[p].loading);
    const rb = el("button", "refresh", loading ? "Updating…" : "↻ Refresh");
    rb.disabled = loading;
    rb.onclick = () => post({ type: "refreshUsage", force: true });
    head.appendChild(rb);
    popEl.appendChild(head);
    let newest = 0;
    for (const p of ["claude", "codex"]) {
      const u = usage[p];
      const sec = el("div", "u-sec");
      const name = el("div", "u-name " + p, NAMES[p]);
      if (u && u.plan) name.appendChild(el("span", "plan", u.plan));
      sec.appendChild(name);
      if (u && u.windows && u.windows.length) {
        for (const w of u.windows) {
          const pct = Math.round(w.percent);
          const row = el("div", "u-row");
          const top = el("div", "u-top");
          top.appendChild(el("span", "", w.title || w.label));
          top.appendChild(el("span", "u-pct" + (pct >= 95 ? " hot" : pct >= 80 ? " warn" : ""), pct + "% used"));
          row.appendChild(top);
          const bar = el("div", "bar");
          const fill = el("div", "fill" + (pct >= 95 ? " hot" : pct >= 80 ? " warn" : ""));
          fill.style.width = Math.min(100, Math.max(0, w.percent)) + "%";
          bar.appendChild(fill);
          row.appendChild(bar);
          const rt = resetText(w);
          if (rt) row.appendChild(el("div", "u-reset", rt));
          sec.appendChild(row);
        }
        newest = Math.max(newest, u.updated || 0);
      } else {
        sec.appendChild(el("div", "u-reset", u && u.loading ? "Checking…" : (u && u.error) || "No data yet."));
      }
      if (u && u.error && u.windows && u.windows.length) sec.appendChild(el("div", "u-err", "Last refresh failed: " + u.error));
      popEl.appendChild(sec);
    }
    if (newest) popEl.appendChild(el("div", "u-foot", "Updated " + new Date(newest * 1000).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }) + " · also refreshed after every answer"));
    placePop(anchor, true);
  }

  // `refreshPop`: redraw an open model menu too (when the choices changed), not on every chat update.
  let pickSig = null;
  function renderPickers(refreshPop) {
    const box = $("#pickers");
    const sig = JSON.stringify(asking().map((p) => {
      const c = config[p];
      if (!c) return null;
      const m = c.models.find((x) => x.id === c.model), e = c.efforts.find((x) => x.id === c.effort);
      return [p, m ? m.label : c.model, e ? e.label : c.effort];
    }));
    if (sig === pickSig) {
      // Same buttons: only update which one is open (a rebuilt button would swallow a click in progress).
      for (const b of box.querySelectorAll(".pickbtn")) b.classList.toggle("open", !!(pop && pop.kind === "model" && b.classList.contains(pop.provider)));
    } else {
    pickSig = sig;
    box.textContent = "";
    for (const p of asking()) {
      const c = config[p];
      if (!c) continue;
      const m = c.models.find((x) => x.id === c.model);
      const e = c.efforts.find((x) => x.id === c.effort);
      const b = el("button", "pickbtn " + p + (pop && pop.kind === "model" && pop.provider === p ? " open" : ""));
      b.appendChild(el("span", "dot"));
      b.appendChild(el("span", "pk-model", m ? m.label : c.model));
      b.appendChild(el("span", "pk-effort", e ? e.label : c.effort));
      b.appendChild(el("span", "chev", "⌄"));
      b.title = NAMES[p] + ": choose model and effort";
      b.onclick = () => {
        if (pop && pop.kind === "model" && pop.provider === p) { closePop(); return; }
        pop = { kind: "model", provider: p, edit: false };
        renderPickers();
        renderModelPop(p);
      };
      box.appendChild(b);
    }
    }
    if (pop && pop.kind === "model") {
      const anchor = box.querySelector(".pickbtn." + pop.provider);
      if (!anchor || !config[pop.provider]) closePop();
      else if (refreshPop) renderModelPop(pop.provider);
    }
  }

  function renderUsage() {
    const box = $("#usage");
    box.textContent = "";
    let any = false;
    for (const p of ["claude", "codex"]) {
      const u = usage[p];
      if (!u || !u.windows || !u.windows.length) continue;
      any = true;
      const span = el("span", "u");
      span.appendChild(el("b", "", NAMES[p] + " "));
      u.windows.slice(0, 2).forEach((w, i) => {
        const pct = Math.round(w.percent);
        span.appendChild(el("span", pct >= 95 ? "hot" : pct >= 80 ? "warn" : "", (i ? " · " : "") + w.label + " " + pct + "%"));
      });
      box.appendChild(span);
    }
    if (!any) box.appendChild(el("span", "", "Usage"));
    box.appendChild(el("span", "chev", "⌃"));
    if (pop && pop.kind === "usage") renderUsagePop(box);
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
      renderPickers(true);
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
  $("#usage").onclick = () => {
    const box = $("#usage");
    if (pop && pop.kind === "usage") { closePop(); return; }
    pop = { kind: "usage" };
    box.classList.add("open");
    renderUsagePop(box);
    post({ type: "refreshUsage", force: false });
  };

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
