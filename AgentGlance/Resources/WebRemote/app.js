// AgentGlance Web Remote — vanilla JS client

(function () {
  'use strict';

  const TOKEN_KEY = 'agentglance_token';
  let ws = null;
  let sessions = {};
  let reconnectDelay = 1000;
  let reconnectTimer = null;
  let initialLoadDone = false;
  let renderCount = 0;
  let wsMessageCount = 0;
  let pollCount = 0;
  const debugLabel = document.getElementById('debug-label');

  // --- DOM refs ---
  const pairingScreen = document.getElementById('pairing-screen');
  const mainScreen = document.getElementById('main-screen');
  const sessionsEl = document.getElementById('sessions');
  const emptyState = document.getElementById('empty-state');
  const loadingState = document.getElementById('loading-state');
  const settingsBtn = document.getElementById('settings-btn');
  const settingsPanel = document.getElementById('settings-panel');
  const wakelockToggle = document.getElementById('wakelock-toggle');
  const disconnectBtn = document.getElementById('disconnect-btn');
  const connectionDot = document.getElementById('connection-dot');
  const pairBtn = document.getElementById('pair-btn');
  const pairError = document.getElementById('pair-error');
  const codeInputsEl = document.getElementById('code-inputs');

  // --- Init ---
  setupCodeInputs();
  var token = localStorage.getItem(TOKEN_KEY);
  if (token) {
    showMain();
    // Fetch sessions via HTTP for instant render, WS connects in parallel for live updates
    fetchInitialSessions();
    connectWebSocket(token);
  } else {
    showPairing();
  }

  function fetchInitialSessions() {
    var t = localStorage.getItem(TOKEN_KEY);
    if (!t) return;
    fetch('/api/status', { headers: { 'Authorization': 'Bearer ' + t } })
      .then(function (r) {
        if (!r.ok) return null;
        return r.json();
      })
      .then(function (data) {
        if (data && data.sessions && data.sessions.length > 0 && Object.keys(sessions).length === 0) {
          for (var i = 0; i < data.sessions.length; i++) {
            sessions[data.sessions[i].id] = data.sessions[i];
          }
          groupMode = data.groupMode || 'none';
          sortMode = data.sortMode || 'lastUpdated';
          serverGroups = data.groups || null;
          if (data.rowTitleFormat) rowTitleFormat = data.rowTitleFormat;
          if (data.rowDetailFormat) rowDetailFormat = data.rowDetailFormat;
          renderSessions();
        }
      })
      .catch(function () { /* WS will handle it */ });
  }

  // --- Pairing ---

  function setupCodeInputs() {
    for (let i = 0; i < 6; i++) {
      const input = document.createElement('input');
      input.type = 'tel';
      input.maxLength = 1;
      input.inputMode = 'numeric';
      input.pattern = '[0-9]';
      input.dataset.index = i;

      input.addEventListener('input', function () {
        this.value = this.value.replace(/\D/g, '');
        if (this.value && i < 5) {
          codeInputsEl.children[i + 1].focus();
        }
        updatePairButton();
      });

      input.addEventListener('keydown', function (e) {
        if (e.key === 'Backspace' && !this.value && i > 0) {
          codeInputsEl.children[i - 1].focus();
        }
        if (e.key === 'Enter') {
          attemptPairing();
        }
      });

      // Handle paste of full code
      input.addEventListener('paste', function (e) {
        e.preventDefault();
        const text = (e.clipboardData || window.clipboardData).getData('text').replace(/\D/g, '');
        for (let j = 0; j < Math.min(text.length, 6); j++) {
          codeInputsEl.children[j].value = text[j];
        }
        if (text.length >= 6) {
          codeInputsEl.children[5].focus();
        }
        updatePairButton();
      });

      codeInputsEl.appendChild(input);
    }
  }

  function getCode() {
    let code = '';
    for (const input of codeInputsEl.children) {
      code += input.value;
    }
    return code;
  }

  function updatePairButton() {
    pairBtn.disabled = getCode().length !== 6;
  }

  pairBtn.addEventListener('click', attemptPairing);

  function getDeviceName() {
    var ua = navigator.userAgent;
    // Try to extract a meaningful device name
    if (/iPhone/.test(ua)) return 'iPhone';
    if (/iPad/.test(ua)) return 'iPad';
    if (/Android/.test(ua)) return 'Android';
    if (/Mac/.test(ua)) {
      if (/Chrome\//.test(ua)) return 'Chrome (Mac)';
      if (/Firefox\//.test(ua)) return 'Firefox (Mac)';
      return 'Safari (Mac)';
    }
    if (/Windows/.test(ua)) return 'Windows';
    if (/Linux/.test(ua)) return 'Linux';
    return 'Browser';
  }

  async function attemptPairing() {
    var code = getCode();
    if (code.length !== 6) return;

    pairBtn.disabled = true;
    pairBtn.textContent = 'Connecting...';
    pairError.hidden = true;

    try {
      console.log('[AG] Pairing with code:', code);
      var resp = await fetch('/pair', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ code: code, deviceName: getDeviceName() }),
      });
      console.log('[AG] Pair response status:', resp.status);
      var data = await resp.json();
      console.log('[AG] Pair response data:', JSON.stringify(data));

      if (data.token) {
        console.log('[AG] Got token, switching to main');
        localStorage.setItem(TOKEN_KEY, data.token);
        showMain();
        connectWebSocket(data.token);
      } else {
        console.log('[AG] No token in response');
        pairError.textContent = data.error || 'Invalid code';
        pairError.hidden = false;
        clearCodeInputs();
      }
    } catch (e) {
      console.error('[AG] Pairing error:', e);
      pairError.textContent = 'Connection failed';
      pairError.hidden = false;
    }

    pairBtn.disabled = false;
    pairBtn.textContent = 'Connect';
  }

  function clearCodeInputs() {
    for (const input of codeInputsEl.children) {
      input.value = '';
    }
    codeInputsEl.children[0].focus();
    updatePairButton();
  }

  // --- Screen Management ---

  function showPairing() {
    pairingScreen.hidden = false;
    mainScreen.hidden = true;
    loadingState.hidden = true;
    if (codeInputsEl.children.length > 0) {
      codeInputsEl.children[0].focus();
    }
  }

  function showMain() {
    pairingScreen.hidden = true;
    mainScreen.hidden = false;
    if (!initialLoadDone) {
      loadingState.hidden = false;
    }
  }

  // --- WebSocket ---

  var hasConnectedOnce = false;

  function connectWebSocket(token) {
    // Cancel any pending reconnect so stale timers don't overwrite this connection
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }

    if (ws) {
      ws.onclose = null;
      ws.onerror = null;
      ws.close();
    }

    var didOpen = false;
    var wsProtocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
    var wsHost = location.hostname + ':' + (parseInt(location.port) + 1);
    ws = new WebSocket(wsProtocol + '//' + wsHost);

    ws.onopen = function () {
      didOpen = true;
      hasConnectedOnce = true;
      reconnectDelay = 1000;
      connectionDot.className = 'dot dot-green';
      console.log('[AG] WebSocket connected, sending auth');
      // Authenticate with token as first message
      ws.send(JSON.stringify({ type: 'auth', token: token }));
    };

    ws.onmessage = function (event) {
      try {
        var msg = JSON.parse(event.data);
        handleServerMessage(msg);
      } catch (e) {
        console.error('[AG] Failed to parse message:', e);
      }
    };

    ws.onclose = function (event) {
      console.log('[AG] WebSocket closed, code=' + event.code);
      connectionDot.className = 'dot dot-red';

      if (!didOpen) {
        // WS never opened — could be invalid token OR server down
        // Probe the server to distinguish
        fetch('/api/status', { headers: { 'Authorization': 'Bearer ' + token } }).then(function (r) {
          if (r.ok) {
            // Server is up and token is valid — transient WS failure, retry
            scheduleReconnect(token);
          } else if (r.status === 401) {
            // Server is up but token is invalid
            console.log('[AG] Token rejected, showing pairing');
            localStorage.removeItem(TOKEN_KEY);
            sessions = {};
            renderSessions();
            showPairing();
          } else {
            scheduleReconnect(token);
          }
        }).catch(function () {
          // Server unreachable — keep retrying
          scheduleReconnect(token);
        });
        return;
      }

      // Was connected, then lost connection — reconnect
      scheduleReconnect(token);
    };

    ws.onerror = function () {
      console.error('[AG] WebSocket error');
    };
  }

  function scheduleReconnect(token) {
    if (reconnectTimer) clearTimeout(reconnectTimer);
    reconnectTimer = setTimeout(function () {
      reconnectDelay = Math.min(reconnectDelay * 1.5, 30000);
      connectWebSocket(token);
    }, reconnectDelay);
  }

  function send(msg) {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(msg));
      return;
    }
    // WS not available — send via HTTP POST fallback
    var t = localStorage.getItem(TOKEN_KEY);
    if (!t) return;
    fetch('/api/action', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + t },
      body: JSON.stringify(msg)
    }).catch(function (err) {
      console.error('[AG] Action POST failed:', err);
    });
  }

  // Keep-alive ping
  setInterval(function () {
    send({ type: 'ping' });
  }, 25000);

  // Fallback poll: if WS messages aren't arriving (Mobile Safari issue),
  // refresh session data via HTTP every 3 seconds
  var lastWsMessage = 0;
  var originalHandleServerMessage = handleServerMessage;
  handleServerMessage = function (msg) {
    lastWsMessage = Date.now();
    wsMessageCount++;
    updateDebugLabel();
    originalHandleServerMessage(msg);
  };

  setInterval(function () {
    // Only poll if WS hasn't delivered a message in the last 4 seconds
    // and we have a token and are on the main screen
    if (Date.now() - lastWsMessage < 4000) return;
    var t = localStorage.getItem(TOKEN_KEY);
    if (!t || mainScreen.hidden) return;

    fetch('/api/status', { headers: { 'Authorization': 'Bearer ' + t } })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (data) {
        if (!data || !data.sessions) return;
        var changed = false;
        for (var i = 0; i < data.sessions.length; i++) {
          var s = data.sessions[i];
          var existing = sessions[s.id];
          if (!existing || existing.state !== s.state || existing.currentTool !== s.currentTool || existing.elapsedSeconds !== s.elapsedSeconds) {
            changed = true;
          }
          sessions[s.id] = s;
        }
        // Remove sessions no longer in the list
        var activeIds = {};
        for (var i = 0; i < data.sessions.length; i++) activeIds[data.sessions[i].id] = true;
        for (var id in sessions) {
          if (!activeIds[id]) { delete sessions[id]; changed = true; }
        }
        if (data.groupMode) groupMode = data.groupMode;
        if (data.sortMode) sortMode = data.sortMode;
        serverGroups = data.groups || null;
        if (data.rowTitleFormat) rowTitleFormat = data.rowTitleFormat;
        if (data.rowDetailFormat) rowDetailFormat = data.rowDetailFormat;
        if (changed) { pollCount++; updateDebugLabel(); renderSessions(); }
      })
      .catch(function () {});
  }, 3000);

  // --- Message Handling ---

  var groupMode = 'none';
  var sortMode = 'lastUpdated';
  var serverGroups = null; // [{id, title, sessionIds}]
  var collapsedGroups = JSON.parse(localStorage.getItem('agentglance_collapsed') || '{}');
  var rowTitleFormat = '{cwd} ({name})';
  var rowDetailFormat = '{detail}';

  // Per-session card expansion state — kept in JS so re-renders don't wipe it.
  var expandedCompletion = {};  // sessionId -> true
  var expandedDiff = {};        // sessionId -> true
  var expandedPlan = {};        // sessionId -> true
  var dismissedCompletion = {}; // sessionId -> signature of dismissed message

  function completionSig(msg) {
    if (!msg) return '';
    return msg.length + ':' + msg.slice(0, 60);
  }

  function handleServerMessage(msg) {
    console.log('[AG] msg:', msg.type, msg.type === 'sessionUpdate' ? msg.payload.state : '');
    switch (msg.type) {
      case 'sync':
        sessions = {};
        expandedCompletion = {};
        expandedDiff = {};
        expandedPlan = {};
        dismissedCompletion = {};
        for (var s of msg.payload.sessions) {
          sessions[s.id] = s;
        }
        groupMode = msg.payload.groupMode || 'none';
        sortMode = msg.payload.sortMode || 'lastUpdated';
        serverGroups = msg.payload.groups || null;
        if (msg.payload.rowTitleFormat) rowTitleFormat = msg.payload.rowTitleFormat;
        if (msg.payload.rowDetailFormat) rowDetailFormat = msg.payload.rowDetailFormat;
        renderSessions();
        break;

      case 'sessionUpdate':
        sessions[msg.payload.id] = msg.payload;
        renderSessions();
        break;

      case 'sessionRemove':
        delete sessions[msg.payload.sessionId];
        delete expandedCompletion[msg.payload.sessionId];
        delete expandedDiff[msg.payload.sessionId];
        delete expandedPlan[msg.payload.sessionId];
        delete dismissedCompletion[msg.payload.sessionId];
        renderSessions();
        break;

      case 'pendingDecision':
        if (sessions[msg.payload.sessionId]) {
          sessions[msg.payload.sessionId].pending = msg.payload;
        }
        // New tool approval — show diff/plan collapsed by default.
        delete expandedDiff[msg.payload.sessionId];
        delete expandedPlan[msg.payload.sessionId];
        renderSessions();
        break;

      case 'decisionResolved':
        if (sessions[msg.payload.sessionId]) {
          sessions[msg.payload.sessionId].pending = null;
        }
        delete expandedDiff[msg.payload.sessionId];
        delete expandedPlan[msg.payload.sessionId];
        renderSessions();
        break;

      case 'pong':
        break;
    }
  }

  // --- Rendering ---

  function renderSessions() {
    var list = Object.values(sessions);
    initialLoadDone = true;
    loadingState.hidden = true;
    emptyState.hidden = list.length > 0;

    // Build new content
    var html = '';

    if (groupMode !== 'none' && serverGroups && serverGroups.length > 0) {
      for (var i = 0; i < serverGroups.length; i++) {
        var group = serverGroups[i];
        var groupSessions = [];
        for (var j = 0; j < group.sessionIds.length; j++) {
          var s = sessions[group.sessionIds[j]];
          if (s) groupSessions.push(s);
        }
        if (groupSessions.length === 0) continue;

        // Render group header inline to avoid Safari repaint issues
        var isCollapsed = !!collapsedGroups[group.id];
        html += '<div class="group-header" data-group-id="' + group.id + '">';
        html += '<span class="group-chevron' + (isCollapsed ? '' : ' expanded') + '">\u25B6</span>';
        html += '<span class="group-title">' + escapeHtml(group.title) + '</span>';
        html += '<span class="group-count">' + groupSessions.length + '</span>';
        html += '</div>';

        if (!isCollapsed) {
          sortSessionList(groupSessions);
          for (var k = 0; k < groupSessions.length; k++) {
            html += buildSessionCardHTML(groupSessions[k]);
          }
        }
      }
    } else {
      sortSessionList(list);
      for (var i = 0; i < list.length; i++) {
        html += buildSessionCardHTML(list[i]);
      }
    }

    sessionsEl.innerHTML = html;
    void sessionsEl.offsetHeight;
    renderCount++;
    updateDebugLabel();

    // Bind event handlers after DOM is updated
    var headers = sessionsEl.querySelectorAll('.group-header');
    for (var i = 0; i < headers.length; i++) {
      headers[i].addEventListener('click', handleGroupHeaderClick);
    }
    bindActionButtons();
  }

  function handleGroupHeaderClick() {
    var groupId = this.getAttribute('data-group-id');
    if (collapsedGroups[groupId]) {
      delete collapsedGroups[groupId];
    } else {
      collapsedGroups[groupId] = true;
    }
    localStorage.setItem('agentglance_collapsed', JSON.stringify(collapsedGroups));
    renderSessions();
  }

  function resolveTemplate(format, session) {
    var detail = buildDetailText(session);
    var stateText = buildStateText(session);
    var s = format;
    s = s.replace(/\{cwd\}/g, session.projectPath || session.cwd || '');
    s = s.replace(/\{name\}/g, session.name || '');
    s = s.replace(/\{state\}/g, stateText);
    s = s.replace(/\{tool\}/g, session.currentTool || '');
    s = s.replace(/\{detail\}/g, detail);
    s = s.replace(/\{time\}/g, session.elapsedFormatted || formatTime(session.elapsedSeconds));
    s = s.replace(/\{tools_count\}/g, String(session.toolCount || 0));
    s = s.replace(/\{model\}/g, session.modelName || '');
    s = s.replace(/\{input_tokens\}/g, formatTokenCount(session.inputTokens || 0));
    s = s.replace(/\{output_tokens\}/g, formatTokenCount(session.outputTokens || 0));
    s = s.replace(/\{total_tokens\}/g, formatTokenCount((session.inputTokens || 0) + (session.outputTokens || 0)));
    // Clean up empty parens and double spaces (matches native behavior)
    s = s.replace(/ \(\)/g, '').replace(/\(\)/g, '');
    s = s.replace(/  +/g, ' ').trim();
    return s;
  }

  function buildStateText(session) {
    if (session.state === 'working') {
      var d = session.workingDetail || 'runningTool';
      if (d === 'thinking') return 'Thinking...';
      if (d === 'compacting') return 'Compacting...';
      if (session.currentTool) return 'Running ' + session.currentTool + '...';
      return 'Working...';
    }
    if (session.state === 'awaitingApproval') return 'Approve ' + (session.currentTool || '') + '?';
    if (session.state === 'ready') return 'Finished';
    if (session.state === 'complete') return 'Complete';
    return 'Idle';
  }

  function formatTokenCount(n) {
    if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
    if (n >= 1000) return (n / 1000).toFixed(1) + 'K';
    return String(n);
  }

  function updateDebugLabel() {
    var source = wsMessageCount > 0 ? 'ws' : (pollCount > 0 ? 'poll' : '...');
    debugLabel.textContent = source + ' r:' + renderCount + ' ws:' + wsMessageCount + ' poll:' + pollCount;
  }

  function escapeHtml(str) {
    if (!str) return '';
    return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  function sortSessionList(list) {
    list.sort(function (a, b) {
      var stateOrder = { awaitingApproval: 0, working: 1, idle: 2, ready: 3, complete: 4 };
      var ao = stateOrder[a.state] != null ? stateOrder[a.state] : 5;
      var bo = stateOrder[b.state] != null ? stateOrder[b.state] : 5;
      if (ao !== bo) return ao - bo;
      return (b.elapsedSeconds || 0) - (a.elapsedSeconds || 0);
    });
  }

  // --- HTML Card Builder ---

  function buildSessionCardHTML(session) {
    var pending = session.pending;
    var extraClass = '';
    if (session.state === 'awaitingApproval') {
      if (pending && pending.type === 'question') extraClass = ' question';
      else if (pending && pending.type === 'plan') extraClass = ' plan';
      else extraClass = ' approval';
    }

    var h = '<div class="session-card' + extraClass + '" data-sid="' + escapeAttr(session.id) + '">';

    // Header row
    h += '<div class="session-header">';
    if (session.state === 'working') {
      var wd = session.workingDetail || 'runningTool';
      if (wd === 'thinking') h += '<div class="spinner cyan"></div>';
      else if (wd === 'compacting') h += '<div class="spinner orange"></div>';
      else h += '<div class="spinner"></div>';
    } else {
      h += '<div class="state-dot ' + stateClass(session.state) + '"></div>';
    }
    var titleText = resolveTemplate(rowTitleFormat, session);
    h += '<span class="session-name">' + escapeHtml(titleText) + '</span>';

    // Mode badge
    h += modeBadgeHTML(session.permissionMode);

    h += '<span class="session-time">' + (session.elapsedFormatted || formatTime(session.elapsedSeconds)) + '</span>';
    h += '</div>';

    // Detail line
    var detailLine = resolveTemplate(rowDetailFormat, session);
    if (detailLine) {
      h += '<div class="session-detail">' + escapeHtml(detailLine) + '</div>';
    }

    // Last user prompt (when thinking)
    if (session.state === 'working' && (session.workingDetail === 'thinking' || !session.workingDetail) && session.lastUserPrompt) {
      var prompt = session.lastUserPrompt.length > 80 ? session.lastUserPrompt.substring(0, 80) + '...' : session.lastUserPrompt;
      h += '<div class="user-prompt">' + escapeHtml(prompt) + '</div>';
    }

    // Approval UI
    if (session.state === 'awaitingApproval' && pending) {
      if (pending.type === 'permission') {
        h += buildPermissionHTML(session.id, pending);
      } else if (pending.type === 'question' && pending.questions) {
        h += buildQuestionHTML(session.id, pending);
      } else if (pending.type === 'plan') {
        h += buildPlanHTML(session.id, pending);
      }
    }

    // Todo progress
    if (session.todoCompleted != null && session.todoTotal && session.todoTotal > 0) {
      var pct = Math.round((session.todoCompleted / session.todoTotal) * 100);
      h += '<div class="todo-bar"><div class="todo-fill" style="width:' + pct + '%"></div></div>';
      h += '<div class="todo-label">' + session.todoCompleted + '/' + session.todoTotal + ' tasks</div>';
    }

    // Completion message — Mac-style card with icon header + markdown body + dismiss.
    if (session.state === 'ready' && session.completionMessage) {
      var sig = completionSig(session.completionMessage);
      if (dismissedCompletion[session.id] !== sig) {
        var isCompExpanded = !!expandedCompletion[session.id];
        var sourceLines = session.completionMessage.split('\n');
        var isLong = sourceLines.length > 8;
        var textToRender = (isCompExpanded || !isLong)
          ? session.completionMessage
          : sourceLines.slice(0, 8).join('\n');
        var rendered = renderMarkdown(textToRender);

        h += '<div class="completion-card">';
        h += '<div class="completion-card-header">';
        h += '<svg class="completion-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>';
        h += '<span class="completion-label">Agent Response</span>';
        h += '<button class="completion-dismiss" data-action="dismissCompletion" aria-label="Dismiss">\u00D7</button>';
        h += '</div>';
        h += '<div class="completion-msg">' + rendered + '</div>';
        if (isLong) {
          var chev = isCompExpanded
            ? '<svg class="completion-toggle-chevron" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="18 15 12 9 6 15"/></svg>'
            : '<svg class="completion-toggle-chevron" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="6 9 12 15 18 9"/></svg>';
          h += '<div class="completion-toggle" data-action="toggleCompletion">' + chev + '<span>' + (isCompExpanded ? 'Show less' : 'Show more') + '</span></div>';
        }
        h += '</div>';
      }
    }

    h += '</div>';
    return h;
  }

  function buildPermissionHTML(sessionId, pending) {
    var h = '';

    // Tool badge + queue count
    h += '<div class="session-header" style="margin-top:4px">';
    if (pending.toolName) {
      h += '<span class="tool-badge yellow">' + escapeHtml(pending.toolName) + '</span>';
    }
    if (pending.pendingCount > 1) {
      h += '<span class="queue-badge">+' + (pending.pendingCount - 1) + ' more</span>';
    }
    h += '</div>';

    // Tool-specific detail
    if (pending.toolName === 'Edit' && pending.oldString != null && pending.newString != null) {
      // Edit diff
      if (pending.filePath) {
        h += '<div class="diff-file">' + escapeHtml(shortenPath(pending.filePath)) + '</div>';
      }
      h += buildDiffHTML(pending.oldString, pending.newString, sessionId);
    } else if (pending.toolName === 'Write' && pending.filePath) {
      // Write file indicator
      var isNew = pending.isNewFile !== false;
      h += '<div class="write-badge ' + (isNew ? 'write-new' : 'write-overwrite') + '">';
      h += isNew ? '+ New file' : 'Overwrite';
      h += '</div>';
      h += '<div class="diff-file">' + escapeHtml(shortenPath(pending.filePath)) + '</div>';
    } else if ((pending.toolName === 'WebFetch' || pending.toolName === 'WebSearch') && pending.url) {
      var icon = pending.toolName === 'WebFetch' ? '\uD83C\uDF10' : '\uD83D\uDD0D';
      h += '<a class="tool-link" href="' + escapeAttr(pending.url) + '" target="_blank" rel="noopener">';
      h += icon + ' ' + escapeHtml(pending.url);
      h += '</a>';
    } else if (pending.toolSummary) {
      h += '<div class="tool-summary">' + escapeHtml(pending.toolSummary) + '</div>';
    }

    // Action buttons
    h += '<div class="actions">';
    h += '<button class="btn btn-allow btn-sm" data-action="allow" data-sid="' + sessionId + '">Allow</button>';
    h += '<button class="btn btn-always btn-sm" data-action="allowAlways" data-sid="' + sessionId + '">Always</button>';
    h += '<button class="btn btn-deny btn-sm" data-action="deny" data-sid="' + sessionId + '">Deny</button>';
    h += '<div class="spacer"></div>';
    h += '<button class="btn btn-skip btn-sm" data-action="dismiss" data-sid="' + sessionId + '">Skip</button>';
    h += '</div>';

    return h;
  }

  // Track question selections per session: { sessionId: { questionText: Set<option> } }
  var questionSelections = {};

  function buildQuestionHTML(sessionId, pending) {
    var questions = pending.questions;
    if (!questions || questions.length === 0) return '';

    var h = '';
    var sel = questionSelections[sessionId] || {};

    // Pagination for multiple questions
    var pageKey = 'q_page_' + sessionId;
    var currentPage = parseInt(localStorage.getItem(pageKey) || '0');
    if (currentPage >= questions.length) currentPage = 0;
    var showPagination = questions.length > 1;
    var displayQuestions = showPagination ? [questions[currentPage]] : questions;

    if (showPagination) {
      h += '<div class="question-nav">';
      h += '<span class="question-progress">Question ' + (currentPage + 1) + ' of ' + questions.length + '</span>';
      if (currentPage > 0) {
        h += '<button class="question-nav-btn" data-action="questionPrev" data-sid="' + sessionId + '">\u25C0</button>';
      }
      if (currentPage < questions.length - 1) {
        h += '<button class="question-nav-btn" data-action="questionNext" data-sid="' + sessionId + '">\u25B6</button>';
      }
      h += '</div>';
    }

    for (var qi = 0; qi < displayQuestions.length; qi++) {
      var q = displayQuestions[qi];
      var qSel = sel[q.questionText] || {};
      h += '<div class="question-block">';
      h += '<div class="question-text">' + escapeHtml(q.questionText) + '</div>';
      h += '<div class="option-chips">';
      for (var oi = 0; oi < q.options.length; oi++) {
        var opt = q.options[oi];
        var isSelected = !!qSel[opt];
        h += '<button class="option-chip' + (isSelected ? ' selected' : '') + '" data-action="selectOption" data-sid="' + sessionId + '" data-question="' + escapeAttr(q.questionText) + '" data-option="' + escapeAttr(opt) + '" data-multi="' + (q.multiSelect ? '1' : '0') + '">' + escapeHtml(opt) + '</button>';
      }
      h += '</div>';
      h += '</div>';
    }

    // Submit button (only if any selection made)
    var hasSelection = Object.keys(sel).some(function (k) { return Object.keys(sel[k]).length > 0; });
    if (hasSelection) {
      h += '<div class="actions">';
      h += '<button class="btn btn-primary btn-sm" data-action="submitAnswers" data-sid="' + sessionId + '">Submit</button>';
      h += '</div>';
    }

    return h;
  }

  function buildPlanHTML(sessionId, pending) {
    var h = '';
    var preview = pending.planPreview;
    var full = pending.planFull;
    var source = preview || full;
    if (source) {
      var isExpanded = !!expandedPlan[sessionId];
      // Show full content when expanded; fall back to preview if server didn't send planFull.
      var toRender = isExpanded ? (full || preview) : (preview || full);
      var hasMore = !!(full && preview && full !== preview) || (source.length > 300);
      var rendered = renderMarkdown(toRender);
      h += '<div class="plan-preview' + (isExpanded ? '' : ' collapsed') + '">' + rendered + '</div>';
      if (hasMore) {
        h += '<div class="plan-toggle" data-action="togglePlan">' + (isExpanded ? 'Show less' : 'Show more') + '</div>';
      }
    }
    h += '<div class="actions">';
    h += '<button class="btn btn-allow btn-sm" data-action="approvePlan" data-sid="' + sessionId + '">Approve</button>';
    h += '<button class="btn btn-deny btn-sm" data-action="rejectPlan" data-sid="' + sessionId + '">Reject</button>';
    h += '</div>';
    return h;
  }

  // --- Minimal Markdown Renderer ---
  // Handles headings, bullet/numbered lists, code blocks, inline code,
  // bold, italic, and safe links. Escapes HTML first so user content
  // can't inject markup. Not a full CommonMark implementation — just
  // what plan previews typically contain.
  function renderMarkdown(text) {
    if (!text) return '';
    var escaped = escapeHtml(text);

    // Pull out fenced code blocks before line-by-line processing.
    var codeBlocks = [];
    escaped = escaped.replace(/```(\w*)\n?([\s\S]*?)```/g, function (_m, _lang, code) {
      var idx = codeBlocks.push(code.replace(/\n+$/, '')) - 1;
      return '\x00CB' + idx + '\x00';
    });

    var lines = escaped.split('\n');
    var out = [];
    var listStack = []; // stack of 'ul' or 'ol'

    function closeLists() {
      while (listStack.length) out.push('</' + listStack.pop() + '>');
    }

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];

      var cb = line.match(/^\x00CB(\d+)\x00$/);
      if (cb) {
        closeLists();
        out.push('<pre class="md-code-block"><code>' + codeBlocks[+cb[1]] + '</code></pre>');
        continue;
      }

      var heading = line.match(/^(#{1,6})\s+(.+)$/);
      if (heading) {
        closeLists();
        var lvl = heading[1].length;
        out.push('<h' + lvl + ' class="md-h' + lvl + '">' + applyInline(heading[2]) + '</h' + lvl + '>');
        continue;
      }

      var bullet = line.match(/^\s*[-*+]\s+(.+)$/);
      if (bullet) {
        if (listStack[listStack.length - 1] !== 'ul') {
          closeLists();
          out.push('<ul class="md-list">');
          listStack.push('ul');
        }
        out.push('<li>' + applyInline(bullet[1]) + '</li>');
        continue;
      }

      var numbered = line.match(/^\s*\d+\.\s+(.+)$/);
      if (numbered) {
        if (listStack[listStack.length - 1] !== 'ol') {
          closeLists();
          out.push('<ol class="md-list">');
          listStack.push('ol');
        }
        out.push('<li>' + applyInline(numbered[1]) + '</li>');
        continue;
      }

      if (line.trim() === '') {
        closeLists();
        continue;
      }

      closeLists();
      out.push('<p class="md-p">' + applyInline(line) + '</p>');
    }
    closeLists();

    return out.join('');
  }

  function applyInline(text) {
    // Inline code first so its contents aren't mangled by bold/italic.
    text = text.replace(/`([^`\n]+)`/g, '<code class="md-inline-code">$1</code>');
    // Bold before italic so ** doesn't get eaten as two single *.
    text = text.replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
    text = text.replace(/\*([^*\n]+)\*/g, '<em>$1</em>');
    // Links — only allow http(s)/mailto to block javascript: injection.
    text = text.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, function (m, txt, url) {
      if (!/^(https?:|mailto:)/i.test(url)) return m;
      return '<a href="' + url + '" target="_blank" rel="noopener">' + txt + '</a>';
    });
    return text;
  }

  // --- Diff Rendering ---

  function buildDiffHTML(oldStr, newStr, sessionId) {
    var diff = computeDiff(oldStr.split('\n'), newStr.split('\n'));
    var totalLines = diff.length;
    var maxLines = 10;
    var expanded = !!(sessionId && expandedDiff[sessionId]);
    var cap = expanded ? totalLines : Math.min(maxLines, totalLines);
    var h = '<div class="diff-block"' + (expanded ? ' data-expanded="true"' : '') + '>';

    for (var i = 0; i < cap; i++) {
      var line = diff[i];
      var cls, prefix;
      if (line.kind === 'added') { cls = 'diff-add'; prefix = '+ '; }
      else if (line.kind === 'removed') { cls = 'diff-remove'; prefix = '\u2212 '; }
      else { cls = 'diff-context'; prefix = '  '; }
      h += '<div class="diff-line ' + cls + '">' + prefix + escapeHtml(line.text) + '</div>';
    }

    if (!expanded && totalLines > maxLines) {
      h += '<div class="diff-toggle" data-action="toggleDiff">Show all ' + totalLines + ' lines</div>';
    }

    h += '</div>';
    return h;
  }

  // Port of EditDiffView.computeDiff (Swift): minimal line diff via LCS DP table + backtrack.
  function computeDiff(oldLines, newLines) {
    var m = oldLines.length, n = newLines.length;
    var dp = new Array(m + 1);
    for (var i = 0; i <= m; i++) {
      dp[i] = new Array(n + 1);
      dp[i][0] = 0;
    }
    for (var j = 0; j <= n; j++) dp[0][j] = 0;

    for (var i = 1; i <= m; i++) {
      for (var j = 1; j <= n; j++) {
        if (oldLines[i - 1] === newLines[j - 1]) {
          dp[i][j] = dp[i - 1][j - 1] + 1;
        } else {
          dp[i][j] = dp[i - 1][j] >= dp[i][j - 1] ? dp[i - 1][j] : dp[i][j - 1];
        }
      }
    }

    var result = [];
    var i = m, j = n;
    while (i > 0 || j > 0) {
      if (i > 0 && j > 0 && oldLines[i - 1] === newLines[j - 1]) {
        result.push({ kind: 'context', text: oldLines[i - 1] });
        i--; j--;
      } else if (j > 0 && (i === 0 || dp[i][j - 1] >= dp[i - 1][j])) {
        result.push({ kind: 'added', text: newLines[j - 1] });
        j--;
      } else {
        result.push({ kind: 'removed', text: oldLines[i - 1] });
        i--;
      }
    }
    result.reverse();
    return result;
  }

  function modeBadgeHTML(mode) {
    if (!mode || mode === 'default') return '';
    var labels = { plan: 'Plan', auto: 'Auto', acceptEdits: 'Accept', bypassPermissions: 'Bypass', dontAsk: 'DontAsk' };
    var classes = { plan: 'mode-plan', auto: 'mode-auto', acceptEdits: 'mode-acceptEdits', bypassPermissions: 'mode-bypass', dontAsk: 'mode-dontAsk' };
    var label = labels[mode];
    if (!label) return '';
    return '<span class="mode-badge ' + (classes[mode] || '') + '">' + label + '</span>';
  }

  function shortenPath(path) {
    if (!path) return '';
    var parts = path.split('/');
    if (parts.length <= 3) return path;
    return '.../' + parts.slice(-2).join('/');
  }

  function escapeAttr(str) {
    if (!str) return '';
    return str.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/'/g, '&#39;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  // --- Action Button Binding ---

  function bindActionButtons() {
    var buttons = sessionsEl.querySelectorAll('[data-action]');
    for (var i = 0; i < buttons.length; i++) {
      buttons[i].addEventListener('click', handleActionClick);
    }
  }

  function handleActionClick() {
    var action = this.getAttribute('data-action');

    // Local UI toggles
    if (action === 'toggleCompletion') {
      var card = this.closest('.session-card');
      var cardSid = card && card.getAttribute('data-sid');
      if (cardSid) {
        if (expandedCompletion[cardSid]) delete expandedCompletion[cardSid];
        else expandedCompletion[cardSid] = true;
        renderSessions();
      }
      return;
    }

    if (action === 'dismissCompletion') {
      var dCard = this.closest('.session-card');
      var dSid = dCard && dCard.getAttribute('data-sid');
      var dSess = dSid && sessions[dSid];
      if (dSess && dSess.completionMessage) {
        dismissedCompletion[dSid] = completionSig(dSess.completionMessage);
        renderSessions();
      }
      return;
    }

    if (action === 'toggleDiff') {
      var diffCard = this.closest('.session-card');
      var diffSid = diffCard && diffCard.getAttribute('data-sid');
      if (diffSid) {
        expandedDiff[diffSid] = true;
        renderSessions();
      }
      return;
    }

    if (action === 'togglePlan') {
      var planCard = this.closest('.session-card');
      var planSid = planCard && planCard.getAttribute('data-sid');
      if (planSid) {
        if (expandedPlan[planSid]) delete expandedPlan[planSid];
        else expandedPlan[planSid] = true;
        renderSessions();
      }
      return;
    }

    var sid = this.getAttribute('data-sid');
    if (!action || !sid) return;

    // Question option selection (local state, no server call)
    if (action === 'selectOption') {
      var qText = this.getAttribute('data-question');
      var opt = this.getAttribute('data-option');
      var isMulti = this.getAttribute('data-multi') === '1';
      if (!questionSelections[sid]) questionSelections[sid] = {};
      var qSel = questionSelections[sid];
      if (!qSel[qText]) qSel[qText] = {};

      if (isMulti) {
        if (qSel[qText][opt]) delete qSel[qText][opt];
        else qSel[qText][opt] = true;
      } else {
        qSel[qText] = {};
        qSel[qText][opt] = true;
      }
      renderSessions();
      return;
    }

    // Question pagination
    if (action === 'questionPrev' || action === 'questionNext') {
      var pageKey = 'q_page_' + sid;
      var page = parseInt(localStorage.getItem(pageKey) || '0');
      page += (action === 'questionNext') ? 1 : -1;
      localStorage.setItem(pageKey, String(Math.max(0, page)));
      renderSessions();
      return;
    }

    // Submit all question answers
    if (action === 'submitAnswers') {
      var sel = questionSelections[sid] || {};
      var answers = {};
      for (var qText in sel) {
        var selected = Object.keys(sel[qText]);
        if (selected.length > 0) {
          answers[qText] = selected.join(',');
        }
      }
      delete questionSelections[sid];
      send({ type: 'answerQuestion', sessionId: sid, answers: answers });
      return;
    }

    // Server actions
    send({ type: action, sessionId: sid });
  }

  // --- Helpers ---

  function stateClass(state) {
    switch (state) {
      case 'working': return 'working';
      case 'awaitingApproval': return 'approval';
      case 'ready': return 'ready';
      case 'idle': return 'idle';
      case 'complete': return 'complete';
      default: return 'idle';
    }
  }

  function buildDetailText(session) {
    var detail;
    if (session.state === 'working') {
      detail = session.workingDetail || 'runningTool';
      if (detail === 'thinking') return 'Thinking...';
      if (detail === 'compacting') return 'Compacting...';
      var parts = [];
      if (session.currentTool) parts.push(session.currentTool);
      if (session.toolCount > 0) parts.push(session.toolCount + ' tools');
      return parts.join(' \u2014 ') || 'Working...';
    }
    if (session.state === 'awaitingApproval') return 'Waiting for approval';
    if (session.state === 'ready') return 'Ready for next prompt';
    if (session.state === 'complete') return 'Session complete';
    if (session.state === 'idle') return 'Idle';
    return '';
  }

  function formatTime(seconds) {
    if (!seconds || seconds < 0) return '0s';
    var m = Math.floor(seconds / 60);
    var s = seconds % 60;
    if (m > 0) return m + 'm ' + s + 's';
    return s + 's';
  }

  // --- Settings Panel ---

  settingsBtn.addEventListener('click', function () {
    settingsPanel.hidden = !settingsPanel.hidden;
  });

  disconnectBtn.addEventListener('click', function () {
    // Close WS, clear token, show pairing
    if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
    if (ws) { ws.onclose = null; ws.onerror = null; ws.close(); ws = null; }
    localStorage.removeItem(TOKEN_KEY);
    releaseWakeLock();
    sessions = {};
    initialLoadDone = false;
    settingsPanel.hidden = true;
    showPairing();
  });

  // --- Keep Screen On ---
  // Uses Wake Lock API if available (HTTPS/localhost), falls back to
  // a silent video loop trick for plain HTTP on LAN.
  // To remove this feature entirely, delete this section and the
  // wakelock-toggle / WAKELOCK_KEY references above.

  var wakeLockActive = false;
  var wakeLockHandle = null; // Wake Lock API handle
  var wakeLockVideo = null;  // Fallback video element
  var WAKELOCK_KEY = 'agentglance_wakelock';

  if (localStorage.getItem(WAKELOCK_KEY) === '1') {
    wakelockToggle.checked = true;
    enableKeepScreenOn();
  }

  wakelockToggle.addEventListener('change', function () {
    localStorage.setItem(WAKELOCK_KEY, this.checked ? '1' : '0');
    if (this.checked) enableKeepScreenOn();
    else disableKeepScreenOn();
  });

  function enableKeepScreenOn() {
    if (wakeLockActive) return;
    wakeLockActive = true;

    // Start video FIRST — must happen synchronously in user gesture context.
    // iOS rejects play() if called from an async callback (gesture expires).
    startVideoWakeLock();

    // Then try Wake Lock API as an upgrade (cleaner, less battery).
    if ('wakeLock' in navigator) {
      navigator.wakeLock.request('screen').then(function (lock) {
        wakeLockHandle = lock;
        console.log('[AG] Wake lock upgraded to API');
        lock.addEventListener('release', function () { wakeLockHandle = null; });
        stopVideoWakeLock();
      }).catch(function () {
        console.log('[AG] Wake Lock API unavailable, keeping video');
      });
    }
  }

  function disableKeepScreenOn() {
    wakeLockActive = false;
    if (wakeLockHandle) { wakeLockHandle.release(); wakeLockHandle = null; }
    stopVideoWakeLock();
  }

  function startVideoWakeLock() {
    if (wakeLockVideo) return;
    // A looping video with a silent audio track keeps iOS awake.
    // Key: must be UNMUTED — iOS ignores muted videos for screen lock.
    // The audio track has zero samples so nothing is audible.
    // Must be started from a user gesture (the toggle click).
    var v = document.createElement('video');
    v.setAttribute('playsinline', '');
    v.setAttribute('loop', '');
    // Explicitly NOT muted — iOS needs active audio decoding
    v.muted = false;
    v.volume = 0.001; // Near-silent but not muted
    v.style.cssText = 'position:fixed;top:-1px;left:-1px;width:1px;height:1px;opacity:0.01;pointer-events:none;z-index:-1';
    v.src = '/silent.mp4';

    document.body.appendChild(v);
    v.play().then(function () {
      console.log('[AG] Wake lock acquired (video, unmuted)');
    }).catch(function (err) {
      console.log('[AG] Video wake lock blocked:', err.message);
      // If unmuted play fails, try muted as last resort
      v.muted = true;
      v.play().then(function () {
        console.log('[AG] Wake lock acquired (video, muted fallback)');
      }).catch(function (err2) {
        console.log('[AG] Video wake lock failed entirely:', err2.message);
      });
    });
    wakeLockVideo = v;
  }

  function stopVideoWakeLock() {
    if (wakeLockVideo) {
      wakeLockVideo.pause();
      wakeLockVideo.remove();
      wakeLockVideo = null;
      console.log('[AG] Wake lock released (video)');
    }
  }

  // Re-acquire on visibility change
  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'visible' && wakeLockActive) {
      if ('wakeLock' in navigator && !wakeLockHandle) {
        navigator.wakeLock.request('screen').then(function (lock) {
          wakeLockHandle = lock;
          lock.addEventListener('release', function () { wakeLockHandle = null; });
        }).catch(function () {});
      }
      if (wakeLockVideo) { wakeLockVideo.play().catch(function () {}); }
    }
  });

})();
