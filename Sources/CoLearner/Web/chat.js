// Chat panel. Swift drives it through window.CL.*; it talks back with post({type, ...}).
(function () {
  "use strict";

  const $ = (s) => document.querySelector(s);
  const log = $("#log");
  const input = $("#input");
  const sendBtn = $("#btn-send");

  // One click = the whole slide; with an area selected, the same buttons mean that area.
  const VIS_RULES =
    "Make ONE self-contained interactive visual as a single ```html code block (inline SVG or canvas + vanilla JS, " +
    "sliders or buttons where they help, no external files). After the block, say in 2-3 sentences what to look at and what to try.";
  function quick(action) {
    const area = !!state.area;
    if (action === "explain") {
      return area
        ? { display: "Explain this area", prompt:
            "Explain the selected area of this slide (the attached crop). Start with the one-sentence takeaway. Then go through " +
            "it piece by piece: define every symbol and say in words what each equation or figure means. Relate it to the rest " +
            "of the slide only where that helps." }
        : { display: "Explain this slide", prompt:
            "Explain this slide to me. Start with the one-sentence takeaway. Then go through it piece by piece: define every " +
            "symbol, say in words what each equation or figure means, and connect it to the slides just before and after when that helps." };
    }
    return area
      ? { display: "Visualize this area", prompt: "Visualize the idea in the selected area of this slide (the attached crop). " + VIS_RULES }
      : { display: "Visualize this slide", prompt: "Visualize the key idea of this slide. " + VIS_RULES };
  }

  const NAMES = { claude: "Claude", codex: "ChatGPT" };

  // messages = the whole conversation about the deck; each carries the slide it was asked on.
  let state = { hasDeck: false, deckTitle: "", deckPath: "", page: 0, pageCount: 0, messages: [], pages: [], provider: "claude",
                conversation: null, history: [], area: null };
  let viewAll = false;   // "This slide" (default) or "All"
  function visible(m) { return viewAll || m.page == null || m.page === state.page; }
  // {claude: {models:[{id,label}], model, efforts:[...], effort}, codex: {...}} — from Swift
  let config = {};
  // {claude: {windows:[{label, percent, resetsAt}], updated}, codex: {...}} — from Swift
  let usage = {};
  const elById = new Map();
  const pendingRender = new Map();
  let rafQueued = false;
  let pendingReveal = null, highlightedMessageID = null, highlightTimer = null;

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
  /// "Claude is answering on slide 7" when that answer isn't on screen.
  function busyNote() {
    const away = state.messages.filter((m) => m.role === "assistant" && m.status === "streaming" && !visible(m));
    return away.map((m) => NAMES[m.provider] + " is answering on slide " + m.page).join(" · ");
  }

  function renderHeader() {
    $("#where-deck").textContent = state.hasDeck ? state.deckTitle : "No slides open";
    $("#where-slide").textContent = state.hasDeck ? "slide " + state.page + " / " + state.pageCount : "";
    for (const b of document.querySelectorAll("#viewseg button")) b.classList.toggle("on", (b.dataset.v === "all") === viewAll);
    $("#head-actions").hidden = !state.hasDeck;
    const others = viewAll ? [] : (state.pages || []).filter((p) => p !== state.page);
    const box = $("#others");
    const list = $("#others-list");
    const sig = others.join(",");
    if (list.dataset.sig !== sig) {
      list.dataset.sig = sig;
      list.textContent = "";
      for (const p of others) {
        const b = document.createElement("button");
        b.className = "pg";
        b.textContent = p;
        b.title = "Go to slide " + p;
        b.onclick = () => post({ type: "gotoSlide", page: p });
        list.appendChild(b);
      }
    }
    box.hidden = !others.length;
    const note = busyNote();
    const att = $("#attach");
    att.className = note ? "busynote" : "";
    att.textContent = !state.hasDeck ? "" : note ? note
      : state.area ? "The selected area of slide " + state.area.page + " goes with your next question"
      : "Slide " + state.page + " goes with your question";
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
    for (const c of document.querySelectorAll(".chip")) c.disabled = !state.hasDeck || (isBusy && c.id !== "btn-area");
    const ex = document.querySelector('.chip[data-action="explain"]'), vi = document.querySelector('.chip[data-action="visualize"]');
    ex.textContent = quick("explain").display;
    vi.textContent = quick("visualize").display;
    const ab = $("#areabox");
    if (state.area) {
      $("#area-img").src = state.area.thumb;
      $("#area-label").textContent = "Area of slide " + state.area.page;
      ab.hidden = false;
    } else ab.hidden = true;
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
    if (popEl.contains(e.target) || e.target.closest(".pickbtn") || e.target.closest("#usage") || e.target.closest("#btn-history")) return;
    closePop();
  });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && pop) { closePop(); e.stopPropagation(); } }, true);

  function el(tag, cls, text) {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }

  // ---------- search across saved chats ----------
  const searchLayer = $("#search-layer"), searchInput = $("#search-input"), searchResults = $("#search-results");
  const searchState = { open: false, query: "", requestID: 0, timer: null, returnFocus: null, opening: false };

  function searchStatus(text, error) {
    const status = $("#search-status");
    status.textContent = text;
    status.classList.toggle("error", !!error);
  }
  function setSearchBackground(inert) {
    for (const id of ["#head", "#others", "#log", "#composer"]) $(id).inert = inert;
  }
  function closeSearch(restoreFocus = true) {
    if (!searchState.open) return;
    searchState.open = false;
    searchState.opening = false;
    searchInput.disabled = false;
    searchState.requestID += 1;
    clearTimeout(searchState.timer);
    searchLayer.hidden = true;
    setSearchBackground(false);
    if (restoreFocus) {
      const target = searchState.returnFocus;
      (target && target.isConnected ? target : $("#btn-search")).focus();
    }
  }
  function queueSearch() {
    clearTimeout(searchState.timer);
    const requestID = ++searchState.requestID;
    const query = searchInput.value.trim();
    searchState.query = query;
    searchState.opening = false;
    searchInput.disabled = false;
    searchResults.textContent = "";
    if (!query) { searchStatus("Type to search your saved chats."); return; }
    searchStatus("Searching…");
    searchState.timer = setTimeout(() => {
      if (searchState.open && searchState.requestID === requestID)
        post({ type: "searchChats", query, requestID });
    }, 200);
  }
  function openSearch() {
    closePop();
    if (!searchState.open) {
      const active = document.activeElement;
      searchState.returnFocus = active && active !== document.body ? active : $("#btn-search");
    }
    searchState.open = true;
    searchLayer.hidden = false;
    setSearchBackground(true);
    queueSearch();
    searchInput.focus();
    searchInput.select();
  }
  function searchSnippet(text, query) {
    const span = el("span", "search-result-snippet");
    text = String(text || "");
    const at = text.toLocaleLowerCase().indexOf(query.toLocaleLowerCase());
    if (at < 0) { span.textContent = text; return span; }
    span.append(document.createTextNode(text.slice(0, at)), el("mark", "", text.slice(at, at + query.length)),
                document.createTextNode(text.slice(at + query.length)));
    return span;
  }
  function setSearchResults(payload) {
    if (!payload || !searchState.open || payload.requestID !== searchState.requestID || payload.query !== searchState.query) return;
    if (payload.error) {
      searchState.opening = false;
      searchInput.disabled = false;
      searchResults.querySelectorAll("button").forEach((button) => { button.disabled = false; });
      searchStatus(String(payload.error), true);
      return;
    }
    searchResults.textContent = "";
    const results = Array.isArray(payload.results) ? payload.results : [];
    searchStatus(results.length >= 100 ? "Showing the 100 newest matches" : results.length
      ? results.length + (results.length === 1 ? " result" : " results") : "No matches. Try another word or phrase.");
    for (const result of results) {
      if (!result || typeof result.id !== "string") continue;
      const button = el("button", "search-result");
      button.type = "button";
      button.appendChild(el("span", "search-result-title", result.deckTitle || "Lecture deck"));
      const metadata = [result.courseName, Number.isInteger(result.page) && result.page > 0 ? "slide " + result.page : null,
                        result.role === "user" ? "You" : NAMES[result.provider] || "Assistant"];
      if (Number.isFinite(result.created)) {
        const date = new Date(result.created * 1000);
        if (!Number.isNaN(date.getTime())) metadata.push(date.toLocaleDateString([], { month: "short", day: "numeric", year: "numeric" }));
      }
      button.appendChild(el("span", "search-result-meta", metadata.filter(Boolean).join(" · ")));
      button.appendChild(searchSnippet(result.snippet, searchState.query));
      button.onclick = () => {
        if (searchState.opening) return;
        searchState.opening = true;
        searchInput.disabled = true;
        searchResults.querySelectorAll("button").forEach((row) => { row.disabled = true; });
        searchStatus("Opening chat…");
        post({ type: "openSearchResult", id: result.id });
      };
      searchResults.appendChild(button);
    }
  }
  function revealPendingMessage() {
    if (!pendingReveal || !state.messages.some((m) => m.id === pendingReveal)) return;
    const id = pendingReveal;
    pendingReveal = null;
    log.querySelectorAll(".search-highlight").forEach((node) => node.classList.remove("search-highlight"));
    highlightedMessageID = id;
    clearTimeout(highlightTimer);
    closeSearch(false);
    if (!viewAll) { viewAll = true; pendingRender.clear(); renderAll(); }
    const target = elById.get(id);
    if (!target) return;
    target.classList.add("search-highlight");
    requestAnimationFrame(() => {
      if (elById.get(id) !== target || highlightedMessageID !== id) return;
      target.tabIndex = -1;
      target.focus({ preventScroll: true });
      target.scrollIntoView({ block: "center", behavior: "auto" });
    });
    highlightTimer = setTimeout(() => {
      if (highlightedMessageID !== id) return;
      highlightedMessageID = null;
      elById.get(id)?.classList.remove("search-highlight");
    }, 5000);
  }
  $("#btn-search").onclick = openSearch;
  $("#search-close").onclick = () => closeSearch();
  searchInput.addEventListener("input", queueSearch);
  searchLayer.addEventListener("mousedown", (e) => { if (e.target === searchLayer) closeSearch(); });
  searchLayer.addEventListener("keydown", (e) => {
    if (e.key !== "Tab") return;
    const focusable = Array.from($("#search-dialog").querySelectorAll("input:not(:disabled), button:not(:disabled)"));
    const first = focusable[0], last = focusable[focusable.length - 1];
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
  });
  document.addEventListener("keydown", (e) => {
    if (searchState.open && e.key === "Escape") { e.preventDefault(); e.stopImmediatePropagation(); closeSearch(); }
  }, true);

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
    // Preserve keyboard focus when native settings redraw the menu.
    const focused = popEl.contains(document.activeElement) ? document.activeElement : null;
    const hadSliderFocus = focused && focused.type === "range";
    const hadFastFocus = focused && focused.id === "fast-mode";
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
      if (hadSliderFocus) range.focus();
    }
    if (c.hint) popEl.appendChild(el("div", "pop-hint", c.hint));
    if (p === "codex") {
      const row = el("label", "chk fast-mode");
      const box = el("input");
      box.type = "checkbox";
      box.id = "fast-mode";
      box.checked = !!c.fastMode;
      box.onchange = () => post({ type: "setFastMode", provider: p, enabled: box.checked });
      row.append(box, el("span", "", "Fast mode"));
      popEl.appendChild(row);
      if (c.fastModeHint) {
        const hint = el("div", "pop-hint", c.fastModeHint);
        hint.id = "fast-mode-hint";
        box.setAttribute("aria-describedby", hint.id);
        popEl.appendChild(hint);
      }
      if (hadFastFocus) box.focus();
    }
    if (anchor()) placePop(anchor(), false);
  }

  function renderHistoryPop() {
    popEl.textContent = "";
    popEl.appendChild(el("div", "pop-title", "Chats about this deck"));
    const fmt = (t) => {
      const d = new Date(t * 1000), now = new Date();
      return d.toDateString() === now.toDateString()
        ? "Today " + d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })
        : d.toLocaleString([], { weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
    };
    // The open chat's row is counted from the messages on screen (the list itself is sent with the slide).
    const asked = (state.messages || []).filter((m) => m.role === "user");
    for (const h of state.history || []) {
      const count = h.current ? asked.length : h.count;
      const first = h.current && asked.length ? asked[0].display || asked[0].text.slice(0, 60) : h.first;
      const row = el("div", "hist");
      row.appendChild(el("span", "check", h.current ? "✓" : ""));
      const main = el("span", "hmain");
      main.appendChild(el("span", "hwhen", (h.legacy ? "Per-slide chats (before v0.1.5)" : fmt(h.created)) + " · " + count + (count === 1 ? " question" : " questions")));
      if (first) main.appendChild(el("span", "hfirst", first));
      row.appendChild(main);
      const del = el("button", "hdel", "Delete");
      del.onclick = (e) => { e.stopPropagation(); post({ type: "deleteChat", id: h.id }); };
      row.appendChild(del);
      row.onclick = () => { if (!h.current) post({ type: "openChat", id: h.id }); closePop(); };
      popEl.appendChild(row);
    }
    const foot = el("div", "pop-foot");
    foot.appendChild(el("span", "", "Each chat covers the whole deck."));
    const nb = el("button", "link", "New chat");
    nb.onclick = () => { post({ type: "newChat" }); closePop(); };
    foot.appendChild(nb);
    popEl.appendChild(foot);
    placePop($("#btn-history"), true);
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
      return [p, m ? m.label : c.model, e ? e.label : c.effort, p === "codex" && !!c.fastMode];
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
      if (p === "codex" && c.fastMode) b.appendChild(el("span", "pk-fast", "Fast"));
      b.appendChild(el("span", "chev", "⌄"));
      b.title = NAMES[p] + (p === "codex" ? ": choose model, effort and fast mode" : ": choose model and effort");
      b.onclick = () => {
        if (pop && pop.kind === "model" && pop.provider === p) { closePop(); return; }
        closePop();
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
    if (!state.hasDeck) {
      d.innerHTML = "Open a lecture from the bar above the slides.";
    } else if (!state.messages.length) {
      d.innerHTML = "Ask anything about <b>slide " + state.page + "</b>.<br>" +
        "This chat covers the whole deck: move between slides and keep asking; the assistants remember the conversation " +
        "and see each slide you ask on. Use ✂︎ Select area to ask about part of a slide.";
    } else {
      d.innerHTML = "Nothing asked on <b>slide " + state.page + "</b> yet in this chat.<br>Ask away: the assistants remember what you asked on the other slides.";
    }
    return d;
  }

  function legacyBanner() {
    const b = document.createElement("div");
    b.className = "banner";
    b.append("These are your per-slide chats from before v0.1.5. New questions continue here, and the assistants get them as context. ");
    const n = document.createElement("button");
    n.textContent = "Start a new chat";
    n.onclick = () => post({ type: "newChat" });
    b.appendChild(n);
    return b;
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
    el.className = "msg " + m.role + (m.provider ? " " + m.provider : "") + (m.status === "streaming" ? " streaming" : "")
      + (m.id === highlightedMessageID ? " search-highlight" : "");
    el.dataset.messageId = m.id;
    el.textContent = "";
    if (m.role === "user") {
      if (viewAll && m.page != null) {
        const tag = document.createElement("button");
        tag.className = "slidetag";
        tag.textContent = "slide " + m.page;
        tag.title = "Go to slide " + m.page;
        tag.onclick = () => post({ type: "gotoSlide", page: m.page });
        el.appendChild(tag);
      }
      const b = document.createElement("div");
      b.className = "bubble";
      if (m.areaThumb) {
        const img = document.createElement("img");
        img.className = "area";
        img.src = m.areaThumb;
        img.alt = "selected area";
        b.appendChild(img);
      }
      b.appendChild(document.createTextNode(m.display || m.text));
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
      if (window.CLSlideLinks) window.CLSlideLinks.decorate(body, {
        pageCount: state.pageCount, deckPath: state.deckPath, conversationID: state.conversation?.id,
      });
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
    if (state.conversation && state.conversation.legacy && state.messages.length) log.appendChild(legacyBanner());
    const shown = state.messages.filter(visible);
    if (!shown.length) {
      log.appendChild(emptyState());
    } else {
      for (const m of shown) {
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
      const sig = (x) => (x.conversation ? x.conversation.id : "") + "|" + (x.hasDeck ? x.deckPath : "") + "|" + x.pageCount + "|"
        + (x.hasDeck ? x.deckTitle : "") + "|"
        + (x.messages || []).map((m) => m.id + ":" + m.status + ":" + (m.text || "").length).join(",");
      const same = viewAll && (s.messages || []).length > 0 && sig(state) === sig(s);
      state = Object.assign({}, state, s);
      if (same) {   // "All" shows every slide's messages: only the header changes with the slide
        renderHeader();   // (an update queued for the next frame still lands)
        if (pop && pop.kind === "history") { if (state.hasDeck) renderHistoryPop(); else closePop(); }
        revealPendingMessage();
        return;
      }
      pendingRender.clear();
      renderAll();
      if (pop && pop.kind === "history") { if (state.hasDeck) renderHistoryPop(); else closePop(); }
      revealPendingMessage();
    },
    upsertMessage(m) {
      const i = state.messages.findIndex((x) => x.id === m.id);
      if (m.page != null && !(state.pages || []).includes(m.page)) state.pages = (state.pages || []).concat([m.page]).sort((a, b) => a - b);
      if (i === -1) {
        state.messages.push(m);
        if (m.role === "user" && pop && pop.kind === "history") renderHistoryPop();
        if (!visible(m)) { renderHeader(); return; }   // asked on another slide: kept, shown there
        const stick = nearBottom();
        if (!elById.size) { const keep = log.querySelector(".banner"); log.textContent = ""; if (keep) log.appendChild(keep); }
        const el = document.createElement("div");
        fillMessage(el, m);
        elById.set(m.id, el);
        log.appendChild(el);
        renderHeader();
        if (stick || m.role === "user") toBottom();
        return;
      }
      state.messages[i] = m;
      if (!elById.has(m.id)) { renderHeader(); return; }
      pendingRender.set(m.id, m);
      if (!rafQueued) {
        rafQueued = true;
        requestAnimationFrame(flushPending);
      }
    },
    setArea(a) {
      state.area = a || null;
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
    openSearch,
    setSearchResults,
    revealMessage(payload) {
      if (!payload || typeof payload.messageID !== "string") return;
      pendingReveal = payload.messageID;
      revealPendingMessage();
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
    const q = action ? quick(action) : null;
    const prompt = q ? q.prompt : text.trim();
    if (!prompt) return;
    post({ type: "send", text: prompt, display: q ? q.display : null, provider: state.provider, useArea: !!state.area });
    if (!q) {
      input.value = "";
      autoGrow();
    }
  }

  sendBtn.onclick = () => {
    if (busy()) post({ type: "stop", providers: asking() });
    else send(input.value);
  };
  // ← → turn slides unless a text box, menu or visual has the keys (decided here, synchronously).
  document.addEventListener("keydown", (e) => {
    if (searchState.open) return;
    if ((e.key !== "ArrowLeft" && e.key !== "ArrowRight") || e.metaKey || e.altKey || e.ctrlKey || e.shiftKey) return;
    const a = document.activeElement;
    if (a && ["TEXTAREA", "INPUT", "SELECT", "IFRAME"].includes(a.tagName)) return;
    e.preventDefault();
    post({ type: "turn", delta: e.key === "ArrowLeft" ? -1 : 1 });
  });
  log.addEventListener("click", (e) => {
    const button = e.target.closest("button.slide-ref");
    if (!button || !log.contains(button)) return;
    e.preventDefault();
    const request = { type: "gotoSlide", page: Number(button.dataset.slide), deckPath: button.dataset.deckPath,
                      conversationID: button.dataset.conversationId };
    // Keep the cited answer on screen when its source slide differs from the slide the question was asked on.
    if (!viewAll) {
      const message = button.closest(".msg"), id = message?.dataset.messageId;
      const top = message?.getBoundingClientRect().top;
      viewAll = true;
      pendingRender.clear();
      renderAll();
      const replacement = id && elById.get(id);
      if (replacement && top != null) {
        log.scrollTop += replacement.getBoundingClientRect().top - top;
        const link = Array.from(replacement.querySelectorAll("button.slide-ref")).find((node) => Number(node.dataset.slide) === request.page);
        link?.focus({ preventScroll: true });
      }
    }
    post(request);
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
  for (const c of document.querySelectorAll(".chip[data-action]")) c.onclick = () => send("", c.dataset.action);
  $("#btn-area").onclick = () => post({ type: "selectArea" });
  $("#area-clear").onclick = () => post({ type: "clearArea" });
  for (const b of document.querySelectorAll("#viewseg button"))
    b.onclick = () => { viewAll = b.dataset.v === "all"; renderAll(); };
  $("#btn-new").onclick = () => post({ type: "newChat" });
  $("#btn-history").onclick = () => {
    if (pop && pop.kind === "history") { closePop(); return; }
    closePop();
    pop = { kind: "history" };
    renderHistoryPop();
  };
  for (const b of document.querySelectorAll("#providers button"))
    b.onclick = () => {
      state.provider = b.dataset.p;
      renderHeader();
      post({ type: "setProvider", provider: b.dataset.p });
    };
  $("#usage").onclick = () => {
    const box = $("#usage");
    if (pop && pop.kind === "usage") { closePop(); return; }
    closePop();
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
