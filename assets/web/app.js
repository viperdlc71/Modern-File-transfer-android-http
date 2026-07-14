/* LocalDrop browser client — vanilla JS, no frameworks. */
(function () {
  "use strict";

  const els = {
    body: document.body,
    pinOverlay: document.getElementById("pin-overlay"),
    pinForm: document.getElementById("pin-form"),
    pinInput: document.getElementById("pin-input"),
    pinError: document.getElementById("pin-error"),
    viewApp: document.getElementById("view-app"),
    fileList: document.getElementById("file-list"),
    filesEmpty: document.getElementById("files-empty"),
    breadcrumb: document.getElementById("breadcrumb"),
    selectAll: document.getElementById("select-all"),
    downloadZip: document.getElementById("download-zip"),
    refresh: document.getElementById("refresh"),
    dropzone: document.getElementById("dropzone"),
    pickFiles: document.getElementById("pick-files"),
    fileInput: document.getElementById("file-input"),
    uploadList: document.getElementById("upload-list"),
    conn: document.getElementById("conn-status"),
    toast: document.getElementById("toast"),
    filterSearch: document.getElementById("filter-search"),
    filterType: document.getElementById("filter-type"),
    clearFilters: document.getElementById("clear-filters"),
    filterCount: document.getElementById("filter-count"),
    viewToggle: document.getElementById("view-toggle"),
    sortBtn: document.getElementById("sort-btn"),
    sortBtnInline: document.getElementById("sort-btn-inline"),
    sortDropdown: document.getElementById("sort-dropdown"),
    fileToolbar: document.getElementById("file-toolbar"),
  };

  const state = {
    token: null,
    files: [],
    filteredFiles: [],
    selected: new Set(),
    uploads: new Map(),
    filters: { search: "", type: "all" },
    viewMode: "list",
    sortKey: "name",
    sortDir: "asc",
    currentPath: "",
  };

  /* ---------- logging ---------- */
  function log(area, message) {
    const ts = new Date().toISOString().split('T')[1].slice(0, -1);
    const entry = `[${ts}] [${area}] ${message}`;
    console.log(entry);
  }

  /* ---------- helpers ---------- */
  function authHeaders() {
    const h = { "X-Requested-With": "fetch" };
    if (state.token) h["Authorization"] = "Bearer " + state.token;
    return h;
  }

  async function api(path, options) {
    options = options || {};
    options.credentials = "same-origin";
    options.headers = Object.assign(authHeaders(), options.headers || {});
    log('http', `request ${path}`);
    const res = await fetch(path, options);
    log('http', `response ${path} status=${res.status}`);
    if (res.status === 401) {
      logout();
      throw new Error("unauthorized");
    }
    if (!res.ok) throw new Error("http_" + res.status);
    return res;
  }

  function showToast(msg, ms) {
    els.toast.textContent = msg;
    els.toast.hidden = false;
    clearTimeout(showToast._t);
    showToast._t = setTimeout(() => (els.toast.hidden = true), ms || 2600);
  }

  function setConn(ok) {
    els.conn.classList.toggle("ok", ok === true);
    els.conn.classList.toggle("bad", ok === false);
  }

  function fmtSize(bytes) {
    if (bytes == null) return "";
    const u = ["B", "KB", "MB", "GB", "TB"];
    let i = 0;
    let n = bytes;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return (i === 0 ? n : n.toFixed(n < 10 ? 2 : 1)) + " " + u[i];
  }

  function fmtDate(ts) {
    if (!ts) return "";
    const d = new Date(ts * 1000);
    return d.toLocaleDateString() + " " + d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  }

  function iconFor(name, isDirectory) {
    if (isDirectory) return "📁";
    const ext = (name.split(".").pop() || "").toLowerCase();
    const map = {
      png: "🖼", jpg: "🖼", jpeg: "🖼", gif: "🖼", webp: "🖼", svg: "🖼", heic: "🖼",
      mp4: "🎞", mov: "🎞", mkv: "🎞", webm: "🎞", avi: "🎞",
      mp3: "🎵", wav: "🎵", ogg: "🎵", flac: "🎵", m4a: "🎵",
      pdf: "📄", doc: "📝", docx: "📝", txt: "📝", md: "📝", rtf: "📝",
      xls: "📊", xlsx: "📊", csv: "📊",
      zip: "🗜", rar: "🗜", "7z": "🗜", gz: "🗜", tar: "🗜",
      apk: "📦", exe: "⚙",
    };
    if (map[ext]) return map[ext];
    return "📄";
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])
    );
  }

  function uuid() {
    return (crypto.randomUUID && crypto.randomUUID()) ||
      (Date.now().toString(36) + Math.random().toString(36).slice(2));
  }

  /* ---------- filters ---------- */
  const TYPE_MAP = {
    image: ["png","jpg","jpeg","gif","webp","svg","heic","bmp","ico"],
    video: ["mp4","mov","mkv","webm","avi","flv","wmv"],
    audio: ["mp3","wav","ogg","flac","m4a","aac","wma"],
    document: ["pdf","doc","docx","txt","md","rtf","odt","ppt","pptx","xls","xlsx","csv"],
    archive: ["zip","rar","7z","gz","tar","bz2"],
  };

  function matchType(name, type) {
    if (type === "all") return true;
    const ext = (name.split(".").pop() || "").toLowerCase();
    return (TYPE_MAP[type] || []).includes(ext) || (type === "other" && !Object.values(TYPE_MAP).some(arr => arr.includes(ext)));
  }

  function matchSize(size, range) {
    if (range === "all" || size == null) return range === "all";
    const mb = size / (1024 * 1024);
    switch (range) {
      case "small": return mb < 1;
      case "medium": return mb >= 1 && mb <= 100;
      case "large": return mb > 100;
      default: return true;
    }
  }

  function matchDate(ts, range) {
    if (range === "all" || !ts) return range === "all";
    const now = Date.now() / 1000;
    const diff = now - ts;
    switch (range) {
      case "today": return diff < 86400;
      case "week": return diff < 7 * 86400;
      case "month": return diff < 30 * 86400;
      case "older": return diff >= 30 * 86400;
      default: return true;
    }
  }

  function sortFiles(files) {
    const key = state.sortKey;
    const dir = state.sortDir === "asc" ? 1 : -1;
    return files.slice().sort((a, b) => {
      if (a.isDirectory !== b.isDirectory) return a.isDirectory ? -1 : 1;
      let va, vb;
      if (key === "name") { va = a.name.toLowerCase(); vb = b.name.toLowerCase(); }
      else if (key === "size") { va = a.size || 0; vb = b.size || 0; }
      else if (key === "date") { va = a.modified || 0; vb = b.modified || 0; }
      else if (key === "type") { va = (a.name.split(".").pop() || "").toLowerCase(); vb = (b.name.split(".").pop() || "").toLowerCase(); }
      else { va = a.name.toLowerCase(); vb = b.name.toLowerCase(); }
      if (va < vb) return -1 * dir;
      if (va > vb) return 1 * dir;
      return 0;
    });
  }

  function applyFilters() {
    const f = state.filters;
    state.filteredFiles = state.files.filter((file) => {
      if (f.search && !file.name.toLowerCase().includes(f.search.toLowerCase())) return false;
      if (!matchType(file.name, f.type)) return false;
      return true;
    });
    state.filteredFiles = sortFiles(state.filteredFiles);
    renderFiles();
    updateFilterUI();
    saveFilters();
  }

  function updateFilterUI() {
    const f = state.filters;
    const active = (f.search ? 1 : 0) + (f.type !== "all" ? 1 : 0);
    els.clearFilters.hidden = active === 0;
    els.filterCount.hidden = active === 0;
    els.filterCount.textContent = active + " filter" + (active === 1 ? "" : "s") + " active";
  }

  function loadFilters() {
    try {
      const saved = localStorage.getItem("localdrop_filters");
      if (saved) {
        const parsed = JSON.parse(saved);
        state.filters.search = parsed.search || "";
        state.filters.type = parsed.type || "all";
      }
    } catch (_) {}
    els.filterSearch.value = state.filters.search;
    els.filterType.value = state.filters.type;
  }

  function saveFilters() {
    try {
      localStorage.setItem("localdrop_filters", JSON.stringify(state.filters));
    } catch (_) {}
  }

  function clearAllFilters() {
    state.filters = { search: "", type: "all" };
    els.filterSearch.value = "";
    els.filterType.value = "all";
    applyFilters();
  }

  /* ---------- breadcrumbs ---------- */
  function renderBreadcrumb() {
    els.breadcrumb.innerHTML = "";
    const parts = state.currentPath ? state.currentPath.split("/").filter(Boolean) : [];
    const allParts = ["Home", ...parts];

    allParts.forEach((part, index) => {
      if (index > 0) {
        const sep = document.createElement("span");
        sep.className = "breadcrumb-sep";
        sep.textContent = "/";
        els.breadcrumb.appendChild(sep);
      }
      const btn = document.createElement("button");
      btn.className = "breadcrumb-item";
      if (index === allParts.length - 1) btn.classList.add("current");
      btn.textContent = part;
      if (index < allParts.length - 1) {
        btn.addEventListener("click", () => {
          const targetPath = parts.slice(0, index).join("/");
          state.currentPath = targetPath;
          loadFiles();
        });
      }
      els.breadcrumb.appendChild(btn);
    });
  }

  /* ---------- auth / PIN modal ---------- */
  function showPinModal() {
    els.pinOverlay.classList.remove("fade-out");
    els.pinOverlay.hidden = false;
    els.pinInput.value = "";
    els.pinError.hidden = true;
    setTimeout(() => els.pinInput.focus(), 100);
  }

  function hidePinModal() {
    els.pinOverlay.classList.add("fade-out");
    setTimeout(() => { els.pinOverlay.hidden = true; }, 250);
  }

  els.pinForm.addEventListener("submit", async (e) => {
    e.preventDefault();
    const pin = els.pinInput.value.trim();
    if (pin.length !== 6) return;
    log('auth', 'attempt');
    try {
      const res = await fetch("/api/auth", {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ pin }),
      });
      if (!res.ok) {
        log('auth', 'failure');
        els.pinError.hidden = false;
        els.pinInput.value = "";
        return;
      }
      const data = await res.json();
      state.token = data.token;
      log('auth', 'success');
      hidePinModal();
      loadFiles();
    } catch (err) {
      log('auth', 'error: ' + err.message);
      els.pinError.hidden = false;
      els.pinError.textContent = "Connection failed. Is the phone still on the network?";
    }
  });

  els.pinInput.addEventListener("input", () => {
    els.pinInput.value = els.pinInput.value.replace(/\D/g, "").slice(0, 6);
    els.pinError.hidden = true;
    if (els.pinInput.value.length === 6) els.pinForm.requestSubmit();
  });

  function logout() {
    state.token = null;
    state.selected.clear();
    state.currentPath = "";
    showPinModal();
  }

  /* ---------- files ---------- */
  async function loadFiles() {
    if (!state.token) return;
    try {
      const pathParam = state.currentPath ? `?path=${encodeURIComponent(state.currentPath)}` : "";
      const res = await api("/api/files" + pathParam);
      const data = await res.json();
      state.files = data.files || [];
      applyFilters();
      renderBreadcrumb();
      setConn(true);
    } catch (err) {
      if (err.message !== "unauthorized") {
        setConn(false);
        showToast("Could not reach the phone.");
      }
    }
  }

  function renderFiles() {
    const list = state.filteredFiles;
    els.fileList.innerHTML = "";
    els.filesEmpty.hidden = list.length > 0;
    els.fileList.classList.toggle("grid-view", state.viewMode === "grid");

    for (const f of list) {
      const row = document.createElement("div");
      row.className = "file-row";
      if (state.selected.has(f.name)) row.classList.add("selected");
      row.dataset.name = f.name;

      const checked = state.selected.has(f.name);
      row.innerHTML = `
        <input type="checkbox" class="file-check" ${checked ? "checked" : ""} />
        <div class="file-icon">${iconFor(f.name, f.isDirectory)}</div>
        <div class="file-meta">
          <div class="file-name">${escapeHtml(f.name)}</div>
          <div class="file-sub">${f.isDirectory ? 'Folder' : fmtSize(f.size) + ' · ' + fmtDate(f.modified)}</div>
        </div>
        <div class="file-actions">
          ${f.isDirectory ? '' : '<button class="btn ghost dl" title="Download">↓</button>'}
        </div>
        <div class="file-progress"><span></span></div>`;

      const checkbox = row.querySelector(".file-check");
      checkbox.addEventListener("change", (e) => {
        e.stopPropagation();
        if (e.target.checked) state.selected.add(f.name);
        else state.selected.delete(f.name);
        row.classList.toggle("selected", e.target.checked);
        updateSelectionUI();
      });

      row.addEventListener("click", (e) => {
        if (e.target === checkbox) return;
        if (f.isDirectory) {
          const newPath = state.currentPath ? state.currentPath + "/" + f.name : f.name;
          state.currentPath = newPath;
          loadFiles();
          return;
        }
        if (state.isSelecting || e.shiftKey || e.ctrlKey || e.metaKey) {
          if (state.selected.has(f.name)) state.selected.delete(f.name);
          else state.selected.add(f.name);
          renderFiles();
        } else {
          downloadFile(f.name, row);
        }
      });

      row.addEventListener("contextmenu", (e) => {
        e.preventDefault();
        if (state.selected.has(f.name)) state.selected.delete(f.name);
        else state.selected.add(f.name);
        renderFiles();
      });

      if (!f.isDirectory) {
        row.querySelector(".dl").addEventListener("click", (e) => {
          e.stopPropagation();
          downloadFile(f.name, row);
        });
      }

      els.fileList.appendChild(row);
    }
    updateSelectionUI();
  }

  function updateSelectionUI() {
    els.downloadZip.disabled = state.selected.size === 0;
    els.selectAll.checked = state.filteredFiles.length > 0 && state.selected.size === state.filteredFiles.length;
    els.fileToolbar.classList.toggle("force-show", state.selected.size > 0);
  }

  els.selectAll.addEventListener("change", (e) => {
    if (e.target.checked) state.filteredFiles.forEach((f) => state.selected.add(f.name));
    else state.selected.clear();
    renderFiles();
  });

  els.refresh.addEventListener("click", loadFiles);

  els.filterSearch.addEventListener("input", () => {
    state.filters.search = els.filterSearch.value;
    applyFilters();
  });

  els.filterType.addEventListener("change", () => {
    state.filters.type = els.filterType.value;
    applyFilters();
  });

  els.clearFilters.addEventListener("click", clearAllFilters);

  els.viewToggle.addEventListener("click", () => {
    state.viewMode = state.viewMode === "list" ? "grid" : "list";
    renderFiles();
  });

  function openSortDropdown() {
    els.sortDropdown.hidden = !els.sortDropdown.hidden;
  }
  els.sortBtn.addEventListener("click", (e) => {
    e.stopPropagation();
    openSortDropdown();
  });
  els.sortBtnInline.addEventListener("click", (e) => {
    e.stopPropagation();
    openSortDropdown();
  });

  document.addEventListener("click", () => {
    els.sortDropdown.hidden = true;
  });

  els.sortDropdown.addEventListener("click", (e) => {
    const item = e.target.closest(".dropdown-item");
    if (!item) return;
    const val = item.dataset.sort;
    const [key, dir] = val.split("-");
    state.sortKey = key;
    state.sortDir = dir;
    applyFilters();
    els.sortDropdown.hidden = true;
  });

  els.downloadZip.addEventListener("click", async () => {
    const names = Array.from(state.selected);
    if (!names.length) return;
    try {
      const q = encodeURIComponent(names.join(","));
      const res = await api("/api/download-zip?files=" + q);
      const blob = await res.blob();
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = "localdrop.zip";
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 5000);
    } catch (err) {
      showToast("Download failed.");
    }
  });

  async function downloadFile(name, row) {
    log('download', 'start name=' + name);
    const progressBar = row ? row.querySelector('.file-progress > span') : null;
    const xhr = new XMLHttpRequest();
    xhr.open("GET", "/api/download/" + encodeURIComponent(name), true);
    xhr.setRequestHeader("X-Requested-With", "fetch");
    if (state.token) xhr.setRequestHeader("Authorization", "Bearer " + state.token);
    xhr.responseType = "blob";

    xhr.onprogress = (e) => {
      if (e.lengthComputable && progressBar) {
        const p = (e.loaded / e.total) * 100;
        progressBar.style.width = p.toFixed(1) + "%";
      }
    };

    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        const blob = xhr.response;
        const url = URL.createObjectURL(blob);
        const a = document.createElement("a");
        a.href = url;
        a.download = name;
        document.body.appendChild(a);
        a.click();
        a.remove();
        setTimeout(() => URL.revokeObjectURL(url), 5000);
        if (progressBar) {
          progressBar.style.width = "100%";
          setTimeout(() => { progressBar.style.width = "0"; }, 1200);
        }
        log('download', 'complete name=' + name);
      } else {
        log('download', 'failed name=' + name + ' status=' + xhr.status);
        showToast("Download failed.");
        if (progressBar) progressBar.style.width = "0";
      }
      if (row) row.classList.remove("downloading");
    };

    xhr.onerror = () => {
      log('download', 'error name=' + name);
      showToast("Download error.");
      if (progressBar) progressBar.style.width = "0";
      if (row) row.classList.remove("downloading");
    };

    if (row) row.classList.add("downloading");
    xhr.send();
  }

  /* ---------- tabs ---------- */
  const tabs = Array.from(document.querySelectorAll(".tab"));
  const tabFiles = document.getElementById("tab-files");
  const tabUpload = document.getElementById("tab-upload");

  tabs.forEach((tab) => {
    tab.addEventListener("click", () => {
      tabs.forEach((t) => t.classList.remove("active"));
      tab.classList.add("active");
      const name = tab.dataset.tab;
      tabFiles.hidden = name !== "files";
      tabUpload.hidden = name !== "upload";
    });
  });

  /* ---------- upload (XHR gives reliable progress) ---------- */
  els.pickFiles.addEventListener("click", () => els.fileInput.click());
  els.fileInput.addEventListener("change", (e) => {
    handleFiles(e.target.files);
    els.fileInput.value = "";
  });

  ["dragenter", "dragover"].forEach((ev) =>
    els.dropzone.addEventListener(ev, (e) => {
      e.preventDefault();
      els.dropzone.classList.add("over");
    })
  );
  ["dragleave", "drop"].forEach((ev) =>
    els.dropzone.addEventListener(ev, (e) => {
      e.preventDefault();
      els.dropzone.classList.remove("over");
    })
  );
  els.dropzone.addEventListener("drop", (e) => {
    if (e.dataTransfer && e.dataTransfer.files) handleFiles(e.dataTransfer.files);
  });

  function handleFiles(fileList) {
    for (const file of Array.from(fileList)) startUpload(file);
  }

  function startUpload(file) {
    const id = uuid();
    const fd = new FormData();
    fd.append("file", file, file.name);
    log('upload', 'start name=' + file.name + ' size=' + file.size);

    const row = document.createElement("div");
    row.className = "up-row";
    row.innerHTML = `
      <div class="up-head">
        <span class="up-name">${escapeHtml(file.name)}</span>
        <span class="up-sub pct-head">0%</span>
      </div>
      <div class="progress"><span></span></div>
      <div class="up-sub pct-foot">0 / ${fmtSize(file.size)} · preparing…</div>`;
    els.uploadList.prepend(row);
    const bar = row.querySelector(".progress > span");
    const pct = row.querySelector(".pct-foot");
    const subHead = row.querySelector(".pct-head");

    const xhr = new XMLHttpRequest();
    xhr.open("POST", "/api/upload?id=" + id);
    xhr.setRequestHeader("X-Requested-With", "fetch");
    if (state.token) xhr.setRequestHeader("Authorization", "Bearer " + state.token);
    xhr.withCredentials = true;
    xhr.timeout = 0;

    xhr.upload.onprogress = (e) => {
      if (e.lengthComputable) {
        const p = (e.loaded / e.total) * 100;
        bar.style.width = p.toFixed(1) + "%";
        subHead.textContent = p.toFixed(0) + "%";
        pct.textContent = fmtSize(e.loaded) + " / " + fmtSize(e.total);
      } else {
        pct.textContent = fmtSize(e.loaded) + " uploaded";
      }
    };

    let retries = 0;
    const maxRetries = 2;

    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        bar.style.width = "100%";
        subHead.textContent = "Done";
        pct.textContent = fmtSize(file.size) + " · uploaded";
        log('upload', 'complete name=' + file.name);
        loadFiles();
      } else if (xhr.status === 401) {
        logout();
      } else {
        subHead.textContent = "Failed";
        let reason = "Upload error (" + xhr.status + ")";
        try {
          const err = JSON.parse(xhr.responseText);
          if (err.error) reason = err.error;
        } catch (_) {}
        pct.textContent = reason;
        log('upload', 'failed name=' + file.name + ' reason=' + reason);
      }
    };

    xhr.onerror = () => {
      if (retries < maxRetries) {
        retries++;
        subHead.textContent = "Retrying (" + (retries + 1) + "/" + (maxRetries + 1) + ")…";
        log('upload', 'retry name=' + file.name + ' attempt=' + (retries + 1));
        setTimeout(() => xhr.send(fd), 1500 * (retries + 1));
      } else {
        subHead.textContent = "Failed";
        pct.textContent = "Connection lost";
        setConn(false);
        log('upload', 'failed name=' + file.name + ' reason=connection-lost');
      }
    };

    xhr.ontimeout = () => {
      subHead.textContent = "Timeout";
      pct.textContent = "Upload timed out — try again";
      log('upload', 'timeout name=' + file.name);
    };

    xhr.send(fd);
  }

  /* ---------- periodic heartbeat ---------- */
  setInterval(() => {
    if (state.token) loadFiles();
  }, 8000);

  /* ---------- boot ---------- */
  loadFilters();
  showPinModal();
})();
