window.__ModuleLoader__.load({ id: "dsh-chat-panel", factory: (require) => {
  var module = { exports: {} }; var exports = module.exports;

  /**
   * dsh-chat-panel -- client half.
   *
   * Adds a "Web Chat" entry to the sidebar footer that asks the host half to
   * arrange the windows (DSH left 2/3, chat.deepseek.com right 1/3). The host
   * half owns all window work because a page cannot reposition top-level
   * browser windows.
   *
   * Mounting strategy
   * -----------------
   * Two layers, deliberately:
   *   1. Register a component into the official `sidebar.footer.action` slot.
   *      That gives us a real mount point plus a re-render tick, and keeps the
   *      plugin honest about the harness lifecycle.
   *   2. Inside that component, insert the actual button next to the sidebar's
   *      New Session control via DOM, because that control is hard-coded and
   *      exposes no slot of its own. Matching is by label text across the
   *      locales the harness ships, then by aria-label.
   *
   * If neither layer finds a home the plugin stays silent. Add
   * `?dshchatdiag=1` to the page URL to get console diagnostics.
   */

  var OPEN_URL = "/dsh-chat-panel/open";
  var CLOSE_URL = "/dsh-chat-panel/close";
  var STATE_URL = "/dsh-chat-panel/state";
  var ENTRY_ID = "dsh-chat-panel-entry";

  var LABELS = ["new session", "new chat", "\u65B0\u5BF9\u8BDD", "\u65B0\u5EFA\u4F1A\u8BDD", "\u65B0\u4F1A\u8BDD"];
  // Button labels. The entry is a switch, not a one-way launcher: when the chat
  // pane is open it says so and closes it, and closing is routed through the
  // host so DSH can widen first and the chat can be torn down while covered.
  var BTN_OPEN = "DeepSeek";                              // DeepSeek
  var BTN_CLOSE = "\u5173\u95ED chat.deepseek";            // 关闭 chat.deepseek
  
  var DIAG = typeof location !== "undefined" && String(location.search).indexOf("dshchatdiag=1") >= 0;
  function diag() {
    if (!DIAG) return;
    try { console.info("[dsh-chat-panel]", arguments.length === 1 ? arguments[0] : Array.prototype.slice.call(arguments)); } catch (e) { }
  }

  function findNewSessionButton() {
    var buttons = document.querySelectorAll("button");
    var i, b, t;
    for (i = 0; i < buttons.length; i++) {
      b = buttons[i];
      t = (b.textContent || "").trim();
      if (!t) continue;
      var lower = t.toLowerCase();
      for (var j = 0; j < LABELS.length; j++) {
        var n = LABELS[j];
        if (t === n || t.indexOf(n) === 0 || lower === n || lower.indexOf(n) === 0) return b;
      }
    }
    for (i = 0; i < buttons.length; i++) {
      b = buttons[i];
      var aria = String(b.getAttribute("aria-label") || "").toLowerCase();
      if (!aria) continue;
      for (var k = 0; k < LABELS.length; k++) {
        if (aria.indexOf(LABELS[k]) >= 0 && (b.textContent || "").trim()) return b;
      }
    }
    return null;
  }

  function buildEntry() {
    var host = document.createElement("div");
    host.id = ENTRY_ID;
    host.style.cssText = "display:flex;box-sizing:border-box;flex:none;align-items:stretch;margin:0 2px 10px";

    // A real <button>, not <a href="javascript:void(0)">. Some page policies
    // reject javascript: URLs outright, and a button has no navigation default
    // to fight in the first place.
    var a = document.createElement("button");
    a.type = "button";
    a.title = BTN_OPEN;
    a.style.cssText =
      "flex:1;min-width:0;display:flex;align-items:center;justify-content:center;box-sizing:border-box;" +
      "gap:6px;padding:0 8px;height:38px;border:1px solid var(--dsw-alias-border-l2, rgba(128,128,128,.35));" +
      "border-radius:12px;background:var(--dsw-alias-button-elevated-fill, transparent);" +
      "color:var(--dsw-alias-label-primary, inherit);cursor:pointer;font-family:inherit;font-size:14px;" +
      "font-weight:500;line-height:22px;text-decoration:none;white-space:nowrap;overflow:hidden";

    var icon = document.createElement("span");
    icon.setAttribute("aria-hidden", "true");
    icon.style.cssText = "flex:none;display:flex";
    icon.innerHTML =
      '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" ' +
      'stroke-linecap="round" stroke-linejoin="round"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>' +
      '<path d="M8.5 9.5h7M8.5 13h4.5"/></svg>';

    var label = document.createElement("span");
    label.textContent = BTN_OPEN;

    a.appendChild(icon);
    a.appendChild(label);
    host.appendChild(a);

    a.addEventListener("mouseenter", function () {
      a.style.background = "var(--dsw-alias-button-floating-hover, rgba(128,128,128,.18))";
    });
    a.addEventListener("mouseleave", function () {
      a.style.background = "var(--dsw-alias-button-elevated-fill, transparent)";
    });

    // ---- state ------------------------------------------------------------
    // `open` drives both the label and which route a click hits. It is refreshed
    // by polling the host rather than tracked locally, so it stays correct after
    // a page refresh, a Ctrl+Alt+D toggle, or the chat being closed by its own X.
    var isOpen = false;

    function paint(text) {
      label.textContent = text;
      a.title = text;
    }

    function applyState(open) {
      isOpen = !!open;
      paint(isOpen ? BTN_CLOSE : BTN_OPEN);
    }

    function refreshState() {
      try {
        fetch(STATE_URL, { credentials: "same-origin", cache: "no-store" })
          .then(function (r) { return r && r.ok ? r.json() : null; })
          .then(function (j) { if (j && typeof j.open === "boolean") applyState(j.open); },
                function () { /* keep the last known state */ });
      } catch (err) { /* keep the last known state */ }
    }

    var pollTimer = null;
    function startPolling() {
      if (pollTimer) return;
      refreshState();
      pollTimer = setInterval(function () {
        if (!document.getElementById(ENTRY_ID)) { clearInterval(pollTimer); pollTimer = null; return; }
        refreshState();
      }, 2000);
    }

    var inFlight = false;
    function fire(e) {
      if (e) { e.preventDefault(); e.stopPropagation(); }
      if (inFlight) return;
      inFlight = true;

      var wantOpen = !isOpen;
      var url = wantOpen ? OPEN_URL : CLOSE_URL;
      diag("clicked; state=", isOpen, "-> posting", url);

      // Visible acknowledgement first: if this text does not change on click,
      // the event never reached the handler and the fault is above this code.
      paint(wantOpen ? "\u6B63\u5728\u6253\u5F00\u2026" : "\u6B63\u5728\u5173\u95ED\u2026"); // 正在打开… / 正在关闭…
      a.style.opacity = ".6";

      var done = function () {
        a.style.opacity = "";
        inFlight = false;
        // Re-read the truth rather than assuming the request took effect.
        refreshState();
      };

      // Last resort when the host route is unreachable. Only meaningful for the
      // opening direction -- there is no protocol handler that closes the pane.
      var fallback = function (why) {
        diag("falling back to dshsplit: because", why);
        if (wantOpen) {
          try { window.location.href = "dshsplit:open"; } catch (err) { diag("fallback failed", String(err)); }
        }
        done();
      };

      try {
        fetch(url, {
          method: "POST",
          credentials: "same-origin",
          headers: { "content-type": "application/json" },
          body: "{}",
        }).then(function (r) {
          diag("host responded", r && r.status);
          if (!r || !r.ok) fallback("status " + (r && r.status));
          else done();
        }, function (err) {
          fallback("fetch rejected: " + String(err));
        });
      } catch (err) {
        fallback("fetch threw: " + String(err));
      }
    }

    a.addEventListener("click", fire);
    a.addEventListener("keydown", function (e) {
      if (e.key === "Enter" || e.key === " ") fire(e);
    });

    // Begin tracking the host's real state so the label is right from the first
    // paint, and stays right if the pane is toggled or closed elsewhere.
    startPolling();

    return host;
  }

  function mountOnce() {
    try {
      if (document.getElementById(ENTRY_ID)) return true;
      var target = findNewSessionButton();
      if (!target) return false;
      var parent = target.parentNode;
      if (!parent) return false;
      var entry = buildEntry();
      if (target.nextSibling) parent.insertBefore(entry, target.nextSibling);
      else parent.appendChild(entry);
      diag("entry mounted next to New Session");
      return true;
    } catch (err) {
      diag("mount failed", String(err));
      return true;
    }
  }

  function startMounting() {
    var tries = 0;
    var timer = null;
    var obs = null;
    function stop() {
      if (timer) { clearInterval(timer); timer = null; }
      if (obs) { try { obs.disconnect(); } catch (e) { } obs = null; }
    }
    function attempt() {
      tries++;
      if (mountOnce() || tries > 200) stop();
    }
    try {
      attempt();
      if (!document.getElementById(ENTRY_ID)) {
        timer = setInterval(attempt, 250);
        obs = new MutationObserver(attempt);
        obs.observe(document.body, { childList: true, subtree: true });
      }
    } catch (err) {
      diag("observer setup failed", String(err));
    }
  }

  var inject = ["slots"];

  function apply(ctx) {
    try {
      diag("apply; services:", { slots: !!ctx.slots });
      // Track sidebar width changes: the button should ride the rail collapse.
      try {
        ctx.slots.inject("sidebar.footer.action", function () {
          ctx.slots.register(
            { name: "sidebar.footer.action", id: "chat-panel-entry", order: 20 },
            function SidebarEntry() { return null; }
          );
        });
      } catch (err) {
        diag("slot registration failed; falling back to DOM only", String(err));
      }
      if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", startMounting);
      } else {
        startMounting();
      }
    } catch (err) {
      diag("apply failed", String(err));
    }
  }

  module.exports = { apply: apply, inject: inject };
  return module.exports; } });
